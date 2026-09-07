// Jail engagement state and window measurement: the pure clamp geometry lives
// in JailMath.swift. AX failures keep its last rect once it has measured this
// engagement. Until then the window server supplies the bounds. This file owns
// both reads and the engaged/virtual-position bookkeeping for the tap callback.

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

enum ClampSource { case ax, windowList }

// Main-thread only: the tap source, timer, and notifications share the main
// run loop. Moving any of them off it would need synchronization here.
var clampArea: Clamp?
var clampSource: ClampSource?
var virtualPos = CGPoint.zero
var engaged = false
// Engage and release transitions publish to the panel state so the menu bar
// icon can show the lock.
var onEngagedChange: ((Bool) -> Void)?
// Runtime gate for the whole jail feature: the panel toggle and the hotkey
// flip it and call refresh().
var jailEnabled = true
// A warp folds its displacement into the next mouse event's delta. Track it
// so integration sees only hand movement, otherwise our own warps feed back
// and the cursor rockets away.
var pendingWarp = CGPoint.zero
// refresh() held off engaging because the left button is down from a press
// outside the clamp (a title-bar drag). Latched until the release: the tap's
// mouse-up hook refreshes so the cursor snaps into the game on release
// instead of at the next timer tick.
var engageDeferred = false

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

// One AX measurement of the game window. unreadable keeps the last AX rect,
// or tries the window server if AX has never measured this engagement.
// fullscreen asks for release.
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

// The window server's answer for the game's window, used while AX has not
// measured: it never blocks on the game, so a stalled main thread cannot
// keep the jail from engaging. Alpha 0 windows are hidden surfaces.
func windowListWindow(_ app: NSRunningApplication) -> FallbackWindow {
    guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                 kCGNullWindowID) as? [[String: Any]] else { return .none }
    let entries = windows.compactMap { info -> WindowListEntry? in
        guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
              pid == app.processIdentifier,
              (info[kCGWindowAlpha as String] as? CGFloat ?? 1) > 0,
              let bounds = info[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              let layer = info[kCGWindowLayer as String] as? Int else { return nil }
        return WindowListEntry(bounds: frame, layer: layer)
    }
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success else { return .none }
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return .none }

    // The window list and CGDisplayBounds use the same top-left global
    // coordinates as the AX reads and CGWarpMouseCursorPosition, so nothing
    // converts; NSScreen frames are bottom-left and would not do.
    return fallbackWindow(entries: entries, displays: displays.prefix(Int(count)).map(CGDisplayBounds))
}

func cursorLocation() -> CGPoint {
    CGEvent(source: nil)?.location ?? .zero
}

func setEngaged(_ on: Bool) {
    if on == engaged { return }
    engaged = on
    if on {
        // Disassociate first so this warp folds into the next delta the same
        // way every later warp does and pendingWarp stays honest.
        CGAssociateMouseAndMouseCursorPosition(0)
        let loc = cursorLocation()
        let target = clampArea.map { $0.clamped(loc) } ?? loc
        virtualPos = target
        pendingWarp = CGPoint(x: target.x - loc.x, y: target.y - loc.y)
        CGWarpMouseCursorPosition(virtualPos)
    } else {
        pendingWarp = .zero
        CGAssociateMouseAndMouseCursorPosition(1)
    }
    // After the cursor work, so an observer reads a settled state.
    onEngagedChange?(on)
}

func releaseJail() {
    clampArea = nil
    clampSource = nil
    engageDeferred = false
    setEngaged(false)
}

// leftReleased: the caller saw the left button go up, so the session button
// state, which the window server updates after the tap has passed the event
// on, is not consulted for this refresh.
func refresh(leftReleased: Bool = false) {
    // tap != nil: engaging disassociates the hardware mouse from the cursor,
    // and only the tap callback moves it afterwards. With no tap (tapCreate
    // failed despite trust) that would freeze the cursor outright.
    guard jailEnabled, tap != nil,
          let front = NSWorkspace.shared.frontmostApplication,
          front.bundleIdentifier == gameBundle else { return releaseJail() }
    switch gameWindow(front) {
    case .clamp(let c):
        clampArea = c
        clampSource = .ax
    case .unreadable:
        // Accessibility sees the close button, subrole and fullscreen flag, so
        // its measurement is better. Once it has measured, a transient failure
        // keeps its rect. The window server only stands in while Accessibility
        // has never answered for this engagement.
        if clampSource == .ax { break }
        switch windowListWindow(front) {
        case .fullscreen:
            return releaseJail()
        case .window(let mode, let frame):
            clampArea = jailClamp(mode: mode, frame: frame, closeButton: nil,
                                  cornerRadius: cornerRadius)
            if clampArea != nil { clampSource = .windowList }
        case .none:
            break
        }
    case .fullscreen:
        return releaseJail()
    }
    guard let area = clampArea else { return }
    if !engaged {
        // The session state also ends a latched deferral whose release the
        // tap missed (disabled by timeout across the mouse-up).
        let held = !leftReleased
            && CGEventSource.buttonState(.combinedSessionState, button: .left)
        let loc = held ? cursorLocation() : .zero
        engageDeferred = shouldDeferEngage(deferred: engageDeferred, leftButtonHeld: held,
                                           cursor: loc, area: area)
        // Skip the disassociate below: while not engaged it would freeze the
        // cursor mid-drag. The tap still needs reviving, for the mouse-up hook.
        if engageDeferred { return revive(tap) }
    }
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
    revive(tap)
}
