// mousejail: confine the cursor to a game's window while it is frontmost.
// VM-style capture: hardware deltas are disconnected from the cursor
// (CGAssociateMouseAndMouseCursorPosition) and the cursor is placed per event
// from clamped integration of the deltas, so it can never cross the window
// edge, even transiently. Locations and deltas are rewritten at the HID tap
// so the game always sees in-bounds, self-consistent events.
//
// Usage: mousejail [bundle-id] [--corner-radius points] [--no-accel]
//                  [scroll options]
//        mousejail --release     restore normal cursor association and exit
//
// Defaults to League of Legends's game client.
//
// Needs Accessibility permission, its own or its parent process's.
//
// Geometry and jail state live in Jail.swift, the event tap in TapHost.swift;
// this file parses arguments, wires signals and timers, and runs the loop.

import Cocoa

let usage = """
usage: mousejail [bundle-id] [--corner-radius points] [--no-accel] [scroll options]
       mousejail --release
scroll options (any one enables the scroll filter; defaults: inverted vertical,
natural horizontal, flatten at 1 line, multiplier 1.0, primary detection):
  --scroll --no-invert-vertical --invert-horizontal --no-flatten
  --lines <1-1000> --multiplier <0.001-100> --alt-trackpad --dump-scroll
"""

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
var noAccel = false
// Scroll filter (spec phase 2), opt-in per launch: any scroll flag enables the
// tap, so tuning flags never silently do nothing. Numeric flags clamp through
// the ScrollFilter helpers rather than failing, matching the settings-load
// rule the spec sets for out-of-range values.
var scrollEnabled = false
var scrollInvertVertical = true
var scrollInvertHorizontal = false
var scrollFlatten = true
var scrollLines = 1
var scrollMulThousandths = 1_000
var scrollAltFlag = false
var scrollDumpFlag = false
while let arg = args.popFirst() {
    switch arg {
    case "--no-accel":
        noAccel = true
    case "--corner-radius":
        guard let points = args.popFirst().flatMap(Double.init),
              points.isFinite, points >= 0 else {
            failUsage("--corner-radius needs a number of points")
        }
        radiusArg = CGFloat(points)
    case "--scroll":
        scrollEnabled = true
    case "--no-invert-vertical":
        scrollEnabled = true
        scrollInvertVertical = false
    case "--invert-horizontal":
        scrollEnabled = true
        scrollInvertHorizontal = true
    case "--no-flatten":
        scrollEnabled = true
        scrollFlatten = false
    case "--lines":
        guard let lines = args.popFirst().flatMap(Int.init) else {
            failUsage("--lines needs an integer count")
        }
        scrollEnabled = true
        scrollLines = clampedLinesPerNotch(lines)
    case "--multiplier":
        guard let multiplier = args.popFirst().flatMap(Double.init) else {
            failUsage("--multiplier needs a number")
        }
        scrollEnabled = true
        scrollMulThousandths = clampedMulThousandths(fromMultiplier: multiplier)
    case "--alt-trackpad":
        scrollEnabled = true
        scrollAltFlag = true
    case "--dump-scroll":
        scrollEnabled = true
        scrollDumpFlag = true
    default:
        // reject unknown args: one used to become the bundle id and leave the
        // jail waiting silently on an app that cannot exist
        guard !arg.hasPrefix("-"), !arg.isEmpty, bundleArg == nil else {
            failUsage("unexpected argument: '\(arg)'")
        }
        bundleArg = arg
    }
}
let gameBundle = bundleArg ?? "com.riotgames.LeagueofLegends.GameClient"
// 18 is measured off the League client, see the README for tuning
let cornerRadius = radiusArg ?? 18

// Immutable snapshots the scroll tap callback reads; flatten, lines, and
// multiplier are shared across axes, inversion is per axis.
let scrollVerticalConfig = ScrollAxisConfig(
    invert: scrollInvertVertical, flatten: scrollFlatten,
    linesPerNotch: scrollLines, mulThousandths: scrollMulThousandths)
let scrollHorizontalConfig = ScrollAxisConfig(
    invert: scrollInvertHorizontal, flatten: scrollFlatten,
    linesPerNotch: scrollLines, mulThousandths: scrollMulThousandths)
let scrollAltDetection = scrollAltFlag
let scrollDump = scrollDumpFlag

let frameRefresh: TimeInterval = 0.5

// Declared before the exit handlers so they can reference it; assigned only
// when --no-accel asks for acceleration control.
var pointerAccel: PointerAccel?

// Restore the cursor on every exit path, a stale disconnect leaves it frozen.
// Raw signal handlers calling CoreGraphics can deadlock against the tap
// thread's CG locks, so use dispatch sources. Acceleration is restored first,
// matching the spec's reset ordering; both handlers run on the main thread,
// which PointerAccel.restore() requires. restore() is idempotent, so the
// signal path re-running it through atexit is fine.
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        pointerAccel?.restore()
        CGAssociateMouseAndMouseCursorPosition(1)
        exit(0)
    }
    src.resume()
    signalSources.append(src) // a released source stops firing
}
atexit {
    pointerAccel?.restore()
    CGAssociateMouseAndMouseCursorPosition(1)
}

guard AXIsProcessTrusted() else { fail("accessibility permission missing") }

// Recover association in case a previous instance crashed mid-capture.
CGAssociateMouseAndMouseCursorPosition(1)

// Pointer acceleration off (spec phase 1), opt-in per launch. enable() owns
// the 5s reassert timer and the didWake reassert. Status goes to stderr,
// which Hammerspoon only surfaces if the helper later dies, because a failed
// HID write feels identical to the curve merely being different.
if noAccel {
    let accel = PointerAccel()
    accel.onWriteHealthChange = { healthy in
        FileHandle.standardError.write(Data((healthy
            ? "pointer acceleration: control recovered\n"
            : "pointer acceleration: HID write failing\n").utf8))
    }
    accel.enable()
    // Only a read that round-trips proves the HID client is real; report the
    // feature as pending, not on, until then (enable()'s timer keeps trying).
    if !accel.clientResponsive {
        FileHandle.standardError.write(Data(
            "pointer acceleration: HID client unresponsive, will keep retrying\n".utf8))
    }
    pointerAccel = accel
}

startTap()
if scrollEnabled { startScrollTap() }

// The notification makes focus changes immediate, the timer covers geometry
// changes and is the self-heal cadence for both taps.
Timer.scheduledTimer(withTimeInterval: frameRefresh, repeats: true) { _ in
    refresh()
    reviveScrollTap()
}
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didActivateApplicationNotification,
    object: nil, queue: .main) { _ in refresh() }

refresh()
CFRunLoopRun()
