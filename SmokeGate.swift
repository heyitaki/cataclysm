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
                   detail: "another instance holds \(lockPath)")
        else { return 1 }
        lockHeld = true
        // The gate registers and unregisters the same agent the shipping app
        // uses. A machine where an installed copy already registered the
        // watcher is refused up front: proceeding would tear down the live
        // registration on the cleanup path, breaking "leave no trace".
        guard step("watcher not already registered", agent.status != .enabled,
                   detail: "an installed Cataclysm's watcher is registered; "
                       + "unregister it (Reset everything and quit, or "
                       + "System Settings > Login Items) before running the gate")
        else { return 1 }
        if smAppServicePath() {
            print("SMOKE PASS (SMAppService)")
            return 0
        }
        // SMAppService refused. The app's runtime falls back to the legacy
        // LaunchAgents job in exactly this case, so the gate repeats the same
        // check through that mechanism (spec: "If registration is refused,
        // run the same check against the ~/Library/LaunchAgents fallback").
        cleanupSM()
        if legacyPath() {
            print("SMOKE PASS (legacy bootstrap; SMAppService refused)")
            return 0
        }
        print("SMOKE FAIL")
        return 1
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
        // (proc_pidpath) matching the in-bundle path. KeepAlive's
        // SuccessfulExit key implies RunAtLoad (launchd.plist(5)), so the
        // watcher spawns on registration; poll to cover the spawn latency.
        var printCode: Int32 = -1
        var output = ""
        var resolved = false
        for _ in 0..<20 {
            (printCode, output) = runLaunchctl(
                ["print", "gui/\(getuid())/\(watcherLabel)"])
            if printCode == 0 {
                resolved = smokeResolution(output: output,
                                           executablePath: executablePath,
                                           pathForPid: processPath)
                if resolved { break }
            }
            usleep(500_000)
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
        let (code, output) = runLaunchctl(
            ["print", "gui/\(getuid())/\(watcherLabel)"])
        guard step("launchctl print shows the legacy job", code == 0,
                   detail: "exit \(code): \(firstLine(of: output))")
        else { return false }
        guard step("legacy executable resolved inside the bundle",
                   launchctlOutputResolvesExecutable(output,
                                                     executablePath: executablePath),
                   detail: "expected \(executablePath); launchd has "
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
        try? agent.unregister()
        smRegistered = false
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

    // The true executable of a running process, from the kernel rather than
    // argv (the watcher's argv[0] is the bare "cataclysm" the plist carries).
    private func processPath(_ pid: Int32) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN); the macro itself does
        // not import into Swift.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
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
