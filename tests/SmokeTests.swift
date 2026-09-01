// Harness for the smoke-gate primitives (Smoke.swift): step-line formatting
// and the launchctl-output executable-resolution check. Pure functions; no
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
        resolutionTests()
        combinedResolutionTests()
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

    static func resolutionTests() {
        let exec = "/Applications/Cataclysm.app/Contents/MacOS/cataclysm"
        // Shape of a real `launchctl print gui/$UID/<label>` dump for a
        // BundleProgram job: the resolved absolute path on a program line.
        let smDump = """
        io.github.heyitaki.cataclysm.watch = {
        \tactive count = 1
        \tpath = /Users/friend/Library/LaunchAgents/disabled.plist
        \tprogram = \(exec)
        }
        """
        checkEq(launchctlOutputResolvesExecutable(smDump, executablePath: exec),
                true, "program line resolves the SM job")

        // The legacy job carries the path in its arguments block instead.
        let legacyDump = """
        io.github.heyitaki.cataclysm.watch = {
        \targuments = {
        \t\t\(exec)
        \t\t--watch
        \t}
        }
        """
        checkEq(launchctlOutputResolvesExecutable(legacyDump, executablePath: exec),
                true, "arguments block resolves the legacy job")

        checkEq(launchctlOutputResolvesExecutable(
                    "program = /usr/local/bin/cataclysm", executablePath: exec),
                false, "a path outside the bundle does not resolve")
        checkEq(launchctlOutputResolvesExecutable("", executablePath: exec),
                false, "empty output does not resolve")
        checkEq(launchctlOutputResolvesExecutable(smDump, executablePath: ""),
                false, "empty expected path never resolves")

        // Deliberate heuristic, pinned: the absolute path counts wherever it
        // appears in the dump, not only on program lines. launchd puts the
        // path only on program/arguments lines for these jobs in practice;
        // tightening would couple the gate to dump formatting.
        checkEq(launchctlOutputResolvesExecutable(
                    "path = \(exec)", executablePath: exec),
                true, "any dump line containing the path counts as resolved")
    }

    // The gate's combined decision: absolute path in the dump, or a live pid
    // whose kernel-reported executable matches the in-bundle path.
    static func combinedResolutionTests() {
        let exec = "/Applications/Cataclysm.app/Contents/MacOS/cataclysm"
        let unspawned = """
        io.github.heyitaki.cataclysm.watch = {
        \tprogram identifier = Contents/MacOS/cataclysm (mode: 2)
        \tstate = not running
        }
        """
        let spawned = """
        io.github.heyitaki.cataclysm.watch = {
        \tprogram identifier = Contents/MacOS/cataclysm (mode: 2)
        \tpid = 77
        }
        """
        checkEq(smokeResolution(output: "program = \(exec)", executablePath: exec,
                                pathForPid: { _ in nil }),
                true, "absolute path resolves without consulting the pid")
        checkEq(smokeResolution(output: spawned, executablePath: exec,
                                pathForPid: { $0 == 77 ? exec : nil }),
                true, "relative dump resolves through the pid's true path")
        checkEq(smokeResolution(output: spawned, executablePath: exec,
                                pathForPid: { _ in "/usr/bin/true" }),
                false, "a pid running something else does not resolve")
        checkEq(smokeResolution(output: spawned, executablePath: exec,
                                pathForPid: { _ in nil }),
                false, "an unreadable pid path does not resolve")
        checkEq(smokeResolution(output: unspawned, executablePath: exec,
                                pathForPid: { _ in exec }),
                false, "no pid and no absolute path never resolves")
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
