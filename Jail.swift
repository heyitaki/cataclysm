// Jail engagement state and AX window measurement: the pure clamp geometry
// lives in JailMath.swift; this file owns the AX reads and the
// engaged/virtual-position bookkeeping the tap callback integrates against.

import Cocoa

// AX calls run on the thread that services the tap, and one refresh makes
// several. Unbounded calls into a stalled game would freeze the cursor via
// tap timeout.
let axTimeout: Float = 0.05
// The window's native-fullscreen state. Undocumented (the SDK only names the
// button, kAXFullScreenButtonAttribute) but what AppKit answers and window
// managers read.
let axFullScreenAttribute = "AXFullScreen"

// Main-thread only: the tap source, timer, and notifications share the main
// run loop. Moving any of them off it would need synchronization here.
var clampArea: Clamp?
var virtualPos = CGPoint.zero
var engaged = false
// Runtime gate for the whole jail feature: the app's panel toggle (and later
// its hotkey) flips it and calls refresh(). The CLI never changes it, so CLI
// behavior is unchanged.
var jailEnabled = true
// A warp folds its displacement into the next mouse event's delta. Track it
// so integration sees only hand movement, otherwise our own warps feed back
// and the cursor rockets away.
var pendingWarp = CGPoint.zero

// One attribute read with the failure kinds the callers need apart: missing
// (the window has no such attribute) is a fact about the window, failed (a
// timeout under load, the element gone) says nothing about it.
enum AXRead {
    case value(CFTypeRef), missing, failed

    var failed: Bool {
        if case .failed = self { return true }
        return false
    }

    var element: AXUIElement? {
        guard case .value(let v) = self, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    var string: String? {
        guard case .value(let v) = self else { return nil }
        return v as? String
    }

    // NSNumber bridges any number to Bool, so the CFBoolean type is checked
    // explicitly (same rule as the settings reads).
    var bool: Bool {
        guard case .value(let v) = self, CFGetTypeID(v) == CFBooleanGetTypeID() else { return false }
        return CFBooleanGetValue((v as! CFBoolean))
    }
}

func axRead(_ el: AXUIElement, _ attribute: String) -> AXRead {
    var ref: CFTypeRef?
    switch AXUIElementCopyAttributeValue(el, attribute as CFString, &ref) {
    case .success: return ref.map { .value($0) } ?? .missing
    case .noValue, .attributeUnsupported: return .missing
    default: return .failed
    }
}

func axElement(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
    axRead(parent, attribute).element
}

func axRect(_ el: AXUIElement) -> CGRect? {
    var posRef: CFTypeRef?
    var sizeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
          AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
          let posVal = posRef, let sizeVal = sizeRef else { return nil }
    var pos = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(posVal as! AXValue, .cgPoint, &pos),
          AXValueGetValue(sizeVal as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: pos, size: size)
}

// In the AX (top-left origin) coordinate space; empty when CG refuses, which
// windowMode treats as "not fullscreen by size".
func activeDisplayBounds() -> [CGRect] {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
    return ids.prefix(Int(count)).map(CGDisplayBounds)
}

// One AX measurement of the game window. unreadable is a transient AX
// failure (the caller keeps its last rect); fullscreen asks for release.
enum GameWindow {
    case unreadable, fullscreen, clamp(Clamp)
}

func gameWindow(_ app: NSRunningApplication) -> GameWindow {
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(ax, axTimeout)
    guard let winEl = axElement(ax, kAXFocusedWindowAttribute)
        ?? axElement(ax, kAXMainWindowAttribute) else { return .unreadable }
    guard let rect = axRect(winEl) else { return .unreadable }
    // A chrome or fullscreen read that failed must not pass as absent: absent
    // chrome drops the title-bar exclusion, and an absent flag engages over
    // native fullscreen. A window without the attribute answers missing, which
    // is absent for real (borderless answers AXUnknown for the subrole).
    let subrole = axRead(winEl, kAXSubroleAttribute)
    let fullScreen = axRead(winEl, axFullScreenAttribute)
    let closeButton = axRead(winEl, kAXCloseButtonAttribute)
    guard !subrole.failed, !fullScreen.failed, !closeButton.failed else { return .unreadable }
    let mode = windowMode(
        standardWindow: subrole.string == kAXStandardWindowSubrole,
        hasCloseButton: closeButton.element != nil,
        fullScreen: fullScreen.bool,
        frame: rect, displays: activeDisplayBounds())
    if mode == .fullscreen { return .fullscreen }
    guard let clamp = jailClamp(mode: mode, frame: rect,
                                closeButton: closeButton.element.flatMap(axRect),
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

func release() {
    clampArea = nil
    setEngaged(false)
}

func refresh() {
    // tap != nil: engaging disassociates the hardware mouse from the cursor,
    // and only the tap callback moves it afterwards. With no tap (tapCreate
    // failed despite trust) that would freeze the cursor outright.
    guard jailEnabled, tap != nil,
          let front = NSWorkspace.shared.frontmostApplication,
          front.bundleIdentifier == gameBundle else { return release() }
    switch gameWindow(front) {
    case .clamp(let c):
        clampArea = c
    case .unreadable:
        // Keep the last known rect. Releasing the cursor for a blip would let
        // it escape.
        break
    case .fullscreen:
        return release()
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
