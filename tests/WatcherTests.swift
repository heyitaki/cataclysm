// Harness for the watcher primitives (Watcher.swift): the poll loop's
// release decision including the startup case, the version gate for
// re-registration, and the legacy LaunchAgents plist round-trip. Pure
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
        reregistrationTests()
        legacyPlistTests()
        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }

    static func releaseTests() {
        // Startup (previous nil): absent releases once — the SIGKILL-took-
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

    static func reregistrationTests() {
        checkEq(needsWatcherReregistration(lastRegistered: nil, current: "0.1.0"),
                true, "never registered needs registration")
        checkEq(needsWatcherReregistration(lastRegistered: "0.1.0", current: "0.2.0"),
                true, "version change needs re-registration")
        checkEq(needsWatcherReregistration(lastRegistered: "0.1.0", current: "0.1.0"),
                false, "same version needs nothing")
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
