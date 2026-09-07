// Event-tap creation and lifecycle: the HID head-insert tap whose callback
// rewrites locations and deltas so the game only ever sees in-bounds,
// self-consistent events, and the scroll filter's own tail-append tap.

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
    // The release that ends a deferred title-bar drag. After this callback
    // returns, so the AX reads do not hold this event past the tap timeout;
    // the event is the proof of the release, so refresh does not re-read the
    // button state.
    if type == .leftMouseUp, engageDeferred {
        DispatchQueue.main.async { refresh(leftReleased: true) }
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

// Returns whether the tap came up. False is never fatal: the app keeps
// running and shows the feature as unavailable (a lost or missing
// Accessibility grant is the common cause and is recoverable).
func startTap() -> Bool {
    tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                            options: .defaultTap, eventsOfInterest: mask,
                            callback: callback, userInfo: nil)
    guard let tapPort = tap else { return false }
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tapPort, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tapPort, enable: true)
    return true
}

// Invalidating the mach port also invalidates its run loop source, so the
// callback can never fire again on a revoked grant.
func stopTap() {
    if let t = tap {
        CGEvent.tapEnable(tap: t, enable: false)
        CFMachPortInvalidate(t)
    }
    tap = nil
}

// Scroll filter tap. Its own tail-append tap on scrollWheel only, so it sees
// whatever vendor drivers produced and gets the last word.
// Never add the scrollWheel bit to the jail's head-insert mask: the masks are
// disjoint on purpose, so no event ever runs through both callbacks and a
// wheel notch can never reach the jail's warp path.

var scrollTap: CFMachPort?
// One long-lived value: residue and the burst timer must survive across
// events; a fresh instance per event silently breaks sub-1.0 multipliers.
var scrollState = ScrollFilterState()

// decideScrollEvent's time parameter is SECONDS; CGEvent.timestamp is mach
// ticks (~41.7ns). Read the timebase once at startup (lazy global). Passing
// ticks raw makes every event look like a burst boundary, so residue resets
// each time and sub-1.0 multipliers emit nothing.
let machTicksToSeconds: Double = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return Double(info.numer) / Double(info.denom) / 1_000_000_000
}()

let scrollMask: CGEventMask = 1 << CGEventType.scrollWheel.rawValue

let scrollCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = scrollTap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }

    // Capture originals before any setter runs: the line-delta setter
    // synthesizes the point and fixed-point fields, so a read after a write
    // returns what the write derived, not what the hardware sent.
    let vertical = AxisDeltas(
        line: event.getIntegerValueField(.scrollWheelEventDeltaAxis1),
        point: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),
        fixedPt: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
    let horizontal = AxisDeltas(
        line: event.getIntegerValueField(.scrollWheelEventDeltaAxis2),
        point: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2),
        fixedPt: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2))
    let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
    let scrollPhase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
    let momentumPhase = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
    let time = Double(event.timestamp) * machTicksToSeconds

    let decision = decideScrollEvent(
        vertical: vertical,
        horizontal: horizontal,
        isContinuous: isContinuous,
        scrollPhase: scrollPhase,
        momentumPhase: momentumPhase,
        verticalConfig: scrollVerticalConfig,
        horizontalConfig: scrollHorizontalConfig,
        altTrackpadDetection: scrollAltDetection,
        time: time,
        state: &scrollState)

    if scrollDump {
        print("scroll t=\(String(format: "%.4f", time))"
            + " cont=\(isContinuous ? 1 : 0) phase=\(scrollPhase)"
            + " momentum=\(momentumPhase)"
            + " v[\(axisDescription(vertical))] h[\(axisDescription(horizontal))]"
            + " -> \(decisionDescription(decision))")
    }

    switch decision {
    case .passUnchanged:
        return Unmanaged.passUnretained(event)
    case .swallow:
        // Returning nil from the callback is the swallow.
        return nil
    case .rewrite(let v, let h):
        // A nil axis carried nothing: leave its fields untouched. flatten
        // must come from the same per-axis config that produced the deltas.
        if let v = v {
            applyAxisDeltas(v, to: event, axis: .vertical,
                            flatten: scrollVerticalConfig.flatten)
        }
        if let h = h {
            applyAxisDeltas(h, to: event, axis: .horizontal,
                            flatten: scrollHorizontalConfig.flatten)
        }
        return Unmanaged.passUnretained(event)
    }
}

private func axisDescription(_ d: AxisDeltas) -> String {
    "line=\(d.line) point=\(d.point) fixed=\(d.fixedPt)"
}

private func decisionDescription(_ decision: ScrollDecision) -> String {
    switch decision {
    case .passUnchanged:
        return "pass"
    case .swallow:
        return "swallow"
    case .rewrite(let v, let h):
        let vs = v.map(axisDescription) ?? "untouched"
        let hs = h.map(axisDescription) ?? "untouched"
        return "rewrite v[\(vs)] h[\(hs)]"
    }
}

func startScrollTap() -> Bool {
    scrollTap = CGEvent.tapCreate(tap: .cghidEventTap, place: .tailAppendEventTap,
                                  options: .defaultTap, eventsOfInterest: scrollMask,
                                  callback: scrollCallback, userInfo: nil)
    guard let tapPort = scrollTap else { return false }
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tapPort, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tapPort, enable: true)
    return true
}

func stopScrollTap() {
    if let t = scrollTap {
        CGEvent.tapEnable(tap: t, enable: false)
        CFMachPortInvalidate(t)
    }
    scrollTap = nil
}

// Self-heal, run by refresh() whenever it engages or defers: macOS disables
// taps under load or on wake, and the disabled-type callback only runs if
// events still reach it. No-op while the tap was never started.
func revive(_ port: CFMachPort?) {
    if let t = port, !CGEvent.tapIsEnabled(tap: t) {
        CGEvent.tapEnable(tap: t, enable: true)
    }
}
