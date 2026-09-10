// Watcher and registration primitives: the release decision for the --watch
// poll loop, the registration plan, the spawn check, and the legacy
// ~/Library/LaunchAgents plist the app writes when SMAppService refuses the
// self-signed identity. Foundation-only so the test harness can exercise the
// pure parts without launchd, AppKit, or any system state.

import Foundation

let cataclysmBundleID = "io.github.heyitaki.cataclysm"
let watcherLabel = "\(cataclysmBundleID).watch"
// The launchctl domain target of the job, for print/bootout/bootstrap.
var watcherJobTarget: String { "gui/\(getuid())/\(watcherLabel)" }
let watcherPlistName = "\(watcherLabel).plist"
let legacyWatcherPlistURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/LaunchAgents/\(watcherPlistName)")
// The absolute path the legacy plist carries (BundleProgram is only supported
// under SMAppService). Derived from bundleURL on every read so a moved bundle
// is noticed, never cached.
var watcherExecutablePath: String {
    Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/cataclysm").path
}

// One decision per poll tick. `previous` nil is the watcher's own startup: if
// the app is already absent, release once before entering the loop: a
// watcher that launchd just restarted after a SIGKILL observes absent
// followed by absent and would never see a transition. After startup, release
// only on a present-to-absent transition; a redundant release would be
// harmless (the call is idempotent) but is not emitted.
func watcherShouldRelease(previous: Bool?, present: Bool) -> Bool {
    !present && previous != false
}

// The argument that selects the watcher process. Shared by the entry point,
// the legacy plist, and the watcher's presence test below.
let watcherFlag = "--watch"

// The watcher is the same bundle as the app, so a running-applications query
// by bundle id could return the watcher itself, or a second watcher process
// (one launchd is still reaping while its replacement starts). Counting any
// watcher would make the app look present forever and every release would be
// skipped, so only a process not running under --watch counts as the app. The
// own-PID check is a shortcut that also holds when the kernel refuses the
// argument read.
func watcherSeesApp(runningPIDs: [pid_t], ownPID: pid_t,
                    argumentsOf: (pid_t) -> [String]) -> Bool {
    runningPIDs.contains { $0 != ownPID && !argumentsOf($0).contains(watcherFlag) }
}

// argv of a live process, read through sysctl KERN_PROCARGS2. Empty when the
// kernel refuses (another user's process, or one that exited between the
// query and the read).
func processArguments(pid: pid_t) -> [String] {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
    return parseProcArgs(Array(buffer.prefix(size)))
}

// KERN_PROCARGS2 layout: a native-endian Int32 argc, the executable path,
// NUL padding, then argc NUL-terminated arguments (the environment follows
// and is ignored). Pure so the test harness can pin the parse.
func parseProcArgs(_ bytes: [UInt8]) -> [String] {
    guard bytes.count > 4 else { return [] }
    let argc = Int(bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
    var index = 4
    while index < bytes.count, bytes[index] != 0 { index += 1 }
    while index < bytes.count, bytes[index] == 0 { index += 1 }
    var args: [String] = []
    while args.count < argc, index < bytes.count {
        var end = index
        while end < bytes.count, bytes[end] != 0 { end += 1 }
        args.append(String(decoding: bytes[index..<end], as: UTF8.self))
        index = end + 1
    }
    return args
}

// What registerWatcher must do, decided from one status snapshot: an enabled
// agent on a version change is unregistered first (SMAppService may not
// launch an agent whose executable changed otherwise), and registration runs
// unless the same version is already loaded by either mechanism. The legacy
// job counts (legacyCurrent: loaded, and its stored path is this bundle's)
// because agent.status never reads enabled on a machine SMAppService
// refuses, and registering anyway would boot the working job out on every
// launch. Pure so the sequencing crash recovery depends on is pinned by
// tests.
struct WatcherRegistrationPlan: Equatable {
    let unregisterFirst: Bool
    let register: Bool
}

func watcherRegistrationPlan(statusEnabled: Bool, legacyCurrent: Bool,
                             versionChanged: Bool) -> WatcherRegistrationPlan {
    WatcherRegistrationPlan(unregisterFirst: statusEnabled && versionChanged,
                            register: !(statusEnabled || legacyCurrent) || versionChanged)
}

// The one launchctl runner. Most callers only branch on the exit code.
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

// Whether launchd holds the job right now, by either mechanism.
func watcherJobLoaded() -> Bool {
    runLaunchctl(["print", watcherJobTarget]).code == 0
}

// The true executable of a running process, from the kernel rather than argv
// (the watcher's argv[0] is the bare "cataclysm" the bundled plist carries).
func executablePath(ofPid pid: Int32) -> String? {
    // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN); the macro itself does not
    // import into Swift.
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return String(cString: buffer)
}

// The job's running pid from a launchctl print dump (a "pid = 12345" line);
// nil when the job has no live process. Only the leading digits are read, so
// a dump format that annotates the pid still parses.
func launchctlPid(inOutput output: String) -> Int32? {
    for rawLine in output.split(separator: "\n") {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("pid = ") else { continue }
        return Int32(line.dropFirst("pid = ".count).prefix(while: \.isNumber))
    }
    return nil
}

// A live pid whose true executable (pathForPid, proc_pidpath in production)
// matches the in-bundle path: proof that launchd ran the program, not only
// that it loaded the definition. The absolute path appearing in the dump
// proves nothing: a BundleProgram job launchd cannot spawn (no Team ID, so
// its LWCR update fails) still shows the path resolved, which once let a
// hollow registration pass as a running watcher. An empty expected path can
// never count as resolved. A pid launchd is still initializing runs
// xpcproxy, so it does not match either.
func launchctlPidResolvesExecutable(_ output: String, executablePath: String,
                                    pathForPid: (Int32) -> String?) -> Bool {
    guard !executablePath.isEmpty,
          let pid = launchctlPid(inOutput: output) else { return false }
    return pathForPid(pid) == executablePath
}

// The runtime's post-registration probe: polls `launchctl print` for up to
// 15s (30 x 0.5s) until a live pid under the label runs this bundle's
// executable. KeepAlive's SuccessfulExit key implies RunAtLoad
// (launchd.plist(5)), so a job launchd accepted spawns on registration; the
// poll covers the spawn latency. The window has to outlast launchd's 10s
// respawn throttle: a label that failed to spawn before (the hollow
// registration an update replaces) gets its first attempt only after that
// delay, and a 10s window closed just before it. Blocks for the whole window
// when the job never spawns.
func pollWatcherSpawn() -> (code: Int32, output: String, resolved: Bool) {
    let executable = watcherExecutablePath
    var code: Int32 = -1
    var output = ""
    for attempt in 0..<30 {
        (code, output) = runLaunchctl(["print", watcherJobTarget])
        if code == 0, launchctlPidResolvesExecutable(output, executablePath: executable,
                                                     pathForPid: executablePath(ofPid:)) {
            return (code, output, true)
        }
        if attempt < 29 { usleep(500_000) }
    }
    return (code, output, false)
}

// The legacy job's plist. Two deliberate differences from the bundled
// SMAppService plist: ProgramArguments carries an absolute executable path
// (BundleProgram is only supported for plists installed through SMAppService),
// and the caller rewrites the file whenever the app notices it moved.
func legacyWatcherPlistData(label: String, bundleID: String,
                            executablePath: String) throws -> Data {
    let plist: [String: Any] = [
        "Label": label,
        "ProgramArguments": [executablePath, watcherFlag],
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
