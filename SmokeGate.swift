// The --smoke-register acceptance gate (spec "3a acceptance", run before the
// Hammerspoon lua is retired): prove a watcher can be registered from the
// real signed bundle by one of the two mechanisms, then leave no trace.
// Prints one PASS/FAIL line per step and exits 0 only when a complete path —
// SMAppService, or the legacy bootstrap after an SMAppService refusal —
// passed every step including its own cleanup. Cleanup (unregister, bootout,
// plist and lock-file removal) is guaranteed on every exit by a defer plus a
// signal guard. This mode never touches taps, the acceleration property,
// cursor association, or UI.

import Foundation
import ServiceManagement

final class SmokeGate {
    // Label, plist path, and executable path come from the shared derivations
    // in Watcher.swift, so the gate validates exactly what the runtime uses.
    private let watcherLabel = watcherJobLabel(bundleID: cataclysmBundleID)
    private let agent = SMAppService.agent(plistName: watcherPlistName)
    private let lockPath: String
    private let lock: InstanceLock
    private var legacyPlistURL: URL {
        legacyWatcherPlistLocation(
            home: FileManager.default.homeDirectoryForCurrentUser,
            bundleID: cataclysmBundleID)
    }
    private var executablePath: String {
        watcherExecutable(inBundle: Bundle.main.bundleURL)
    }

    // Cleanup flags, flipped the moment each piece of state exists, so the
    // guard undoes exactly what is live on any exit, signal included.
    private var lockHeld = false
    private var smRegistered = false
    private var legacyBootstrapped = false
    private var legacyPlistWritten = false
    private var signalSources: [DispatchSourceSignal] = []

    init() {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        lockPath = base.appendingPathComponent(cataclysmBundleID)
            .appendingPathComponent("instance.lock").path
        lock = InstanceLock(path: lockPath)
    }

    func run() -> Int32 {
        installSignalGuard()
        defer { cleanup() }
        guard step("acquire instance lock", lock.acquire(),
                   detail: lock.openFailure ?? "another instance holds \(lockPath)")
        else { return 1 }
        lockHeld = true
        // The gate registers and unregisters the same agent the shipping app
        // uses. A machine where an installed copy already registered the
        // watcher is refused up front: proceeding would tear down the live
        // registration on the cleanup path, breaking "leave no trace".
        guard step("watcher not already registered", agent.status != .enabled,
                   detail: "an installed Cataclysm's watcher agent "
                       + "(\(watcherLabel)) is registered; switch it off "
                       + "under System Settings > Login Items before "
                       + "running the gate")
        else { return 1 }
        // Same refusal for the legacy mechanism: legacyPath() boots out the
        // label, then overwrites and deletes the plist at this exact path, so
        // an installed copy registered through the fallback would lose its
        // crash recovery. The instance lock does not cover this: the
        // installed app need not be running for its agent to be loaded.
        let legacyLive = runLaunchctl(
            ["print", "gui/\(getuid())/\(watcherLabel)"]).code == 0
            || FileManager.default.fileExists(atPath: legacyPlistURL.path)
        guard step("legacy watcher not already installed", !legacyLive,
                   detail: "an installed Cataclysm's legacy watcher is "
                       + "present; remove it (launchctl bootout "
                       + "gui/\(getuid())/\(watcherLabel); rm "
                       + "\(legacyPlistURL.path)) before running the gate")
        else { return 1 }
        if smAppServicePath() {
            guard noTraceLeft() else {
                print("SMOKE FAIL")
                return 1
            }
            print("SMOKE PASS (SMAppService)")
            return 0
        }
        // SMAppService refused. The app's runtime falls back to the legacy
        // LaunchAgents job in exactly this case, so the gate repeats the same
        // check through that mechanism (spec: "If registration is refused,
        // run the same check against the ~/Library/LaunchAgents fallback").
        cleanupSM()
        // A PASS must leave no registered agent; while the SM agent cannot be
        // torn down, a legacy pass would print PASS over live residue.
        guard step("SMAppService agent torn down", !smRegistered,
                   detail: "unregister keeps failing; not attempting legacy")
        else {
            print("SMOKE FAIL")
            return 1
        }
        if legacyPath() {
            guard noTraceLeft() else {
                print("SMOKE FAIL")
                return 1
            }
            print("SMOKE PASS (legacy bootstrap; SMAppService refused)")
            return 0
        }
        print("SMOKE FAIL")
        return 1
    }

