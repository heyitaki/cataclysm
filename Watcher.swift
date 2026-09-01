// Watcher and registration primitives (spec "Crash recovery and the
// watcher"): the release decision for the --watch poll loop, the version gate
// for unregister-then-re-register on updates, and the legacy
// ~/Library/LaunchAgents plist the app writes when SMAppService refuses the
// self-signed identity. Foundation-only so the test harness can exercise all
// of it without launchd, AppKit, or any system state.

import Foundation

// One decision per poll tick. `previous` nil is the watcher's own startup: if
// the app is already absent, release once before entering the loop — a
// watcher that launchd just restarted after a SIGKILL observes absent
// followed by absent and would never see a transition. After startup, release
// only on a present-to-absent transition; a redundant release would be
// harmless (the call is idempotent) but is not emitted.
func watcherShouldRelease(previous: Bool?, present: Bool) -> Bool {
    !present && previous != false
}

// Every release changes the watcher executable, and SMAppService may not
// launch an agent whose executable changed unless it is re-registered
// (unregister first, per its header). nil means no registration has ever
// succeeded, which likewise needs one.
func needsWatcherReregistration(lastRegistered: String?, current: String) -> Bool {
    lastRegistered != current
}

// What registerWatcher must do, decided from one status snapshot: an enabled
// agent on a version change is unregistered first (SMAppService may not
// launch an agent whose executable changed otherwise), and registration runs
// unless the same version is already enabled. Pure so the sequencing that
// crash recovery depends on is pinned by tests.
struct WatcherRegistrationPlan: Equatable {
    let unregisterFirst: Bool
    let register: Bool
}

func watcherRegistrationPlan(statusEnabled: Bool,
                             versionChanged: Bool) -> WatcherRegistrationPlan {
    WatcherRegistrationPlan(unregisterFirst: statusEnabled && versionChanged,
                            register: !statusEnabled || versionChanged)
}

// MARK: - Shared job derivations

// Used by both the app runtime and the smoke gate, so the gate always
// validates exactly the label, plist path, and executable path the runtime
// will register. Parameterized (no Bundle or FileManager reads) so the test
// harness can pin the derivations.
func watcherJobLabel(bundleID: String) -> String {
    "\(bundleID).watch"
}

func legacyWatcherPlistLocation(home: URL, bundleID: String) -> URL {
    home.appendingPathComponent(
        "Library/LaunchAgents/\(watcherJobLabel(bundleID: bundleID)).plist")
}

func watcherExecutable(inBundle bundleURL: URL) -> String {
    bundleURL.appendingPathComponent("Contents/MacOS/cataclysm").path
}

// The one launchctl runner. Callers that only branch on the exit code drop
// the output; the smoke gate reports it in FAIL details.
@discardableResult
func runLaunchctl(_ arguments: [String]) -> (code: Int32, output: String) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    proc.arguments = arguments
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = pipe
    do { try proc.run() } catch { return (-1, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

// The legacy job's plist. Two deliberate differences from the bundled
// SMAppService plist: ProgramArguments carries an absolute executable path
// (BundleProgram is only supported for plists installed through SMAppService),
// and the caller rewrites the file whenever the app notices it moved.
func legacyWatcherPlistData(label: String, bundleID: String,
                            executablePath: String) throws -> Data {
    let plist: [String: Any] = [
        "Label": label,
        "ProgramArguments": [executablePath, "--watch"],
        "KeepAlive": ["SuccessfulExit": false],
        "AssociatedBundleIdentifiers": bundleID,
    ]
    return try PropertyListSerialization.data(
        fromPropertyList: plist, format: .xml, options: 0)
}

// Reads the executable path back out of an existing legacy plist, for the
// moved-bundle check. nil for unparseable data or a plist without one.
func legacyWatcherExecutablePath(inPlistData data: Data) -> String? {
    guard let plist = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any],
          let args = plist["ProgramArguments"] as? [String]
    else { return nil }
    return args.first
}
