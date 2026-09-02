// Jail engagement state and AX window measurement: the pure clamp geometry
// lives in JailMath.swift; this file owns the AX reads and the
// engaged/virtual-position bookkeeping the tap callback integrates against.

import Cocoa

// AX calls run on the thread that services the tap, and one refresh makes
// several. Unbounded calls into a stalled game would freeze the cursor via
// tap timeout.
let axTimeout: Float = 0.05
// Installed once, on first use. The timeout is per element (AXUIElement.h),
// and an element without its own uses the process-global one, so the
// system-wide set covers every window and button fetched later.
private let axTimeoutInstalled: Bool = {
    AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), axTimeout) == .success
}()
// The window's native-fullscreen state. Undocumented (the SDK only names the
// button, kAXFullScreenButtonAttribute) but what AppKit answers and window
// managers read.
let axFullScreenAttribute = "AXFullScreen"

// Main-thread only: the tap source, timer, and notifications share the main
// run loop. Moving any of them off it would need synchronization here.
var clampArea: Clamp?
var virtualPos = CGPoint.zero
var engaged = false
// Runtime gate for the whole jail feature: the panel toggle and the hotkey
// flip it and call refresh().
var jailEnabled = true
// A warp folds its displacement into the next mouse event's delta. Track it
// so integration sees only hand movement, otherwise our own warps feed back
// and the cursor rockets away.
var pendingWarp = CGPoint.zero

// One attribute read with the failure kinds the callers need apart: missing
// (the window has no such attribute, or answers it with the wrong type) is a
// fact about the window, failed (a timeout under load, the element gone) says
// nothing about it.
enum AXRead<Value> {
    case value(Value), missing, failed

    var failed: Bool {
        if case .failed = self { return true }
        return false
    }

    var payload: Value? {
        if case .value(let v) = self { return v }
        return nil
    }

    // nil from the transform is a wrong-typed answer: missing.
    func compactMap<T>(_ transform: (Value) -> T?) -> AXRead<T> {
        flatMap { transform($0).map { .value($0) } ?? .missing }
    }

    func flatMap<T>(_ transform: (Value) -> AXRead<T>) -> AXRead<T> {
        switch self {
        case .value(let v): return transform(v)
        case .missing: return .missing
        case .failed: return .failed
        }
    }
}

// notImplemented ("the process does not fully support the accessibility
// API") is permanent, so it counts as missing: as a failure it would keep the
// jail from ever engaging on such a process.
func axRead(_ el: AXUIElement, _ attribute: String) -> AXRead<CFTypeRef> {
    var ref: CFTypeRef?
    switch AXUIElementCopyAttributeValue(el, attribute as CFString, &ref) {
    case .success: return ref.map { .value($0) } ?? .missing
    case .noValue, .attributeUnsupported, .notImplemented: return .missing
    default: return .failed
    }
}

func axElement(_ el: AXUIElement, _ attribute: String) -> AXRead<AXUIElement> {
    axRead(el, attribute).compactMap {
        CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil
    }
}

func axString(_ el: AXUIElement, _ attribute: String) -> AXRead<String> {
    axRead(el, attribute).compactMap { $0 as? String }
}

// Any number counts (a non-AppKit AX server may answer 0/1), so this is
// looser than the settings reads, which reject numbers for bool keys.
func axBool(_ el: AXUIElement, _ attribute: String) -> AXRead<Bool> {
    axRead(el, attribute).compactMap { ($0 as? NSNumber)?.boolValue }
}

func axPoint(_ ref: CFTypeRef) -> CGPoint? {
    guard CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    return AXValueGetValue((ref as! AXValue), .cgPoint, &point) ? point : nil
}

func axSize(_ ref: CFTypeRef) -> CGSize? {
    guard CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
    var size = CGSize.zero
    return AXValueGetValue((ref as! AXValue), .cgSize, &size) ? size : nil
}

func axRect(_ el: AXUIElement) -> AXRead<CGRect> {
    axRead(el, kAXPositionAttribute).compactMap(axPoint).flatMap { origin in
        axRead(el, kAXSizeAttribute).compactMap(axSize).compactMap { CGRect(origin: origin, size: $0) }
    }
}

