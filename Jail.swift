// Jail engagement state and AX window measurement: the pure clamp geometry
// lives in JailMath.swift; this file owns the AX reads and the
// engaged/virtual-position bookkeeping the tap callback integrates against.

import Cocoa

let inset: CGFloat = 1
// AX calls run on the thread that services the tap, and one refresh makes
// several. Unbounded calls into a stalled game would freeze the cursor via
// tap timeout.
let axTimeout: Float = 0.05

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

func axElement(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &ref) == .success,
          let el = ref, CFGetTypeID(el) == AXUIElementGetTypeID() else { return nil }
    return (el as! AXUIElement)
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

// AX half of the title-bar measurement; the inference rules live with the
// rest of the pure geometry in JailMath.swift.
func titleBarHeight(_ winEl: AXUIElement, frame: CGRect) -> CGFloat {
    let closeButton = axElement(winEl, kAXCloseButtonAttribute).flatMap(axRect)
    return inferredTitleBarHeight(closeButton: closeButton, frame: frame)
}

func gameClamp(_ app: NSRunningApplication) -> Clamp? {
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(ax, axTimeout)
    guard let winEl = axElement(ax, kAXFocusedWindowAttribute)
        ?? axElement(ax, kAXMainWindowAttribute) else { return nil }
    guard var rect = axRect(winEl) else { return nil }
    let titleBar = titleBarHeight(winEl, frame: rect)
    rect.origin.y += titleBar
    rect.size.height -= titleBar
    let inner = rect.insetBy(dx: inset, dy: inset)
    // insetBy returns CGRect.null once a side is too thin to inset, and null's
    // infinite origin turns virtualPos into NaN permanently: NaN never compares
    // equal, so every later re-clamp warps again. Keep the last known rect.
    guard !inner.isEmpty else { return nil }
    return Clamp(rect: inner, titleBar: titleBar, cornerRadius: cornerRadius)
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

func refresh() {
    // tap != nil: engaging disassociates the hardware mouse from the cursor,
    // and only the tap callback moves it afterwards. With no tap (tapCreate
    // failed despite trust) that would freeze the cursor outright.
    guard jailEnabled, tap != nil,
          let front = NSWorkspace.shared.frontmostApplication,
          front.bundleIdentifier == gameBundle else {
        clampArea = nil
        setEngaged(false)
        return
    }
    // On a transient AX failure keep the last known rect. Releasing the
    // cursor for a blip would let it escape.
    if let c = gameClamp(front) {
        clampArea = c
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