    // The last step on either path. BTM keys launch items by label, so the
    // legacy plist written under the shared label re-enables the SMAppService
    // agent's record (left behind by a register() that spawn-failed), and smd
    // re-submits that job to launchd within a second of the legacy bootout
    // freeing the label: the agent reads .enabled and runs while every
    // earlier step reported PASS. So the verdict is taken from the end
    // state, polled for 3s with the agent unregistered again whenever it
    // comes back.
    private func noTraceLeft() -> Bool {
        var enabled = true
        var loaded = true
        for _ in 0..<6 {
            if agent.status == .enabled {
                smRegistered = true
                cleanupSM()
            }
            enabled = agent.status == .enabled
            loaded = runLaunchctl(["print", "gui/\(getuid())/\(watcherLabel)"]).code == 0
            usleep(500_000)
        }
        return step("no watcher left behind", !enabled && !loaded,
                    detail: enabled
                        ? "the SMAppService agent is registered again (BTM label collision)"
                        : "the job is still loaded in launchd")
    }

    // Prints the step's line; detail reaches the line only on failure.
    private func step(_ name: String, _ pass: Bool, detail: String = "") -> Bool {
        print(smokeStepLine(name, pass: pass, detail: detail))
        return pass
    }

    // register → status readback → launchctl print resolution → unregister.
    private func smAppServicePath() -> Bool {
        do {
            try agent.register()
            smRegistered = true
            _ = step("register watcher (SMAppService)", true)
        } catch {
            return step("register watcher (SMAppService)", false,
                        detail: error.localizedDescription)
        }
        let status = agent.status
        guard step("status readback is enabled", status == .enabled,
                   detail: "status rawValue = \(status.rawValue)")
        else { return false }
        // BundleProgram stays relative in the print dump until launchd spawns
        // the job ("program identifier = Contents/MacOS/cataclysm", "resolve
        // program"), so resolution is proven by whichever appears first: the
        // absolute path in the dump, or the spawned pid's true executable
        // (proc_pidpath) matching the in-bundle path.
        let (printCode, output, resolved) = pollLaunchctlPrint(label: watcherLabel) {
            smokeResolution(output: $0, executablePath: executablePath,
                            pathForPid: executablePath(ofPid:))
        }
        guard step("launchctl print shows the job", printCode == 0,
                   detail: "exit \(printCode): \(firstLine(of: output))")
        else { return false }
        guard step("executable resolved inside the bundle", resolved,
                   detail: "expected \(executablePath); launchd has "
                       + programLines(of: output))
        else { return false }
        do {
            try agent.unregister()
            smRegistered = false
            return step("unregister watcher (SMAppService)", true)
        } catch {
            return step("unregister watcher (SMAppService)", false,
                        detail: error.localizedDescription)
        }
    }

