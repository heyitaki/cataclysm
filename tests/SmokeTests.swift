// Harness for the smoke-gate primitives (Smoke.swift): step-line formatting
// and the launchctl-output spawn check. Pure functions; no
// launchd, no files, no system state.
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
struct SmokeTests {
    static func main() {
        stepLineTests()
        spawnResolutionTests()
        pidTests()
        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }

    static func stepLineTests() {
        checkEq(smokeStepLine("acquire instance lock", pass: true),
                "PASS acquire instance lock", "pass line is bare")
        checkEq(smokeStepLine("register watcher", pass: false,
                              detail: "Operation not permitted"),
                "FAIL register watcher: Operation not permitted",
                "fail line carries the detail")
        checkEq(smokeStepLine("bootout legacy job", pass: false),
                "FAIL bootout legacy job", "fail without detail stays bare")
        // Detail is failure diagnostics; a passing step never prints it.
        checkEq(smokeStepLine("status readback", pass: true, detail: "status = 1"),
                "PASS status readback", "pass line drops the detail")
    }

    // The one spawn check both mechanisms rely on.
    static func spawnResolutionTests() {
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
    }

    static func pidTests() {
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
}
