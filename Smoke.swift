// Pure logic for the --smoke-register acceptance gate (spec "3a
// acceptance"): the per-step report line and the launchctl-output check that
// launchd resolved the watcher's executable inside the app bundle.
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

// launchctl print proves launchd resolved the job's executable inside the
// bundle when the absolute in-bundle path appears in the dump: BundleProgram
// resolves to a `program = <path>` line, and the legacy job carries the same
// path in its arguments block. An empty expected path can never count as
// resolved.
func launchctlOutputResolvesExecutable(_ output: String,
                                       executablePath: String) -> Bool {
    !executablePath.isEmpty && output.contains(executablePath)
}

// The job's running pid from a launchctl print dump (a "pid = 12345" line);
// nil when the job has no live process. An SMAppService BundleProgram job
// keeps its program identifier bundle-relative in the dump until spawn, so
// the pid (checked against proc_pidpath by the caller) is what proves
// launchd resolved the executable inside the bundle. Only the leading digits
// are read, so a dump format that annotates the pid still parses.
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
// that it loaded the definition. The legacy job's dump always carries its
// absolute ProgramArguments path, so this is the only check that means
// anything for that job. An empty expected path can never count as resolved.
func launchctlPidResolvesExecutable(_ output: String, executablePath: String,
                                    pathForPid: (Int32) -> String?) -> Bool {
    guard !executablePath.isEmpty,
          let pid = launchctlPid(inOutput: output) else { return false }
    return pathForPid(pid) == executablePath
}

// The SMAppService resolution decision: the absolute path in the dump, or a
// live pid running the in-bundle executable. Either proves launchd resolved
// BundleProgram inside the bundle.
func smokeResolution(output: String, executablePath: String,
                     pathForPid: (Int32) -> String?) -> Bool {
    launchctlOutputResolvesExecutable(output, executablePath: executablePath)
        || launchctlPidResolvesExecutable(output, executablePath: executablePath,
                                          pathForPid: pathForPid)
}