    // write plist → bootstrap → launchctl print resolution → bootout →
    // delete. The legacy job carries an absolute ProgramArguments path
    // because BundleProgram is only supported under SMAppService.
    private func legacyPath() -> Bool {
        do {
            let data = try legacyWatcherPlistData(
                label: watcherLabel, bundleID: cataclysmBundleID,
                executablePath: executablePath)
            try FileManager.default.createDirectory(
                at: legacyPlistURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            // A definition launchd already holds would mask the fresh file.
            runLaunchctl(["bootout", "gui/\(getuid())/\(watcherLabel)"])
            try data.write(to: legacyPlistURL)
            legacyPlistWritten = true
            _ = step("write legacy plist", true)
        } catch {
            return step("write legacy plist", false,
                        detail: error.localizedDescription)
        }
        let (bootCode, bootOutput) = runLaunchctl(
            ["bootstrap", "gui/\(getuid())", legacyPlistURL.path])
        legacyBootstrapped = bootCode == 0
        guard step("bootstrap legacy job", bootCode == 0,
                   detail: "exit \(bootCode): \(firstLine(of: bootOutput))")
        else { return false }
        // The legacy dump always echoes the absolute ProgramArguments path,
        // so only a live pid running that executable proves launchd ran the
        // job rather than merely loaded it (spec: the fallback is "measured
        // to run, not merely to load").
        let (code, output, spawned) = pollLaunchctlPrint(label: watcherLabel) {
            launchctlPidResolvesExecutable($0, executablePath: executablePath,
                                           pathForPid: executablePath(ofPid:))
        }
        guard step("launchctl print shows the legacy job", code == 0,
                   detail: "exit \(code): \(firstLine(of: output))")
        else { return false }
        guard step("legacy job spawned the in-bundle executable", spawned,
                   detail: "expected a pid running \(executablePath); launchd has "
                       + programLines(of: output))
        else { return false }
        let (outCode, outOutput) = runLaunchctl(
            ["bootout", "gui/\(getuid())/\(watcherLabel)"])
        legacyBootstrapped = outCode != 0
        guard step("bootout legacy job", outCode == 0,
                   detail: "exit \(outCode): \(firstLine(of: outOutput))")
        else { return false }
        do {
            try FileManager.default.removeItem(at: legacyPlistURL)
            legacyPlistWritten = false
            return step("delete legacy plist", true)
        } catch {
            return step("delete legacy plist", false,
                        detail: error.localizedDescription)
        }
    }

    // MARK: - Cleanup guard

    // Idempotent: the success paths already ran their unregister/bootout/
    // delete steps and cleared the flags, so the defer finds nothing to undo.
    private func cleanup() {
        cleanupSM()
        cleanupLegacy()
        if lockHeld {
            // The gate must leave no lock file behind (a normal app run keeps
            // its own for the process lifetime; this process is done with it).
            unlink(lockPath)
            lock.release()
            lockHeld = false
        }
    }

    private func cleanupSM() {
        guard smRegistered else { return }
        // Clear the flag only on success: an unregister that keeps throwing
        // must keep the defer retrying and block the legacy path, or the gate
        // could exit 0 with the agent still registered.
        do {
            try agent.unregister()
            smRegistered = false
        } catch {}
    }

    private func cleanupLegacy() {
        if legacyBootstrapped {
            runLaunchctl(["bootout", "gui/\(getuid())/\(watcherLabel)"])
            legacyBootstrapped = false
        }
        if legacyPlistWritten {
            try? FileManager.default.removeItem(at: legacyPlistURL)
            legacyPlistWritten = false
        }
    }

    // Dispatch sources need no run loop, only a live queue, so they work in
    // this procedural mode. The handler may race a step on the main thread;
    // every cleanup call is idempotent and best-effort, which is the most a
    // signal path can promise.
    private func installSignalGuard() {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            src.setEventHandler { [weak self] in
                self?.cleanup()
                exit(1)
            }
            src.resume()
            signalSources.append(src) // a released source stops firing
        }
    }

    private func firstLine(of output: String) -> String {
        output.split(separator: "\n", maxSplits: 1,
                     omittingEmptySubsequences: true)
            .first.map(String.init) ?? ""
    }

    // What launchd actually resolved, for the resolution-failure detail: the
    // program/arguments-adjacent lines of the print dump, so a path-form
    // mismatch is diagnosable from the FAIL line alone.
    private func programLines(of output: String) -> String {
        let lines = output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("program") || $0.contains("cataclysm") }
        return lines.isEmpty ? "no program lines" : lines.joined(separator: " | ")
    }
}
