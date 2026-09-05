// Harness for the watcher primitives (Watcher.swift): the poll loop's
// release decision including the startup case, the registration plan, and
// the legacy LaunchAgents plist round-trip. Pure
// functions; no launchd, no files, no system state.
//
// Build and run: make test

import Foundation

var passed = 0
var failed = 0

func check(_ cond: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if cond { passed += 1 } else {
        failed += 1
        let text = detail()
        print("FAIL: \(name)\(text.isEmpty ? "" : ": " + text)")
    }
}

func checkEq<T: Equatable>(_ got: T, _ want: T, _ name: String) {
    check(got == want, name, "got \(got), want \(want)")
}

@main
struct WatcherTests {
    static func main() {
        releaseTests()
        presenceTests()
        registrationPlanTests()
        derivationTests()
        legacyPlistTests()
        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }

    static func releaseTests() {
        // Startup (previous nil): absent releases once, the SIGKILL-took-
        // both case where the restarted watcher never sees a transition.
        checkEq(watcherShouldRelease(previous: nil, present: false), true,
                "startup with app absent releases")
        checkEq(watcherShouldRelease(previous: nil, present: true), false,
                "startup with app present does not release")

        // Steady state: only the present-to-absent transition releases.
        checkEq(watcherShouldRelease(previous: true, present: false), true,
                "present-to-absent transition releases")
        checkEq(watcherShouldRelease(previous: false, present: false), false,
                "absent-to-absent does not re-release")
        checkEq(watcherShouldRelease(previous: true, present: true), false,
                "present-to-present does not release")
        checkEq(watcherShouldRelease(previous: false, present: true), false,
                "absent-to-present does not release")
    }

    // The watcher shares the app's bundle id, so it and any second watcher
    // (legacy job beside the SMAppService agent) can appear in its own
    // running-applications query; only a process not under --watch counts.
    static func presenceTests() {
        let argv: (pid_t) -> [String] = { pid in
            switch pid {
            case 500, 502: return ["/x/cataclysm", "--watch"]
            case 501: return ["/x/cataclysm"]
            default: return []
            }
        }
        checkEq(watcherSeesApp(runningPIDs: [], ownPID: 500, argumentsOf: argv),
                false, "no matching process: absent")
        checkEq(watcherSeesApp(runningPIDs: [500], ownPID: 500, argumentsOf: argv),
                false, "only the watcher itself: absent")
        checkEq(watcherSeesApp(runningPIDs: [500, 502], ownPID: 500, argumentsOf: argv),
                false, "two watchers and no app: absent")
        checkEq(watcherSeesApp(runningPIDs: [500, 502, 501], ownPID: 500,
                               argumentsOf: argv),
                true, "two watchers plus the app: present")
        checkEq(watcherSeesApp(runningPIDs: [501], ownPID: 500, argumentsOf: argv),
                true, "the app alone: present")
        checkEq(watcherSeesApp(runningPIDs: [503], ownPID: 500, argumentsOf: argv),
                true, "unreadable arguments: counted as the app")

        // KERN_PROCARGS2 parse: argc, exec path, NUL padding, argv, then env.
        var bytes: [UInt8] = [2, 0, 0, 0]
        bytes += Array("/x/cataclysm".utf8) + [0, 0, 0]
        bytes += Array("/x/cataclysm".utf8) + [0]
        bytes += Array("--watch".utf8) + [0]
        bytes += Array("HOME=/u".utf8) + [0]
        checkEq(parseProcArgs(bytes), ["/x/cataclysm", "--watch"],
                "parses argc arguments and ignores the environment")
        checkEq(parseProcArgs([1, 0, 0]), [], "truncated header: empty")
        checkEq(parseProcArgs([3, 0, 0, 0] + Array("/x".utf8) + [0, 0]
                              + Array("a".utf8) + [0]),
                ["a"], "argc beyond the buffer stops at the end")

        // Live read of this harness's own argv, which is the case the
        // watcher relies on for a sibling watcher.
        let own = processArguments(pid: getpid())
        checkEq(own.first?.hasSuffix("watcher-tests") ?? false, true,
                "own argv reads back through sysctl")
    }

