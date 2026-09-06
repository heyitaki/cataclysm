// Pure logic for the --smoke-register acceptance gate: the per-step report
// line and the launchctl-output check that launchd spawned the watcher's
// executable inside the app bundle.
// Foundation-only so the test harness can exercise both without launchd or
// any system state; the fallible glue lives in SmokeGate.swift.

import Foundation

// One printed line per gate step. Detail is appended only on failure: a PASS
// line stays grep-ably uniform, a FAIL line carries what to report.
func smokeStepLine(_ step: String, pass: Bool, detail: String = "") -> String {
    let head = "\(pass ? "PASS" : "FAIL") \(step)"
    guard !pass, !detail.isEmpty else { return head }
    return "\(head): \(detail)"
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
// proves nothing for either job: the legacy job always echoes its
// ProgramArguments path, and a BundleProgram job launchd cannot spawn (no
// Team ID, so its LWCR update fails) can still show the path resolved, which
// once let a hollow registration pass as a running watcher. An empty
// expected path can never count as resolved. A pid launchd is still
// initializing runs xpcproxy, so it does not match either.
func launchctlPidResolvesExecutable(_ output: String, executablePath: String,
                                    pathForPid: (Int32) -> String?) -> Bool {
    guard !executablePath.isEmpty,
          let pid = launchctlPid(inOutput: output) else { return false }
    return pathForPid(pid) == executablePath
}
