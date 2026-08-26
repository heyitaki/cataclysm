// mousejail: confine the cursor to a game's window while it is frontmost,
// using VM-style capture: hardware mouse deltas are disconnected from the
// cursor (CGAssociateMouseAndMouseCursorPosition) and the cursor is placed
// explicitly per event from our own clamped integration of the deltas, so it
// can never cross the window edge, even transiently. Event locations and
// deltas are rewritten at the HID tap so the game and the window server
// always see in-bounds, self-consistent events.
//
// The window frame is re-read on a timer so moving the window or changing the
// game's windowed resolution is picked up automatically.
//
// Usage: mousejail [bundle-id]   confine while that app is frontmost
//                                (default: League of Legends's game client)
//        mousejail --release     restore normal cursor association and exit,
//                                recovering from an instance that died
//                                mid-capture
//
// Requires Accessibility permission (its own, or its parent process's when
// spawned by e.g. Hammerspoon).

import Cocoa

let cliArgs = CommandLine.arguments.dropFirst()
if cliArgs.contains("--release") {
    CGAssociateMouseAndMouseCursorPosition(1)
    exit(0)
}
let gameBundle = cliArgs.first(where: { !$0.hasPrefix("-") })
    ?? "com.riotgames.LeagueofLegends.GameClient"

let inset: CGFloat = 1
let frameRefresh: TimeInterval = 0.5
// Bound synchronous AX calls into the game: they run on the same thread that
// must service the event tap, and an unbounded call during a game stall would
// freeze the cursor via tap timeout. Kept small because one refresh can make
// several AX calls and their worst cases add up against that same timeout.
let axTimeout: Float = 0.05
// Fallback title-bar inference: aspect ratios of common windowed game
// resolutions; the title bar is the window height left over above the game
// content. The ratio gaps exceed the accepted title-bar range at any playable
// width, so at most one matches.
let contentRatios: [CGFloat] = [9.0 / 16.0, 10.0 / 16.0, 3.0 / 4.0, 4.0 / 5.0]

// All of this state is touched only on the main thread: the tap's run loop
// source, the refresh timer, and the workspace notifications all live on the
// main run loop. Moving any of them off it would need synchronization here.
var clampRect: CGRect?
var virtualPos = CGPoint.zero
var engaged = false
var tap: CFMachPort?
// Each CGWarpMouseCursorPosition folds its displacement into the next mouse
// event's delta; track it so integration sees only real hand movement,
// otherwise our own warps feed back and the cursor rockets away.
var pendingWarp = CGPoint.zero

func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
    return min(max(v, lo), hi)
}

