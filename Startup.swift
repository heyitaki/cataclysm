// Startup-order primitives (spec "First run"): instance ownership and the
// install-location gate. Foundation-only so the test harness can exercise
// both without touching AppKit or any system state beyond a temp file.

import Foundation

// Exclusive advisory lock on a file, held open for the process lifetime.
// Acquiring the lock is what makes an instance the owner; the kernel releases
// it on any exit, SIGKILL included, so no stale lock can lock the app out.
// A running-applications query is a read with no ownership and is not a
// substitute: two copies launched at the same moment can each look, each see
// nothing, and each proceed.
final class InstanceLock {
    private let path: String
    private var fd: Int32 = -1

    // Set when the lock file itself could not be opened (a file sitting where
    // the parent directory belongs, a permissions problem, a full disk). Nil
    // after a lost contest: the caller tells those apart because the first
    // is a startup failure to explain and the second is a running instance.
    private(set) var openFailure: String?

    init(path: String) {
        self.path = path
    }

    // Creates parent directories as needed. Returns false when another live
    // process (or another open descriptor) holds the lock, or when the lock
    // file cannot be opened at all (openFailure set). Either way this
    // instance is not the owner and must touch nothing.
    func acquire() -> Bool {
        guard fd < 0 else { return true }
        openFailure = nil
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        // O_CLOEXEC: the relaunch helper must not inherit the descriptor,
        // or the instance it opens loses the lock contest to a dead process.
        let openFd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard openFd >= 0 else {
            openFailure = "\(path): \(String(cString: strerror(errno)))"
            return false
        }
        guard flock(openFd, LOCK_EX | LOCK_NB) == 0 else {
            // Only EWOULDBLOCK means another live holder; anything else (a
            // filesystem without flock, say) is an environment failure and
            // must not read as "already running".
            if errno != EWOULDBLOCK {
                openFailure = "\(path): \(String(cString: strerror(errno)))"
            }
            close(openFd)
            return false
        }
        fd = openFd
        return true
    }

    // For tests; the app never releases, it just exits.
    func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }
}

// The install gate (startup step 3): running from a mounted disk image or an
// app-translocation mirror gets the move-to-Applications screen and nothing
// else. The mounted image is read-only, its /Volumes path is not stable
// across mounts, and ejecting it under a registered agent leaves a job whose
// executable is gone. ~/Downloads is allowed: BundleProgram keeps the
// watcher's executable path bundle-relative.
func isBlockedInstallLocation(_ bundlePath: String) -> Bool {
    bundlePath.hasPrefix("/Volumes/") || bundlePath.contains("/AppTranslocation/")
}
