// Harness for the startup primitives (Startup.swift): instance-lock
// ownership, conflict, release, parent-directory creation, unopenable paths,
// and the install-location gate's path rules. Locks only ever touch files
// under a scratch temp directory; no system state.
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

let scratchDir = NSTemporaryDirectory() + "cataclysm-startup-tests-\(getpid())"

func cleanup() {
    try? FileManager.default.removeItem(atPath: scratchDir)
}

@main
struct StartupTests {
    static func main() {
        lockTests()
        installLocationTests()
        cleanup()
        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }

    static func lockTests() {
        let path = scratchDir + "/a/b/instance.lock"

        // acquire creates missing parent directories and takes ownership
        let first = InstanceLock(path: path)
        checkEq(first.acquire(), true, "first acquire succeeds")
        checkEq(FileManager.default.fileExists(atPath: path), true,
                "lock file created with parent directories")

        // flock treats separate open descriptions as independent owners, so a
        // second lock on the same path conflicts even in-process — the same
        // way a second launched copy would.
        let second = InstanceLock(path: path)
        checkEq(second.acquire(), false, "second acquire loses while held")
        checkEq(second.openFailure, nil, "a lost contest is not an open failure")

        // acquire on an already-held lock is idempotent for the owner
        checkEq(first.acquire(), true, "re-acquire by the owner succeeds")

        // release frees the lock for the next taker
        first.release()
        checkEq(second.acquire(), true, "acquire succeeds after release")
        second.release()

        // an unopenable path (parent is a file, so mkdir and open both fail)
        // reports not-owner rather than trapping
        let blocker = scratchDir + "/blocker"
        FileManager.default.createFile(atPath: blocker, contents: nil)
        let bad = InstanceLock(path: blocker + "/x/instance.lock")
        checkEq(bad.acquire(), false, "unopenable lock path is not acquired")
        check(bad.openFailure?.hasPrefix(blocker) == true,
              "unopenable lock path reports the open failure",
              "got \(String(describing: bad.openFailure))")
    }

    static func installLocationTests() {
        checkEq(isBlockedInstallLocation("/Volumes/Cataclysm/Cataclysm.app"),
                true, "mounted image blocked")
        checkEq(isBlockedInstallLocation("/Volumes/Cataclysm 1/Cataclysm.app"),
                true, "second mount of same volume name blocked")
        checkEq(isBlockedInstallLocation(
                    "/private/var/folders/ab/T/AppTranslocation/0AB1/d/Cataclysm.app"),
                true, "translocated copy blocked")
        checkEq(isBlockedInstallLocation("/Applications/Cataclysm.app"),
                false, "Applications allowed")
        checkEq(isBlockedInstallLocation("/Users/friend/Downloads/Cataclysm.app"),
                false, "Downloads allowed (BundleProgram keeps the agent relative)")
        checkEq(isBlockedInstallLocation("/Users/friend/Volumes/Cataclysm.app"),
                false, "non-root Volumes path allowed")
        checkEq(isBlockedInstallLocation("/VolumesBackup/Cataclysm.app"),
                false, "prefix must be the /Volumes/ directory itself")
    }
}
