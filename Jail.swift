// Jail geometry and engagement state: the rounded-rect clamp, AX window
// measurement, and the engaged/virtual-position bookkeeping the tap callback
// integrates against.

import Cocoa

let inset: CGFloat = 1
// AX calls run on the thread that services the tap, and one refresh makes
// several. Unbounded calls into a stalled game would freeze the cursor via
// tap timeout.
let axTimeout: Float = 0.05
// Fallback title-bar inference: common windowed aspect ratios. The title bar
// is the window height left over above the content. Ratio gaps exceed the
// accepted band at any playable width, so at most one matches.
let contentRatios: [CGFloat] = [9.0 / 16.0, 10.0 / 16.0, 3.0 / 4.0, 4.0 / 5.0]

// Main-thread only: the tap source, timer, and notifications share the main
// run loop. Moving any of them off it would need synchronization here.
var clampArea: Clamp?
var virtualPos = CGPoint.zero
var engaged = false
// A warp folds its displacement into the next mouse event's delta. Track it
// so integration sees only hand movement, otherwise our own warps feed back
// and the cursor rockets away.
var pendingWarp = CGPoint.zero

func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
    return min(max(v, lo), hi)
}

// Built once per frame refresh, so a radius can never describe a rect that has
// moved on. The top arc is shrunk by the title bar the rect already excludes: a
// circle that much smaller is internally tangent to the real one, so it can only
// hold the cursor further inside the window.
struct Clamp {
    let rect: CGRect
    let topRadius: CGFloat
    let bottomRadius: CGFloat
    init(rect: CGRect, titleBar: CGFloat) {
        // half the shorter side is the largest radius the two arc centres fit in
        let cap = min(rect.width, rect.height) / 2
        self.rect = rect
        self.topRadius = min(max(0, cornerRadius - titleBar), cap)
        self.bottomRadius = min(cornerRadius, cap)
    }

    // A rect clamp holds the cursor in the frame but not in the window, and the
    // difference is the four rounded corners: out there a click lands on the app
    // behind, which drops the game out of focus and releases the jail.
    func clamped(_ p: CGPoint) -> CGPoint {
        let q = CGPoint(x: clamp(p.x, rect.minX, rect.maxX),
                        y: clamp(p.y, rect.minY, rect.maxY))
        let top = q.y < rect.midY
        let radius = top ? topRadius : bottomRadius
        guard radius > 0 else { return q }
        let left = q.x < rect.midX
        let cx = left ? rect.minX + radius : rect.maxX - radius
        let cy = top ? rect.minY + radius : rect.maxY - radius
        let dx = q.x - cx, dy = q.y - cy
        // only the quadrant beyond both arc centres is corner, anywhere else the
        // rect clamp already holds
        guard left == (dx < 0), top == (dy < 0) else { return q }
        let d = hypot(dx, dy)
        guard d > radius else { return q }
        // Whole points, because the delta fields the callback writes are
        // integers. To nearest rather than inward: inward leaves nearly a point
        // of step between a position just inside the arc and its projection just
        // outside, so a hand crossing there twitches.
        let s = radius / d
        return CGPoint(x: (cx + dx * s).rounded(), y: (cy + dy * s).rounded())
    }
}

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

// The title bar must be excluded from the clamp or click-flicks drag the
// window and ratchet the cursor out the top. Measure it from the close
// button, which sits vertically centered in the title bar. No close button
// means borderless or fullscreen. The ratio table covers windows that hide
// their standard controls.
func titleBarHeight(_ winEl: AXUIElement, frame: CGRect) -> CGFloat {
    if let btn = axElement(winEl, kAXCloseButtonAttribute),
       let btnRect = axRect(btn) {
        let tb = btnRect.height + (btnRect.minY - frame.minY) * 2
        // a bar taller than its own window means a bad AX read, fall through
        if tb > 0 && tb < 80 && tb < frame.height { return tb }
    }
    for ratio in contentRatios {
        // 16..45 points spans the standard macOS title-bar heights
        let tb = frame.height - frame.width * ratio
        if tb >= 16 && tb <= 45 { return tb }
    }
    return 0
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
    return Clamp(rect: inner, titleBar: titleBar)
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
    guard let front = NSWorkspace.shared.frontmostApplication,
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