    static func registrationPlanTests() {
        checkEq(watcherRegistrationPlan(statusEnabled: false, legacyCurrent: false,
                                        versionChanged: true),
                WatcherRegistrationPlan(unregisterFirst: false, register: true),
                "never registered: register without unregistering")
        checkEq(watcherRegistrationPlan(statusEnabled: true, legacyCurrent: false,
                                        versionChanged: true),
                WatcherRegistrationPlan(unregisterFirst: true, register: true),
                "version change on an enabled agent: unregister then register")
        checkEq(watcherRegistrationPlan(statusEnabled: true, legacyCurrent: false,
                                        versionChanged: false),
                WatcherRegistrationPlan(unregisterFirst: false, register: false),
                "same version, enabled: leave it alone")
        checkEq(watcherRegistrationPlan(statusEnabled: false, legacyCurrent: false,
                                        versionChanged: false),
                WatcherRegistrationPlan(unregisterFirst: false, register: true),
                "same version but nothing loaded: register")
        // The legacy job is the active mechanism on a machine SMAppService
        // refuses; agent.status never reads enabled there, and re-registering
        // every launch would boot the working job out first.
        checkEq(watcherRegistrationPlan(statusEnabled: false, legacyCurrent: true,
                                        versionChanged: false),
                WatcherRegistrationPlan(unregisterFirst: false, register: false),
                "same version, legacy job current: leave it alone")
        checkEq(watcherRegistrationPlan(statusEnabled: false, legacyCurrent: true,
                                        versionChanged: true),
                WatcherRegistrationPlan(unregisterFirst: false, register: true),
                "version change on a legacy job: register (SMAppService retried)")
    }

    // The runtime and the smoke gate both consume these; a drift here would
    // let the gate validate a different job than the app registers.
    static func derivationTests() {
        checkEq(watcherJobLabel(bundleID: "io.github.heyitaki.cataclysm"),
                "io.github.heyitaki.cataclysm.watch",
                "label derives from the bundle id")
        checkEq(legacyWatcherPlistLocation(
                    home: URL(fileURLWithPath: "/Users/friend"),
                    bundleID: "io.github.heyitaki.cataclysm").path,
                "/Users/friend/Library/LaunchAgents/"
                    + "io.github.heyitaki.cataclysm.watch.plist",
                "legacy plist lives in the user's LaunchAgents")
        checkEq(watcherExecutable(
                    inBundle: URL(fileURLWithPath: "/Applications/Cataclysm.app")),
                "/Applications/Cataclysm.app/Contents/MacOS/cataclysm",
                "executable path points inside the bundle")
    }

    static func legacyPlistTests() {
        let label = "io.github.heyitaki.cataclysm.watch"
        let bundleID = "io.github.heyitaki.cataclysm"
        let exec = "/Users/friend/Downloads/Cataclysm.app/Contents/MacOS/cataclysm"

        guard let data = try? legacyWatcherPlistData(
                label: label, bundleID: bundleID, executablePath: exec),
              let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any]
        else {
            check(false, "legacy plist generates and parses")
            return
        }

        checkEq(plist["Label"] as? String, label, "Label matches the file name")
        checkEq(plist["ProgramArguments"] as? [String], [exec, "--watch"],
                "ProgramArguments is the absolute path plus --watch")
        checkEq((plist["KeepAlive"] as? [String: Bool])?["SuccessfulExit"], false,
                "KeepAlive is SuccessfulExit = false")
        checkEq(plist["AssociatedBundleIdentifiers"] as? String, bundleID,
                "AssociatedBundleIdentifiers names the app")
        // BundleProgram is only supported for SMAppService-installed plists;
        // the legacy job must not carry it.
        checkEq(plist["BundleProgram"] == nil, true, "no BundleProgram in legacy plist")

        // The moved-bundle check reads the same path back out.
        checkEq(legacyWatcherExecutablePath(inPlistData: data), exec,
                "executable path round-trips")
        checkEq(legacyWatcherExecutablePath(inPlistData: Data("junk".utf8)), nil,
                "unparseable data reads as no path")
        let bare = try! PropertyListSerialization.data(
            fromPropertyList: ["Label": label], format: .xml, options: 0)
        checkEq(legacyWatcherExecutablePath(inPlistData: bare), nil,
                "plist without ProgramArguments reads as no path")
    }
}
