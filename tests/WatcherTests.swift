// Harness for the watcher primitives (Watcher.swift): the poll loop's
// release decision including the startup case, the registration plan, the
// launchctl-output spawn check, and the legacy LaunchAgents plist
// round-trip. Pure functions; no launchd, no files, no system state.
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
        spawnResolutionTests()
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
        // refuses; agent.status reads not registered there (no smd record),
        // and re-registering every launch would boot the working job out
        // first.
        checkEq(watcherRegistrationPlan(statusEnabled: false, legacyCurrent: true,
                                        versionChanged: false),
                WatcherRegistrationPlan(unregisterFirst: false, register: false),
                "same version, legacy job current: leave it alone")
        checkEq(watcherRegistrationPlan(statusEnabled: false, legacyCurrent: true,
                                        versionChanged: true),
                WatcherRegistrationPlan(unregisterFirst: false, register: true),
                "version change on a legacy job: register (SMAppService retried)")
        // The legacy job holds the shared label, so status reads enabled
        // too; the plan still asks for the unregister, and the runtime is
        // what treats its failure as expected in that state.
        checkEq(watcherRegistrationPlan(statusEnabled: true, legacyCurrent: true,
                                        versionChanged: true),
                WatcherRegistrationPlan(unregisterFirst: true, register: true),
                "version change with the legacy job holding the label: unregister then register")
    }

    static func spawnResolutionTests() {
        // The label is what the bundled plist's Label key must match.
        checkEq(watcherLabel, "io.github.heyitaki.cataclysm.watch", "watcher label")
        checkEq(watcherPlistName, "io.github.heyitaki.cataclysm.watch.plist", "plist name")
        let exec = "/Applications/Cataclysm.app/Contents/MacOS/cataclysm"
        let loadedOnly = """
        io.github.heyitaki.cataclysm.watch = {
        \targuments = {
        \t\t\(exec)
        \t\t--watch
        \t}
        \tstate = not running
        }
        """
        let running = loadedOnly.replacingOccurrences(
            of: "state = not running", with: "pid = 512")
        checkEq(launchctlPidResolvesExecutable(loadedOnly, executablePath: exec,
                                               pathForPid: { _ in exec }),
                false, "the absolute path alone does not prove a spawn")
        checkEq(launchctlPidResolvesExecutable(running, executablePath: exec,
                                               pathForPid: { $0 == 512 ? exec : nil }),
                true, "a live pid running the in-bundle executable resolves")
        checkEq(launchctlPidResolvesExecutable(running, executablePath: exec,
                                               pathForPid: { _ in "/usr/bin/true" }),
                false, "a pid running something else does not resolve")
        checkEq(launchctlPidResolvesExecutable(running, executablePath: exec,
                                               pathForPid: { _ in nil }),
                false, "an unreadable pid path does not resolve")
        checkEq(launchctlPidResolvesExecutable(running, executablePath: "",
                                               pathForPid: { _ in "" }),
                false, "empty expected path never resolves")

        let dump = """
        io.github.heyitaki.cataclysm.watch = {
        \tactive count = 1
        \tstate = running
        \tprogram identifier = Contents/MacOS/cataclysm (mode: 2)
        \tpid = 4821
        }
        """
        checkEq(launchctlPid(inOutput: dump), 4821, "pid line parses")
        checkEq(launchctlPid(inOutput: "\tpid = 4821 (spawned)"), 4821,
                "annotated pid line still parses the leading digits")
        checkEq(launchctlPid(inOutput: "state = not running"), nil,
                "no pid line reads as no process")
        checkEq(launchctlPid(inOutput: "\tpid = junk"), nil,
                "non-numeric pid reads as no process")
        checkEq(launchctlPid(inOutput: ""), nil, "empty output has no pid")
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
