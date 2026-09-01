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