// One AX measurement of the game window. unreadable is a transient AX
// failure (the caller keeps its last rect); fullscreen asks for release.
enum GameWindow {
    case unreadable, fullscreen, clamp(Clamp)
}

func gameWindow(_ app: NSRunningApplication) -> GameWindow {
    _ = axTimeoutInstalled
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    // Only a window that is missing (not one that timed out) falls back to
    // the main window: a stalled read says nothing about which is focused.
    let focused = axElement(ax, kAXFocusedWindowAttribute)
    guard !focused.failed,
          let winEl = focused.payload ?? axElement(ax, kAXMainWindowAttribute).payload,
          let rect = axRect(winEl).payload else { return .unreadable }
    // A chrome or fullscreen read that failed must not pass as absent: absent
    // chrome drops the title-bar exclusion, and an absent flag engages over
    // native fullscreen. A window without the attribute (or answering it with
    // another type) is missing, which is absent for real: borderless answers
    // AXUnknown for the subrole.
    let subrole = axString(winEl, kAXSubroleAttribute)
    let fullScreen = axBool(winEl, axFullScreenAttribute)
    let closeButton = axElement(winEl, kAXCloseButtonAttribute)
    guard !subrole.failed, !fullScreen.failed, !closeButton.failed else { return .unreadable }
    let mode = windowMode(standardWindow: subrole.payload == kAXStandardWindowSubrole,
                          hasCloseButton: closeButton.payload != nil,
                          fullScreen: fullScreen.payload ?? false)
    if mode == .fullscreen { return .fullscreen }
    // Only the title-bar measurement needs the button's rect, so it is read
    // after the fullscreen decision.
    let buttonRect = closeButton.flatMap(axRect)
    guard !buttonRect.failed,
          let clamp = jailClamp(mode: mode, frame: rect, closeButton: buttonRect.payload,
                                cornerRadius: cornerRadius) else { return .unreadable }
    return .clamp(clamp)
}

func setEngaged(_ on: Bool) {
    if on == engaged { return }
    engaged = on
    if on {
        // Disassociate first so this warp folds into the next delta the same
        // way every later warp does and pendingWarp stays honest.
        CGAssociateMouseAndMouseCursorPosition(0)
        let loc = CGEvent(source: nil)?.location ?? .zero
        let target = clampArea.map { $0.clamped(loc) } ?? loc
        virtualPos = target
        pendingWarp = CGPoint(x: target.x - loc.x, y: target.y - loc.y)
        CGWarpMouseCursorPosition(virtualPos)
    } else {
        pendingWarp = .zero
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}

func releaseJail() {
    clampArea = nil
    setEngaged(false)
}

func refresh() {
    // tap != nil: engaging disassociates the hardware mouse from the cursor,
    // and only the tap callback moves it afterwards. With no tap (tapCreate
    // failed despite trust) that would freeze the cursor outright.
    guard jailEnabled, tap != nil,
          let front = NSWorkspace.shared.frontmostApplication,
          front.bundleIdentifier == gameBundle else { return releaseJail() }
    switch gameWindow(front) {
    case .clamp(let c):
        clampArea = c
    case .unreadable:
        // Keep the last known rect. Releasing the cursor for a blip would let
        // it escape.
        break
    case .fullscreen:
        return releaseJail()
    }
    guard let area = clampArea else { return }
    setEngaged(true)
    // Re-clamp after a window move or resize so the cursor and clicks cannot
    // sit outside the new rect until the next move event.
    let target = area.clamped(virtualPos)
    if target != virtualPos {
        // accumulate: the last tap event's warp may be unconsumed
        pendingWarp.x += target.x - virtualPos.x
        pendingWarp.y += target.y - virtualPos.y
        virtualPos = target
        CGWarpMouseCursorPosition(virtualPos)
    }
    // Self-heal: something may have re-associated the cursor (display change,
    // wake from sleep, another process) or disabled the tap. Both idempotent.
    CGAssociateMouseAndMouseCursorPosition(0)
    if let t = tap, !CGEvent.tapIsEnabled(tap: t) {
        CGEvent.tapEnable(tap: t, enable: true)
    }
}
