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
//
// Geometry and jail state live in Jail.swift, the event tap in TapHost.swift;
// this file parses arguments, wires signals and timers, and runs the loop.

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

let frameRefresh: TimeInterval = 0.5

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

startTap()

// The notification makes focus changes immediate, the timer covers geometry
// changes and is the self-heal cadence.
Timer.scheduledTimer(withTimeInterval: frameRefresh, repeats: true) { _ in refresh() }
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didActivateApplicationNotification,
    object: nil, queue: .main) { _ in refresh() }

refresh()
CFRunLoopRun()
