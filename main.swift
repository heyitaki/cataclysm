// mousejail: confine the cursor to a game's window while it is frontmost.
// VM-style capture: hardware deltas are disconnected from the cursor
// (CGAssociateMouseAndMouseCursorPosition) and the cursor is placed per event
// from clamped integration of the deltas, so it can never cross the window
// edge, even transiently. Locations and deltas are rewritten at the HID tap
// so the game always sees in-bounds, self-consistent events.
//
// Usage: mousejail [bundle-id] [--corner-radius points]
//        mousejail --release     restore normal cursor association and exit
//
// Defaults to League of Legends's game client.
//
// Needs Accessibility permission, its own or its parent process's.

import Cocoa

let usage = "usage: mousejail [bundle-id] [--corner-radius points] | mousejail --release"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
}

// Under Hammerspoon this line is the whole alert, so it has to be actionable.
func failUsage(_ message: String) -> Never { fail("\(message)\n\(usage)") }

var args = CommandLine.arguments.dropFirst()
if args.contains("--release") {
    CGAssociateMouseAndMouseCursorPosition(1)
    exit(0)
}

var radiusArg: CGFloat?
var bundleArg: String?
while let arg = args.popFirst() {
    if arg == "--corner-radius" {
        guard let points = args.popFirst().flatMap(Double.init),
              points.isFinite, points >= 0 else {
            failUsage("--corner-radius needs a number of points")
        }
        radiusArg = CGFloat(points)
        continue
    }
    // reject unknown args: one used to become the bundle id and leave the jail
    // waiting silently on an app that cannot exist
    guard !arg.hasPrefix("-"), !arg.isEmpty, bundleArg == nil else {
        failUsage("unexpected argument: '\(arg)'")
    }
    bundleArg = arg
}
let gameBundle = bundleArg ?? "com.riotgames.LeagueofLegends.GameClient"
// 18 is measured off the League client, see the README for tuning
let cornerRadius = radiusArg ?? 18

let inset: CGFloat = 1
let frameRefresh: TimeInterval = 0.5
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
var tap: CFMachPort?
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

// Restore the cursor on every exit path, a stale disconnect leaves it frozen.
// Raw signal handlers calling CoreGraphics can deadlock against the tap
// thread's CG locks, so use dispatch sources.
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        CGAssociateMouseAndMouseCursorPosition(1)
        exit(0)
    }
    src.resume()
    signalSources.append(src) // a released source stops firing
}
atexit { CGAssociateMouseAndMouseCursorPosition(1) }

guard AXIsProcessTrusted() else { fail("accessibility permission missing") }

// Recover association in case a previous instance crashed mid-capture.
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
guard let tapPort = tap else { fail("could not create event tap") }
let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tapPort, 0)
CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
CGEvent.tapEnable(tap: tapPort, enable: true)

// The notification makes focus changes immediate, the timer covers geometry
// changes and is the self-heal cadence.
Timer.scheduledTimer(withTimeInterval: frameRefresh, repeats: true) { _ in refresh() }
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didActivateApplicationNotification,
    object: nil, queue: .main) { _ in refresh() }

refresh()
CFRunLoopRun()