func clamped(_ p: CGPoint, to r: CGRect) -> CGPoint {
    return CGPoint(x: clamp(p.x, r.minX, r.maxX), y: clamp(p.y, r.minY, r.maxY))
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

// The title bar must be excluded from the clamp: reaching it lets rapid
// click-flicks drag the window and ratchet the cursor out the top. Prefer
// measuring it from the close button (the traffic lights sit vertically
// centered in the title bar, so its height is the button band plus symmetric
// margins); a window without a close button is borderless or fullscreen and
// has no title bar. The aspect-ratio inference remains as a fallback in case
// the game window hides its standard controls.
func titleBarHeight(_ winEl: AXUIElement, frame: CGRect) -> CGFloat {
    if let btn = axElement(winEl, kAXCloseButtonAttribute),
       let btnRect = axRect(btn) {
        let tb = btnRect.height + (btnRect.minY - frame.minY) * 2
        if tb > 0 && tb < 80 { return tb }
    }
    for ratio in contentRatios {
        // 16..45 points spans the standard macOS title-bar heights
        let tb = frame.height - frame.width * ratio
        if tb >= 16 && tb <= 45 { return tb }
    }
    return 0
}

func gameClampRect(_ app: NSRunningApplication) -> CGRect? {
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(ax, axTimeout)
    guard let winEl = axElement(ax, kAXFocusedWindowAttribute)
        ?? axElement(ax, kAXMainWindowAttribute) else { return nil }
    guard var rect = axRect(winEl) else { return nil }
    let titleBar = titleBarHeight(winEl, frame: rect)
    rect.origin.y += titleBar
    rect.size.height -= titleBar
    return rect.insetBy(dx: inset, dy: inset)
}

func setEngaged(_ on: Bool) {
    if on == engaged { return }
    engaged = on
    if on {
        // Disassociate before warping so this warp folds into the next delta
        // the same way every later warp does, and pendingWarp stays honest.
        CGAssociateMouseAndMouseCursorPosition(0)
        let loc = CGEvent(source: nil)?.location ?? .zero
        let target = clampRect.map { clamped(loc, to: $0) } ?? loc
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
        clampRect = nil
        setEngaged(false)
        return
    }
    // A transient AX failure while the game is still frontmost keeps the last
    // known rect; releasing the cursor for a blip would let it escape.
    if let f = gameClampRect(front) {
        clampRect = f
    }
    guard let r = clampRect else { return }
    setEngaged(true)
    // Re-clamp after a window move or resize so the cursor and clicks cannot
    // sit outside the new rect until the next move event.
    let target = clamped(virtualPos, to: r)
    if target != virtualPos {
        // accumulate: an unconsumed warp from the last tap event may still be
        // outstanding
        pendingWarp.x += target.x - virtualPos.x
        pendingWarp.y += target.y - virtualPos.y
        virtualPos = target
        CGWarpMouseCursorPosition(virtualPos)
    }
    // Self-heal: re-assert capture in case something re-associated the
    // hardware cursor (display reconfiguration, wake from sleep, another
    // process), and re-enable the tap if macOS disabled it; both idempotent.
    CGAssociateMouseAndMouseCursorPosition(0)
    if let t = tap, !CGEvent.tapIsEnabled(tap: t) {
        CGEvent.tapEnable(tap: t, enable: true)
    }
}

let callback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard engaged, let r = clampRect else { return Unmanaged.passUnretained(event) }
    // Uniform handling for every tapped type: clicks carry delta fields too,
    // and a warp displacement can fold into whichever event comes next, so
    // all of them must consume pendingWarp or the compensation misfires.
    let dx = CGFloat(event.getDoubleValueField(.mouseEventDeltaX)) - pendingWarp.x
    let dy = CGFloat(event.getDoubleValueField(.mouseEventDeltaY)) - pendingWarp.y
    let old = virtualPos
    virtualPos = clamped(CGPoint(x: old.x + dx, y: old.y + dy), to: r)
    let applied = CGPoint(x: virtualPos.x - old.x, y: virtualPos.y - old.y)
    // plain assignment is correct only because the accumulated value was
    // consumed into dx/dy above; do not early-return between there and here
    pendingWarp = applied
    event.location = virtualPos
    // Keep the emitted event self-consistent: a pinned location with a large
    // raw delta would keep delta-reading consumers moving through the clamp.
    event.setDoubleValueField(.mouseEventDeltaX, value: Double(applied.x))
    event.setDoubleValueField(.mouseEventDeltaY, value: Double(applied.y))
    // The warp is the one WindowServer round trip per event; skip it when the
    // cursor did not move (clicks, pushing into a clamped edge at 1000 Hz).
    if applied != .zero {
        CGWarpMouseCursorPosition(virtualPos)
    }
    return Unmanaged.passUnretained(event)
}

// Restore normal cursor behavior on every exit path; a stale disconnect would
// leave the user with a frozen cursor. Signals are handled via dispatch
// sources on the main queue: raw handlers calling CoreGraphics from signal
// context can deadlock against the tap thread's CG locks, leaving the process
// alive with the cursor disconnected.
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        CGAssociateMouseAndMouseCursorPosition(1)
        exit(0)
    }
    src.resume()
    // the array exists to retain the sources; a released source stops firing
    signalSources.append(src)
}
atexit { CGAssociateMouseAndMouseCursorPosition(1) }

guard AXIsProcessTrusted() else {
    FileHandle.standardError.write(Data("accessibility permission missing\n".utf8))
    exit(1)
}

// Recover cursor association in case a previous instance crashed mid-capture.
CGAssociateMouseAndMouseCursorPosition(1)

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

tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                        options: .defaultTap, eventsOfInterest: mask,
                        callback: callback, userInfo: nil)
guard let tapPort = tap else {
    FileHandle.standardError.write(Data("could not create event tap\n".utf8))
    exit(1)
}
let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tapPort, 0)
CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
CGEvent.tapEnable(tap: tapPort, enable: true)

// The activation notification makes engage/disengage on focus change
// immediate; the timer covers geometry changes and is the self-heal cadence.
Timer.scheduledTimer(withTimeInterval: frameRefresh, repeats: true) { _ in refresh() }
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didActivateApplicationNotification,
    object: nil, queue: .main) { _ in refresh() }

refresh()
CFRunLoopRun()
