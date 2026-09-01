// Event-tap creation and lifecycle: the HID head-insert tap whose callback
// rewrites locations and deltas so the game only ever sees in-bounds,
// self-consistent events.

import Cocoa

var tap: CFMachPort?

let mask: CGEventMask =
    (1 << CGEventType.mouseMoved.rawValue) |
    (1 << CGEventType.leftMouseDragged.rawValue) |
    (1 << CGEventType.rightMouseDragged.rawValue) |
    (1 << CGEventType.otherMouseDragged.rawValue) |
    (1 << CGEventType.leftMouseDown.rawValue) |
    (1 << CGEventType.leftMouseUp.rawValue) |
    (1 << CGEventType.rightMouseDown.rawValue) |
    (1 << CGEventType.rightMouseUp.rawValue) |
    (1 << CGEventType.otherMouseDown.rawValue) |
    (1 << CGEventType.otherMouseUp.rawValue)

let callback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard engaged, let area = clampArea else { return Unmanaged.passUnretained(event) }
    // Every tapped type must consume pendingWarp: clicks carry delta fields
    // too, and a warp displacement can fold into whichever event comes next.
    let dx = CGFloat(event.getDoubleValueField(.mouseEventDeltaX)) - pendingWarp.x
    let dy = CGFloat(event.getDoubleValueField(.mouseEventDeltaY)) - pendingWarp.y
    let old = virtualPos
    virtualPos = area.clamped(CGPoint(x: old.x + dx, y: old.y + dy))
    let applied = CGPoint(x: virtualPos.x - old.x, y: virtualPos.y - old.y)
    // plain assignment is correct only because the accumulated value was
    // consumed into dx/dy above
    pendingWarp = applied
    event.location = virtualPos
    // A pinned location with a large raw delta would keep delta-reading
    // consumers moving through the clamp.
    event.setDoubleValueField(.mouseEventDeltaX, value: Double(applied.x))
    event.setDoubleValueField(.mouseEventDeltaY, value: Double(applied.y))
    // Warp every event: a stray re-association is undetectable, since a cursor
    // position read still returns what we last wrote, and at a corner both axes
    // pin, so a change-gated warp would never fire where the cursor leaks.
    CGWarpMouseCursorPosition(virtualPos)
    return Unmanaged.passUnretained(event)
}

func startTap() {
    tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                            options: .defaultTap, eventsOfInterest: mask,
                            callback: callback, userInfo: nil)
    guard let tapPort = tap else { fail("could not create event tap") }
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tapPort, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tapPort, enable: true)
}
