// Cataclysm app entry. `main()` dispatches on arguments before SwiftUI ever
// loads, so the watcher (`--watch`) never starts UI, never touches AppKit
// state, and can run headless under launchd.
// A plain launch runs six startup steps in order: instance lock,
// cursor re-association, install-location gate, clamped settings load, trust
// check, and only then taps, the acceleration property, and agent
// registration. Steps 1-3 run before any UI, so a duplicate launch or a
// launch from the DMG never flashes a panel.

import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Runtime globals shared with Jail/TapHost

// Loaded from the settings store during startup step 4, before any tap can
// read them.
var gameBundle = Settings.Default.targetBundleID
var cornerRadius = CGFloat(Settings.Default.cornerRadius)
var scrollVerticalConfig = ScrollAxisConfig(
    invert: true, flatten: true, linesPerNotch: 1, mulThousandths: 1_000)
var scrollHorizontalConfig = ScrollAxisConfig(
    invert: true, flatten: true, linesPerNotch: 1, mulThousandths: 1_000)
var scrollAltDetection = false
var scrollDump = false

@main
struct CataclysmMain {
    static func main() {
        let args = CommandLine.arguments.dropFirst()
        if args.contains(watcherFlag) {
            runWatcher()
        }
        // The scroll measurement flag only sets the dump global, then the
        // launch proceeds normally.
        if args.contains("--dump-scroll") {
            scrollDump = true
        }
        AppRuntime.shared.preflight()
        AppRuntime.shared.start()
        CataclysmApp.main()
    }

    // The watcher process: no UI, no taps, no property writes, and no
    // instance lock. It only ever calls the
    // idempotent release, so it can never conflict with a live app instance.
    // Deliberately tiny: launchd restarts a crashed KeepAlive job at most
    // about every 10s, so the less here that can crash, the better.
    static func runWatcher() -> Never {
        var previous: Bool?
        let timer = Timer(timeInterval: 1.0, repeats: true) { _ in
            let present = watcherSeesApp(
                runningPIDs: NSRunningApplication
                    .runningApplications(withBundleIdentifier: cataclysmBundleID)
                    .map(\.processIdentifier),
                ownPID: ProcessInfo.processInfo.processIdentifier,
                argumentsOf: processArguments(pid:))
            if watcherShouldRelease(previous: previous, present: present) {
                CGAssociateMouseAndMouseCursorPosition(1)
            }
            previous = present
        }
        // Fire once before the loop: the startup release is the case that
        // matters most (a SIGKILL that took the app and the watcher together
        // never produces a present-to-absent transition).
        timer.fire()
        RunLoop.main.add(timer, forMode: .default)
        RunLoop.main.run()
        exit(0) // unreachable; the watcher runs until launchd stops it
    }
}

// MARK: - Observable status for the panel

// Published state behind the panel's status and failure rows. Every failure
// the app can have surfaces here, because the
// panel is the app's only surface.
final class AppState: ObservableObject {
    @Published var trusted = false
    @Published var featuresRunning = false
    @Published var jailTapUp = false
    @Published var scrollTapUp = false
    // The lock is holding the cursor right now, distinct from the stored
    // jailEnabled preference: the game may not be frontmost.
    @Published var jailEngaged = false
    // A false return from the HID property write feels identical to the curve
    // merely being different, so the toggle must show failed, not checked.
    @Published var accelWriteFailing = false
    // The HID client never round-tripped a read: nothing is actually held,
    // so the feature must not present as on.
    @Published var accelUnresponsive = false
    // The acceleration property is actually taken (startAcceleration ran and
    // was not torn down). Distinct from the stored preference: on an
    // ungranted first launch the preference is on but startup step 6 has not
    // applied it yet, and the toggle must read unavailable, not checked. A
    // lost grant keeps the property held (stopFeatures leaves it alone), so
    // !trusted on its own cannot stand in for this.
    @Published var accelHeld = false
    @Published var pointerSpeedAvailable = false
    @Published var watcherRegistered = false
    @Published var watcherRequiresApproval = false
    // register() threw (SMAppService path) and the legacy bootstrap failed
    // too, or the legacy write itself failed. Lands in the panel's status
    // area, never in a log nobody reads.
    @Published var watcherError: String?
    @Published var loginItemError: String?
    // The login item was switched off in Login Items while the preference
    // is on. Shown as an approval hint, never as a failure.
    @Published var loginItemRequiresApproval = false
    // RegisterEventHotKey refused the chord (another app owns it). Shows in
    // the hotkey row rather than leaving a recorded chord that does nothing.
    @Published var hotkeyRegistrationFailed = false
    // The game picker's rows, rebuilt on panel open and on every app launch
    // or quit system-wide.
    @Published var pickerRows: [GamePickerRow] = []
}

// MARK: - Startup sequence and feature lifecycle

final class AppRuntime {
    static let shared = AppRuntime()
    let state = AppState()
    // The store the panel binds to directly: its setters publish, so a
    // control can never show a value that did not reach storage.
    let settings = Settings()

    private let lock: InstanceLock
    private var pointerAccel: PointerAccel?
    private let hotkeyCenter = HotkeyCenter()
    private var refreshTimer: Timer?
    private var trustTimer: Timer?
    private var telemetry: Telemetry?
    private var telemetryTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var pickerObservers: [NSObjectProtocol] = []
    private var onboarding: OnboardingController?
    private var signalSources: [DispatchSourceSignal] = []
    // Stamps the background spawn check a registration starts; bumped by
    // every registration so a stale result cannot act on a job that has
    // since been replaced.
    private var watcherProbeGeneration = 0

    private init() {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        lock = InstanceLock(path: base
            .appendingPathComponent(cataclysmBundleID)
            .appendingPathComponent("instance.lock").path)
    }

    // Steps 1-3. The loser of the lock, an unopenable lock file, and a
    // blocked install location each show one screen and exit 0 having touched
    // nothing: no cursor writes beyond step 2's release, no acceleration
    // property, no agent, and the exit restorers are deliberately not
    // installed yet.
    func preflight() {
        if !lock.acquire() {
            // An unopenable lock file is not a second instance: saying so
            // would send the user hunting for a process that does not exist
            // at every launch, with nothing to fix. Name the path instead.
            if let failure = lock.openFailure {
                showLockFailure(failure)
            } else {
                showDuplicateNotice()
            }
            exit(0)
        }
        // Thaw a cursor a dead instance left frozen. Needs no Accessibility
        // grant (measured), so this works ungranted.
        CGAssociateMouseAndMouseCursorPosition(1)
        if isBlockedInstallLocation(Bundle.main.bundlePath) {
            showMoveToApplicationsScreen()
            exit(0)
        }
    }

    // Steps 4-6. The trust poll runs for the whole process lifetime: it
    // dismisses onboarding on a fresh grant and catches a revoked one.
    func start() {
        // setEngaged only runs from the tap callback and the refresh timer,
        // both on the main run loop, so the publish needs no dispatch.
        onEngagedChange = { [weak self] on in self?.state.jailEngaged = on }
        applySettings()
        // The hotkey needs no Accessibility grant, so it registers before
        // trust; toggling while ungranted just flips the stored preference.
        hotkeyCenter.onHotkey = { [weak self] in
            guard let self else { return }
            // Inert while the master switch is off, like the dimmed
            // checkbox: a stray chord must not silently rewrite the stored
            // preference behind a closed panel.
            guard self.settings.enabled else { return }
            self.setJailEnabled(!self.settings.jailEnabled)
        }
        applyHotkey()
        installExitRestorers()
        state.trusted = AXIsProcessTrusted()
        // Both branches wait for the run loop, which SwiftUI starts after
        // start() returns. The taps are active (.defaultTap) from creation and
        // are serviced only from the main run loop, so a tap created here
        // would hold every mouse event until then; and registration spawns
        // launchctl synchronously on the legacy path, which stretches that
        // stall. Deferring puts both on the first run loop pass instead.
        if state.trusted {
            DispatchQueue.main.async {
                if self.settings.enabled { self.startFeatures() }
                self.registerAgentsIfNeeded()
            }
        } else {
            // The window needs the run loop; this fires once SwiftUI starts it.
            DispatchQueue.main.async { self.showOnboarding() }
        }
        trustTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) {
            [weak self] _ in self?.trustTick()
        }
        // Keep the game picker fresh for the panel's whole lifetime: a target
        // quitting while the panel is open drops to
        // the synthesized stored row with the selection unchanged. These are
        // NSWorkspace.shared.notificationCenter notifications, not
        // NotificationCenter.default ones.
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            pickerObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.rebuildGamePicker()
            })
        }
        // The heartbeat (Telemetry.swift) runs only on the normal launch
        // path of a release image: the Makefile writes CataclysmHeartbeat
        // into Info.plist, true for `make dmg` and false for local builds,
        // which then never mint an install id. The ordering in main() is
        // load-bearing: `--watch` exits before start() is ever called, so
        // neither the timer nor the immediate tick below exists in the
        // watcher process. Each tick re-reads the opt-out switch, so turning
        // it off cancels nothing in flight and simply leaves the next tick
        // ineligible.
        if Bundle.main.infoDictionary?["CataclysmHeartbeat"] as? Bool == true {
            telemetry = Telemetry(settings: settings, appVersion: appVersion)
            telemetryTimer = Timer.scheduledTimer(withTimeInterval: Telemetry.tickInterval,
                                                  repeats: true) {
                [weak self] _ in self?.telemetryTick()
            }
            // Deferred like the feature start above so the first send
            // follows the rest of startup instead of interleaving with it.
            DispatchQueue.main.async { self.telemetryTick() }
        }
    }

    private func telemetryTick() {
        telemetry?.tick(transport: AppRuntime.sendHeartbeat)
    }

    // Production transport: fire and forget. The outcome is deliberately
    // ignored; Telemetry stamps the attempt before calling this, so a failed
    // send waits out the interval rather than retrying every hour.
    private static func sendHeartbeat(_ request: URLRequest) {
        URLSession.shared.dataTask(with: request).resume()
    }

    // Reopened from the panel's warning row after a lost grant; never shown
    // while granted.
    func showOnboarding() {
        guard !state.trusted else { return }
        if onboarding == nil { onboarding = OnboardingController() }
        onboarding?.show()
    }

    private func applySettings() {
        gameBundle = settings.targetBundleID
        cornerRadius = CGFloat(settings.cornerRadius)
        jailEnabled = settings.jailEnabled
        applyScrollConfigs()
        rebuildGamePicker()
    }

    // Snapshot the running .regular apps into pure picker rows. Called on
    // panel open and on every workspace launch/terminate notification. The
    // stored target is kept whatever its activation policy: its row claims
    // "(not running)" when absent, and a target running as an accessory app
    // is still running. Known apps take their picker name from the table so
    // Riot's look-alike apps stay apart.
    func rebuildGamePicker() {
        let target = settings.targetBundleID
        let stored: String? = target == Settings.noTarget ? nil : target
        let keep = Set(pinnedApps.compactMap(\.bundleID) + [target])
        let running = NSWorkspace.shared.runningApplications
            .filter { app in
                app.activationPolicy == .regular
                    || app.bundleIdentifier.map(keep.contains) == true
            }
            .map { app in
                GamePickerCandidate(
                    bundleID: app.bundleIdentifier,
                    name: app.bundleIdentifier.flatMap(knownAppName(for:)) ?? app.localizedName)
            }
        let rows = buildGamePickerRows(
            storedBundleID: stored,
            storedName: knownAppName(for: target) ?? settings.targetDisplayName,
            pinned: pinnedApps,
            running: running, ownBundleID: cataclysmBundleID)
        // Rebuilds fire on every app launch and quit system-wide; an
        // unchanged snapshot must not republish, or the whole panel
        // re-renders (and re-resolves icons) for unrelated apps.
        if rows != state.pickerRows { state.pickerRows = rows }
    }

    private func trustTick() {
        let trusted = AXIsProcessTrusted()
        guard trusted != state.trusted else { return }
        state.trusted = trusted
        if trusted {
            onboarding?.close()
            onboarding = nil
            if settings.enabled { startFeatures() }
            registerAgentsIfNeeded()
        } else {
            // Revoked while running: the taps stop delivering and that is not
            // a crash. Re-associate, drop the features to unavailable, keep
            // polling, never exit. The acceleration property needs no grant,
            // so it stays under control.
            stopFeatures()
        }
    }

    private func startFeatures() {
        guard !state.featuresRunning else { return }
        if settings.accelerationOff { startAcceleration() }
        state.jailTapUp = startTap()
        state.scrollTapUp = startScrollTap()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) {
            [weak self] _ in
            self?.retryDownTaps()
            refresh()
            revive(scrollTap)
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { _ in refresh() }
        refresh()
        state.featuresRunning = true
    }

    // tapCreate can refuse while AXIsProcessTrusted() is already true (the
    // login-item launch race, TCC lagging a fresh grant). trustTick only acts
    // on a trust change, so without this the feature would stay down with a
    // "failed" caption until relaunch. Assign only on success so the panel
    // does not re-render every tick.
    private func retryDownTaps() {
        if !state.jailTapUp, startTap() { state.jailTapUp = true }
        if !state.scrollTapUp, startScrollTap() { state.scrollTapUp = true }
    }

    private func stopFeatures() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        stopTap()
        stopScrollTap()
        releaseJail()
        // releaseJail only re-associates from the engaged state; make the
        // release unconditional.
        CGAssociateMouseAndMouseCursorPosition(1)
        state.jailTapUp = false
        state.scrollTapUp = false
        state.featuresRunning = false
    }

    private func startAcceleration() {
        // An instance kept alive by a failed disable() (setAccelerationOff)
        // is re-enabled rather than replaced, so its claim and stored
        // original carry over. enable() is idempotent for a live instance.
        if let pointerAccel {
            pointerAccel.setSpeed(thousandths: settings.pointerSpeedThousandths)
            pointerAccel.enable()
            state.accelHeld = true
            return
        }
        let accel = PointerAccel(speedThousandths: settings.pointerSpeedThousandths)
        state.pointerSpeedAvailable = accel.linearAvailable
        accel.onLinearAvailabilityChange = { [weak self] available in
            self?.state.pointerSpeedAvailable = available
        }
        accel.onWriteHealthChange = { [weak self] healthy in
            self?.state.accelWriteFailing = !healthy
            // A healthy write proves the client round-trips too.
            if healthy { self?.state.accelUnresponsive = false }
        }
        accel.enable()
        // Only a read that round-trips proves the HID client is real; until
        // it does the panel shows the feature as failed rather than on
        // (enable()'s timer keeps retrying).
        state.accelUnresponsive = !accel.clientResponsive
        pointerAccel = accel
        state.accelHeld = true
    }

    // Everything a panel open refreshes. The store's publish forces a fresh
    // read of every setting: a value changed behind the panel (a `defaults
    // write`) never went through a publishing setter. Deferred a turn so it
    // never publishes inside the update that showed the panel.
    func panelWillAppear() {
        DispatchQueue.main.async { self.settings.objectWillChange.send() }
        rebuildGamePicker()
        refreshWatcherStatus()
        refreshLoginItemStatus()
        refreshAccelHealth()
    }

    // Re-probe on panel open: a HID client that recovers without ever passing
    // through a failing write never fires onWriteHealthChange, so the latched
    // unresponsive flag has to be re-read when someone looks.
    func refreshAccelHealth() {
        guard let pointerAccel else { return }
        state.accelUnresponsive = !pointerAccel.clientResponsive
        // A failed disable() (setAccelerationOff) keeps the instance with
        // its claim; writeFailing alone would read false and clear the
        // failure the toggle showed, while the properties are still held.
        state.accelWriteFailing = pointerAccel.writeFailing || pointerAccel.restoreFailed
    }

    // Called only after trust, so no agent is ever
    // registered on a first launch that is still ungranted or quarantined.
    private func registerAgentsIfNeeded() {
        syncLoginItem()
        registerWatcher()
    }

    // MARK: - Watcher registration

    let appVersion =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

    // The watcher agent always runs; it is not a user setting. A version
    // change unregisters first: SMAppService may not launch an agent whose
    // executable changed unless it is re-registered, and every release
    // changes the executable.
    private func registerWatcher() {
        watcherProbeGeneration += 1
        let agent = SMAppService.agent(plistName: watcherPlistName)
        let version = appVersion
        // The legacy job counts as the active mechanism only when launchd has
        // it loaded and its stored path is this bundle's: a moved bundle or a
        // plist whose bootstrap failed falls through to registration instead.
        let storedLegacyPath = legacyWatcherStoredPath
        let legacyCurrent = storedLegacyPath == watcherExecutablePath && legacyWatcherLoaded()
        let plan = watcherRegistrationPlan(
            statusEnabled: agent.status == .enabled,
            legacyCurrent: legacyCurrent,
            versionChanged: settings.lastRegisteredVersion != version)
        if plan.unregisterFirst {
            do {
                try agent.unregister()
            } catch where !legacyCurrent {
                // The stale agent is still enabled. Registering over it, or
                // installing the legacy job beside it, and then recording
                // this version would make every later launch read "same
                // version, enabled" and never retry. Surface it and leave
                // the recorded version alone so the next launch retries.
                state.watcherError = "Crash recovery update failed: "
                    + error.localizedDescription
                refreshWatcherStatus()
                return
            } catch {
                // status reads .enabled only because the legacy job holds the
                // shared label, and launchd refuses to remove a job smd did
                // not submit ("Requestor lacks required entitlement"). That
                // job is booted out by the register path below anyway, so
                // the failure is not an obstacle: falling through updates in
                // one launch instead of surfacing a red row until the next.
            }
        }
        if plan.register {
            // The legacy job and the SMAppService agent share one launchd
            // label (the fallback is the same job), so launchd holds
            // at most one of them and `bootout` on that label unloads
            // whichever is loaded. A legacy job left over from a build
            // SMAppService refused therefore has to go before register()
            // claims the label; booting it out afterwards would unload the
            // agent just registered and leave no watcher until next login
            // while status still read .enabled. A job that cannot be booted
            // out keeps recovering on its own; surface the failure and leave
            // the recorded version alone so the next launch retries.
            if let failure = bootOutLegacyWatcher() {
                state.watcherError = "Crash recovery update failed: " + failure
                refreshWatcherStatus()
                return
            }
            do {
                try agent.register()
                settings.lastRegisteredVersion = version
                state.watcherError = nil
            } catch {
                // register() also throws while the agent sits in Login
                // Items awaiting approval or switched off there. That is
                // the user's decision: never route around it with the
                // legacy job, which needs no approval at all.
                // refreshWatcherStatus() below surfaces the approval row.
                if agent.status == .requiresApproval {
                    // Recorded so later launches stop repeating the bootout
                    // and throw for a version already reconciled; a
                    // re-enable in Login Items launches from the bundle and
                    // needs no re-register for this version.
                    settings.lastRegisteredVersion = version
                    state.watcherError = nil
                } else if let failure = installLegacyWatcher() {
                    // SMAppService refused outright (the self-signed
                    // identity, or anything else): fall back to the
                    // mechanism it replaced, which has no code-signing
                    // requirement, and surface a double failure.
                    state.watcherError = "Crash recovery failed: "
                        + "\(error.localizedDescription); \(failure)"
                } else {
                    settings.lastRegisteredVersion = version
                    state.watcherError = nil
                }
            }
        }
        // A register pass rewrote or deleted the plist itself; only a pass
        // that left it alone can find it stale.
        if !plan.register { reconcileLegacyWatcherIfMoved(storedPath: storedLegacyPath) }
        refreshWatcherStatus()
        // Probed whenever the agent is what launchd should be running, not
        // only on the launch that registered it. A hollow registration
        // (accepted, .enabled, never spawned) is the normal outcome under the
        // self-signed identity, and its 15s check only completes if this
        // process survives that long: quit, logout, or a crash inside the
        // window would otherwise leave every later launch reading "same
        // version, enabled" and never installing the fallback. A re-run
        // inside the window (a trust flap) bumps the generation and drops the
        // earlier probe's result, so it needs this replacement probe too.
        if agent.status == .enabled {
            verifyWatcherSpawn(generation: watcherProbeGeneration)
        }
    }

    // SMAppService can accept a registration launchd then never runs: under
    // the self-signed identity register() succeeds and status reads .enabled,
    // but launchd fails every spawn ("Unable to get updated LWCR", because
    // BTM ignores the plist's bundle identifiers for an executable with no
    // Team ID) and throttles the respawns. A hollow registration is no crash
    // recovery, so the runtime checks for a real spawn, off the main thread
    // because the hollow case blocks for the full window. On non-spawn the
    // agent is unregistered and the legacy job installed in its place. A failed unregister is surfaced only while launchd still
    // holds the job: the legacy job cannot take the label then. With nothing
    // loaded the label is free, and stopping there would repeat identically
    // every launch (same version, status still enabled) with no watcher at
    // all. The generation stamp drops a result that lands after a later
    // registration replaced the job.
    private func verifyWatcherSpawn(generation: Int) {
        DispatchQueue.global().async {
            let probe = pollWatcherSpawn()
            DispatchQueue.main.async { [self] in
                guard generation == watcherProbeGeneration, !probe.resolved else { return }
                do {
                    try SMAppService.agent(plistName: watcherPlistName).unregister()
                } catch where watcherJobLoaded() {
                    // Asked now rather than read off the poll's last tick,
                    // which is up to 15s old and reads -1 on a failed spawn
                    // of launchctl itself.
                    state.watcherError = "Crash recovery failed: the registered "
                        + "watcher never started and could not be unregistered: "
                        + error.localizedDescription
                    refreshWatcherStatus()
                    return
                } catch {
                    // Nothing loaded under the label: the legacy bootstrap
                    // below can claim it whatever smd's record says.
                }
                if let failure = installLegacyWatcher() {
                    state.watcherError = "Crash recovery failed: the registered "
                        + "watcher never started; \(failure)"
                } else {
                    state.watcherError = nil
                }
                refreshWatcherStatus()
            }
        }
    }

    // The absolute executable path the legacy plist stores; nil without one.
    private var legacyWatcherStoredPath: String? {
        guard let data = try? Data(contentsOf: legacyWatcherPlistURL) else { return nil }
        return legacyWatcherExecutablePath(inPlistData: data)
    }

    // Writes the legacy plist with the current absolute executable path and
    // bootstraps it. Boots out first: launchd keeps the loaded definition, so
    // rewriting the file alone never reaches a job already bootstrapped.
    // Returns a failure description, or nil on success.
    private func installLegacyWatcher() -> String? {
        do {
            let data = try legacyWatcherPlistData(
                label: watcherLabel, bundleID: cataclysmBundleID,
                executablePath: watcherExecutablePath)
            try FileManager.default.createDirectory(
                at: legacyWatcherPlistURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            runLaunchctl(["bootout", watcherJobTarget])
            try data.write(to: legacyWatcherPlistURL)
            guard runLaunchctl(
                ["bootstrap", "gui/\(getuid())", legacyWatcherPlistURL.path]).code == 0
            else { return "legacy bootstrap failed" }
            return nil
        } catch {
            return "legacy plist write failed: \(error.localizedDescription)"
        }
    }

    // The legacy plist's absolute path goes stale when the app moves (the
    // ~/Downloads case BundleProgram exists to solve, which the legacy path
    // cannot use); rewrite and re-bootstrap when it no longer matches.
    private func reconcileLegacyWatcherIfMoved(storedPath: String?) {
        guard let stored = storedPath, stored != watcherExecutablePath else { return }
        if let failure = installLegacyWatcher() {
            state.watcherError = "Crash recovery failed after the app moved: \(failure)"
        }
    }

    // Launch at login is SMAppService.mainApp, independent of the watcher
    // agent. register()/unregister() throw; the failure lands in the panel's
    // status area, never in a log. An item switched off in Login Items
    // reads .requiresApproval and register() throws there (same as the
    // watcher agent): that is the user's decision, so it is never
    // re-requested and shows as an approval hint, not a failure. Turning the
    // preference off unregisters in that state too, else the entry would
    // outlive the setting and launch the app again once re-enabled there
    private func syncLoginItem() {
        let status = SMAppService.mainApp.status
        state.loginItemRequiresApproval =
            settings.launchAtLogin && status == .requiresApproval
        do {
            if settings.launchAtLogin, status != .enabled, status != .requiresApproval {
                try SMAppService.mainApp.register()
            } else if !settings.launchAtLogin,
                      status == .enabled || status == .requiresApproval {
                try SMAppService.mainApp.unregister()
            }
            state.loginItemError = nil
        } catch {
            state.loginItemError = "Launch at login failed: \(error.localizedDescription)"
        }
    }

    // Read-only status probe for the crash-recovery row, re-run on every
    // panel open. Either mechanism counts as registered: the SMAppService
    // agent, or the legacy job actually loaded in launchd (the plist file
    // alone proves nothing if bootstrap failed).
    func refreshWatcherStatus() {
        let status = SMAppService.agent(plistName: watcherPlistName).status
        state.watcherRequiresApproval = status == .requiresApproval
        state.watcherRegistered = status == .enabled || legacyWatcherLoaded()
    }

    // Read-only counterpart of syncLoginItem for panel open: a switch-off in
    // System Settings otherwise stays invisible until the checkbox is next
    // toggled. Registers and unregisters nothing.
    func refreshLoginItemStatus() {
        state.loginItemRequiresApproval =
            settings.launchAtLogin && SMAppService.mainApp.status == .requiresApproval
    }

    private func legacyWatcherLoaded() -> Bool {
        FileManager.default.fileExists(atPath: legacyWatcherPlistURL.path)
            && watcherJobLoaded()
    }

    // MARK: - Panel write-through

    // Every control writes through the settings store and applies
    // immediately. Setters are safe to call while
    // ungranted: they persist the preference, and the live half applies when
    // startFeatures() runs.

    // The master switch. Off is the trust-revoked teardown plus releasing
    // the acceleration property, so the mouse behaves as if the app had
    // quit; on restarts everything under the same trust gate as startup.
    // The stored feature preferences are untouched either way.
    func setEnabled(_ on: Bool) {
        settings.enabled = on
        if on {
            if state.trusted { startFeatures() }
            // A failed release latched accelWriteFailing; re-taking the
            // property supersedes the failed restore, so re-read the truth.
            refreshAccelHealth()
        } else {
            stopFeatures()
            releaseAcceleration()
        }
    }

    func setJailEnabled(_ on: Bool) {
        settings.jailEnabled = on
        jailEnabled = on
        if state.featuresRunning { refresh() }
    }

    // Persist the bundle id and the display name together: the synthesized
    // row needs both when the target is absent.
    func setTarget(bundleID: String, name: String) {
        settings.targetBundleID = bundleID
        settings.targetDisplayName = name
        gameBundle = bundleID
        rebuildGamePicker()
        if state.featuresRunning { refresh() }
    }

    // "Choose from Applications…": the open panel takes focus and dismisses
    // the Cataclysm panel, so the completion writes straight through the
    // settings store (via setTarget) and never assumes the panel survived;
    // the player reopens it to see the new selection.
    func chooseTargetFromApplications() {
        let chooser = NSOpenPanel()
        chooser.allowedContentTypes = [.applicationBundle]
        chooser.allowsMultipleSelection = false
        chooser.canChooseDirectories = false
        chooser.directoryURL = URL(fileURLWithPath: "/Applications")
        NSApp.activate(ignoringOtherApps: true)
        chooser.begin { [weak self] response in
            // Same self-exclusion as the running-app rows: targeting
            // Cataclysm would jail the cursor to its own panel.
            guard response == .OK, let url = chooser.url,
                  let bundle = Bundle(url: url),
                  let id = bundle.bundleIdentifier,
                  id != cataclysmBundleID else { return }
            let name = (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle.infoDictionary?["CFBundleName"] as? String)
                ?? url.deletingPathExtension().lastPathComponent
            self?.setTarget(bundleID: id, name: name)
        }
    }

    func setAccelerationOff(_ on: Bool) {
        settings.accelerationOff = on
        if on {
            // The enable half waits for trust: startup step 6 owns when the
            // property is first taken.
            guard state.featuresRunning else { return }
            startAcceleration()
        } else {
            // Runs even while ungranted: a revoked grant leaves pointerAccel
            // holding the property (stopFeatures keeps it under control), so
            // the off half must not wait for featuresRunning.
            releaseAcceleration()
        }
    }

    // disable() restores the original and stops the reassert timer.
    private func releaseAcceleration() {
        guard let accel = pointerAccel else { return }
        if accel.disable() {
            pointerAccel = nil
            state.accelHeld = false
            state.pointerSpeedAvailable = false
            state.accelWriteFailing = false
            state.accelUnresponsive = false
        } else {
            // The properties are still held and the original could not be
            // written back. The instance stays: its claim and stored
            // original are what a later restore (the next toggle cycle or
            // quit) puts back, and dropping it would leave them held by nobody
            // after deinit's one retry. The toggle must read failed, not
            // off, same as a failed enable.
            state.accelWriteFailing = true
        }
    }

    func setInvertVertical(_ on: Bool) {
        settings.invertVertical = on
        applyScrollConfigs()
    }

    func setMulThousandths(_ thousandths: Int) {
        settings.mulThousandths = thousandths
        applyScrollConfigs()
    }

    func setPointerSpeedThousandths(_ thousandths: Int) {
        settings.pointerSpeedThousandths = thousandths
        // Read back: the store clamps.
        pointerAccel?.setSpeed(thousandths: settings.pointerSpeedThousandths)
    }

    func setLaunchAtLogin(_ on: Bool) {
        settings.launchAtLogin = on
        syncLoginItem()
    }

    func setInvertHorizontal(_ on: Bool) {
        settings.invertHorizontal = on
        applyScrollConfigs()
    }

    func setFlattenNotches(_ on: Bool) {
        settings.flattenNotches = on
        applyScrollConfigs()
    }

    func setLinesPerNotch(_ lines: Int) {
        settings.linesPerNotch = lines
        applyScrollConfigs()
    }

    func setAltTrackpadDetection(_ on: Bool) {
        settings.altTrackpadDetection = on
        applyScrollConfigs()
    }

    func setCornerRadius(_ radius: Double) {
        settings.cornerRadius = radius
        cornerRadius = CGFloat(settings.cornerRadius)
        // The clamp rebuilds from the global on the next refresh; force one so
        // the new arc applies now rather than on the 0.5s tick.
        if state.featuresRunning { refresh() }
    }

    // MARK: - Hotkey

    // Persist first, then register: a chord another app owns still stores and
    // displays, with the failure shown in the row.
    func setHotkey(keyCode: Int, modifiers: Int) {
        settings.hotkeyKeyCode = keyCode
        settings.hotkeyModifiers = modifiers
        applyHotkey()
    }

    // The recorder releases the registration while capturing: an active
    // RegisterEventHotKey swallows its own chord globally, so re-recording
    // the current chord would otherwise never reach the recorder's monitor.
    func beginHotkeyCapture() { hotkeyCenter.unregister() }
    func endHotkeyCapture() { applyHotkey() }

    private func applyHotkey() {
        state.hotkeyRegistrationFailed = !hotkeyCenter.apply(
            keyCode: settings.hotkeyKeyCode, modifiers: settings.hotkeyModifiers)
    }

    // MARK: - Resets

    // "Reset to defaults": erase chosen settings (never
    // recovery.-prefixed keys; the store enforces that) and reapply the
    // defaults immediately. Acceleration stays off at the default speed:
    // a running feature keeps holding and a stopped one starts.
    func resetToDefaults() {
        settings.resetToDefaults()
        applySettings()
        pointerAccel?.setSpeed(thousandths: settings.pointerSpeedThousandths)
        applyHotkey()
        syncLoginItem()
        // The reset restores the master switch to on; if it was off, the
        // features are torn down and reapplying settings alone would leave
        // the panel claiming on over a dead runtime.
        if settings.enabled, state.trusted, !state.featuresRunning {
            startFeatures()
        }
        if state.featuresRunning {
            // No pointerAccel == nil gate: an instance kept by a failed
            // disable() has no timer, and startAcceleration() is what
            // rebuilds it (enable() is idempotent for a live one).
            if settings.accelerationOff { startAcceleration() }
            refresh()
        }
    }

    // Boots out and deletes the legacy job, ahead of an SMAppService
    // registration, which needs the shared label free (see registerWatcher). Returns a failure description, or nil
    // once the job is neither loaded nor on disk. bootout's exit code is not
    // the signal: it is nonzero for a job that was never loaded, which is
    // the normal state of a plist whose bootstrap failed, so the job's
    // presence in launchd is probed instead before the file goes.
    private func bootOutLegacyWatcher() -> String? {
        guard FileManager.default.fileExists(atPath: legacyWatcherPlistURL.path)
        else { return nil }
        runLaunchctl(["bootout", watcherJobTarget])
        guard !watcherJobLoaded() else {
            return "the legacy crash-recovery job is still loaded in launchd"
        }
        try? FileManager.default.removeItem(at: legacyWatcherPlistURL)
        guard !FileManager.default.fileExists(atPath: legacyWatcherPlistURL.path)
        else { return "the legacy crash-recovery plist could not be deleted" }
        return nil
    }

    private func applyScrollConfigs() {
        scrollVerticalConfig = settings.verticalScrollConfig
        scrollHorizontalConfig = settings.horizontalScrollConfig
        scrollAltDetection = settings.altTrackpadDetection
    }

    // Menu Quit: restore the acceleration property, re-associate
    // the cursor, exit 0. The atexit restorer runs the same two calls again,
    // which is fine because both are idempotent.
    func quit() -> Never {
        pointerAccel?.restore()
        CGAssociateMouseAndMouseCursorPosition(1)
        exit(0)
    }

    // Restore on every exit path: a stale disconnect leaves the cursor frozen
    // and a held HID property leaves acceleration off. Raw signal handlers calling
    // CoreGraphics can deadlock against the tap thread's CG locks, so use
    // dispatch sources; both run on the main thread, which restore() requires.
    private func installExitRestorers() {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                self?.pointerAccel?.restore()
                CGAssociateMouseAndMouseCursorPosition(1)
                exit(0)
            }
            src.resume()
            signalSources.append(src) // a released source stops firing
        }
        atexit {
            AppRuntime.shared.pointerAccel?.restore()
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }

    // The trusted state may only update after a relaunch on some macOS
    // versions, so the button stays until the poll is verified enough.
    // sh outlives this process, so the new instance starts after the lock
    // and the atexit restorers have run.
    static func relaunch() -> Never {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "sleep 0.5; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? proc.run()
        exit(0)
    }

    private func showDuplicateNotice() {
        _ = NSApplication.shared
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Cataclysm is already running"
        alert.informativeText =
            "This copy will quit. The running instance keeps control of the "
            + "cursor and pointer settings."
        alert.runModal()
    }

    private func showLockFailure(_ failure: String) {
        _ = NSApplication.shared
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Cataclysm could not start"
        alert.informativeText =
            "The instance lock file could not be opened, so Cataclysm cannot "
            + "tell whether another copy is running and will quit. Remove "
            + "whatever is in the way and open it again.\n\n\(failure)"
        alert.addButton(withTitle: "Quit")
        alert.runModal()
    }

    private func showMoveToApplicationsScreen() {
        _ = NSApplication.shared
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Move Cataclysm to the Applications folder first"
        alert.informativeText =
            "Cataclysm is running from a disk image or a translocated copy, "
            + "where crash recovery cannot work. Drag Cataclysm.app into "
            + "Applications, then open it from there."
        alert.addButton(withTitle: "Quit")
        alert.runModal()
    }
}

// MARK: - Onboarding

// One screen, shown while AXIsProcessTrusted() is false. The primary button
// raises the system prompt with the app pre-listed; the secondary opens the
// Accessibility pane; the runtime's 0.5s poll dismisses it on success.
final class OnboardingController {
    private var window: NSWindow?

    func show() {
        if window == nil { window = makeWindow() }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
        window = nil
    }

    private func makeWindow() -> NSWindow {
        let view = OnboardingView(
            requestTrust: {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue()
                    as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            },
            openSettings: {
                let pane = "x-apple.systempreferences:com.apple.preference"
                    + ".security?Privacy_Accessibility"
                if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
            },
            relaunch: { AppRuntime.relaunch() })
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Welcome to Cataclysm"
        window.styleMask = [.titled, .closable]
        // Closing cancels nothing permanent; the poll reopens features on
        // grant and the panel's warning row reopens this window on demand.
        window.isReleasedWhenClosed = false
        return window
    }
}

struct OnboardingView: View {
    let requestTrust: () -> Void
    let openSettings: () -> Void
    let relaunch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cataclysm needs Accessibility access")
                .font(.title2).bold()
            Text("macOS requires the Accessibility permission for any app "
                + "that repositions the cursor or reads mouse events. "
                + "Cataclysm uses it to keep the cursor inside your game's "
                + "window and to adjust scrolling, and does nothing else "
                + "with it.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Grant Access…", action: requestTrust)
                    .keyboardShortcut(.defaultAction)
                Button("Open Accessibility Settings", action: openSettings)
            }
            Divider()
            Text("If macOS does not pick up the grant, relaunch the app:")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Relaunch Cataclysm", action: relaunch)
        }
        .padding(20)
        .frame(width: 440)
    }
}

// MARK: - Panel

// Every slider row reserves the same label and readout widths, so the two
// tracks start and end on the same x whatever their own title and range.
private let speedSliderLabelReserve = "Pointer speed"
private let speedSliderReadoutReserve = multiplierLabel(forThousandths: mulThousandths(
    forMultiplier: max(scrollSpeedScale.maximum, pointerSpeedScale.maximum)))

struct SpeedSliderRow: View {
    let title: String
    let scale: SliderScale
    let thousandths: Int
    let isDisabled: Bool
    var caption: String? = nil
    let set: (Int) -> Void

    // Commit on release: moving outside the panel dismisses it, so a live
    // cursor-speed preview cannot be tried while dragging.
    @State private var sliderPos = 0.0
    @State private var draggingSlider = false
    @State private var dragStartPos = 0.0

    // An unmoved thumb preserves stored values off the snap grid or outside
    // the track. This stays independent of draggingSlider, which clears
    // before commitSlider runs.
    private var sliderMoved: Bool { sliderPos != dragStartPos }

    var body: some View {
        let readout = draggingSlider && sliderMoved
            ? mulThousandths(forMultiplier: scale.multiplier(forPosition: sliderPos))
            : thousandths
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                Text(speedSliderLabelReserve).hidden()
                Text(title)
            }
            .fixedSize()
            // A little air between the label and the track's start.
            .padding(.trailing, 6)

            // The unavailable caption occupies the inactive track, keeping
            // the readout and reset in place within the 320-point panel.
            Slider(value: $sliderPos, in: scale.positionRange) { editing in
                if editing { dragStartPos = sliderPos }
                draggingSlider = editing
                if !editing { commitSlider() }
            }
            .accessibilityLabel(title)
            .opacity(caption == nil ? 1 : 0)
            .accessibilityHidden(caption != nil)
            .overlay(alignment: .trailing) {
                if let caption {
                    Text(caption).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            // Reserve the widest in-range readout of either scale so the
            // track stays still when the multiplier reaches two digits.
            ZStack(alignment: .trailing) {
                Text(speedSliderReadoutReserve).hidden()
                Text(multiplierLabel(forThousandths: readout))
            }
            .monospacedDigit()
            .fixedSize()
            Button {
                set(1_000)
                syncPosition(thousandths: 1_000)
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .help("Reset to 1.00x")
        }
        .frame(maxWidth: .infinity, minHeight: menuRowHeight, alignment: .leading)
        .padding(.horizontal, menuRowInset)
        .disabled(isDisabled)
        .onAppear { syncPosition(thousandths: thousandths) }
        .onChange(of: thousandths) { syncPosition(thousandths: $0) }
    }

    private func commitSlider() {
        guard sliderMoved else { return }
        let value = mulThousandths(forMultiplier: scale.multiplier(forPosition: sliderPos))
        set(value)
        syncPosition(thousandths: value)
    }

    private func syncPosition(thousandths: Int) {
        sliderPos = scale.position(forMultiplier: Double(thousandths) / 1_000)
        dragStartPos = sliderPos
    }
}

struct CataclysmApp: App {
    @ObservedObject private var settings = AppRuntime.shared.settings
    @ObservedObject private var state = AppRuntime.shared.state
    // Drawn once per state; the label re-evaluates on every panel or state
    // change and follows the master switch, then the cursor lock.
    private static let offIcon = makeMenuBarIcon(.off)
    private static let onIcon = makeMenuBarIcon(.on)
    private static let engagedIcon = makeMenuBarIcon(.engaged)

    var body: some Scene {
        // `.window` style because the speed sliders do not
        // render in `.menu`.
        MenuBarExtra {
            PanelView(state: state, settings: settings)
        } label: {
            Image(nsImage: !settings.enabled ? Self.offIcon
                  : state.jailEngaged ? Self.engagedIcon : Self.onIcon)
        }
        .menuBarExtraStyle(.window)
    }
}

// The default view, laid out as menu rows: every row
// shares one height and inset, commands lift on hover like Control Center
// rows, and the Advanced knobs live on a second page standing in for a
// submenu (a `.window` panel has no real ones). Width fixed at 320 points so
// the panel never reflows as values change.
struct PanelView: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: Settings
    // Which page shows; every open starts on the main page.
    @State private var showingAdvanced = false

    // Ungranted: both taps are down, so the jail and the scroll filter read
    // unavailable rather than on. The acceleration property needs no grant
    // but is only applied after trust (startup step 6), so its failure states
    // can only exist while trusted.
    private var jailFailed: Bool { state.featuresRunning && !state.jailTapUp }
    private var scrollFailed: Bool { state.featuresRunning && !state.scrollTapUp }
    private var accelFailed: Bool { state.accelWriteFailing || state.accelUnresponsive }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showingAdvanced { advancedPage } else { mainPage }
        }
        .padding(menuPanelInset)
        .frame(width: menuPanelWidth)
        .background(PanelBackground())
        .background(PanelWindowStyle())
        .onAppear {
            showingAdvanced = false
            AppRuntime.shared.panelWillAppear()
        }
    }

    // MARK: Pages

    private var mainPage: some View {
        Group {
            staticRow {
                // No update check in the panel: the version is what a player
                // quotes in a bug report and compares against the download
                // page by hand.
                // Baseline-aligned so the smaller caption sits on the
                // headline's text line rather than floating mid-height.
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text("Cataclysm").font(.headline)
                    Text(AppRuntime.shared.appVersion)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Cataclysm on", isOn: Binding(
                    get: { settings.enabled },
                    set: { AppRuntime.shared.setEnabled($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            if !state.trusted {
                warningRow("Grant Accessibility access…") {
                    AppRuntime.shared.showOnboarding()
                }
            }
            if state.trusted && !state.watcherRegistered {
                warningRow(state.watcherRequiresApproval
                           ? "Crash recovery needs approval in Login Items…"
                           : "Crash recovery is off; open Login Items…",
                           action: openLoginItems)
            }
            errorRow(state.watcherError)
            menuDivider
            featureToggle("Lock cursor to app when focused",
                          isOn: settings.jailEnabled,
                          failed: jailFailed,
                          held: false,
                          set: { AppRuntime.shared.setJailEnabled($0) })
            gameRow
            menuDivider
            accelToggle
            // A downed tap holds nothing a click could undo, so these
            // tap-backed toggles pass held: false and disable while failed;
            // only the acceleration toggle keeps a live retry (accelHeld).
            featureToggle("Invert wheel scrolling",
                          isOn: settings.invertVertical,
                          failed: scrollFailed,
                          held: false,
                          set: { AppRuntime.shared.setInvertVertical($0) })
            // The two checkboxes, then the two sliders, so the section reads
            // as switches followed by dials rather than alternating.
            pointerSpeedRow
            SpeedSliderRow(title: "Scroll speed", scale: scrollSpeedScale,
                           thousandths: settings.mulThousandths,
                           isDisabled: !state.trusted || scrollFailed || !settings.enabled,
                           set: { AppRuntime.shared.setMulThousandths($0) })
            menuDivider
            MenuRow(title: "Advanced", trailingSymbol: "chevron.right") {
                showingAdvanced = true
            }
            menuDivider
            staticRow {
                Toggle("Launch at login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { AppRuntime.shared.setLaunchAtLogin($0) }))
                    .toggleStyle(.checkbox)
            }
            errorRow(state.loginItemError)
            if state.loginItemRequiresApproval {
                warningRow("Launch at login needs approval in Login Items…",
                           action: openLoginItems)
            }
            MenuRow(title: "Quit Cataclysm") { AppRuntime.shared.quit() }
        }
    }

    // The Advanced page: the knobs a player has no
    // reason to touch. Scroll knobs share the slider's disabled rule; the
    // hotkey row, corner radius, and the commands stay live because they are
    // preference writes, not tap-dependent.
    private var advancedPage: some View {
        Group {
            MenuRow(title: "Advanced", leadingSymbol: "chevron.left", headline: true) {
                showingAdvanced = false
            }
            menuDivider
            featureToggle("Invert horizontal scrolling",
                          isOn: settings.invertHorizontal,
                          failed: scrollFailed,
                          held: false,
                          set: { AppRuntime.shared.setInvertHorizontal($0) })
            featureToggle("Flatten scroll notches",
                          isOn: settings.flattenNotches,
                          failed: scrollFailed,
                          held: false,
                          set: { AppRuntime.shared.setFlattenNotches($0) })
            featureToggle("Fallback trackpad detection",
                          isOn: settings.altTrackpadDetection,
                          failed: scrollFailed,
                          held: false,
                          set: { AppRuntime.shared.setAltTrackpadDetection($0) })
            staticRow { HotkeyRow(state: state, settings: settings) }
            stepperRow("Lines per notch",
                       value: settings.linesPerNotch, range: 1...1000,
                       set: { AppRuntime.shared.setLinesPerNotch($0) })
                .disabled(!state.trusted || scrollFailed || !settings.enabled)
            stepperRow("Corner radius",
                       value: Int(settings.cornerRadius), range: 0...200,
                       set: { AppRuntime.shared.setCornerRadius(Double($0)) })
                .help("Radius of the jail's rounded corners in windowed mode; 0 disables corner clamping")
            menuDivider
            MenuRow(title: "Reset to defaults") {
                AppRuntime.shared.resetToDefaults()
            }
        }
    }

    // MARK: Row helpers

    private var menuDivider: some View {
        Divider().padding(.vertical, 5).padding(.horizontal, menuRowInset)
    }

    // A row without a command: same height and inset as a MenuRow, no
    // highlight, so controls line up with the commands around them.
    private func staticRow<Content: View>(
        @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) { content() }
            .frame(maxWidth: .infinity, minHeight: menuRowHeight, alignment: .leading)
            .padding(.horizontal, menuRowInset)
    }

    private func warningRow(_ title: String, action: @escaping () -> Void) -> some View {
        MenuRow(title: title, leadingSymbol: "exclamationmark.triangle.fill",
                tint: .orange, action: action)
    }

    @ViewBuilder
    private func errorRow(_ text: String?) -> some View {
        if let text {
            staticRow {
                Text(text).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func openLoginItems() {
        let link = "x-apple.systempreferences:"
            + "com.apple.LoginItems-Settings.extension"
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    // MARK: Application row

    // Sentinel tag for the chooser row; a real bundle id is never empty.
    private let chooseTag = ""

    // Rows tagged by bundle id, never by name, so two apps with the same
    // display name stay distinguishable. "None" clears the target so the jail
    // matches nothing; selecting the chooser row opens the NSOpenPanel and
    // leaves the stored selection untouched until it returns. A Menu with a
    // hand-drawn label rather than a bare Picker: a pop-up button sizes to
    // its content and cannot be stretched to the row, this label can.
    private var gameRow: some View {
        staticRow {
            Menu {
                Picker("Application", selection: Binding(
                    get: { settings.targetBundleID },
                    set: { tag in
                        if tag == chooseTag {
                            AppRuntime.shared.chooseTargetFromApplications()
                        } else if tag == Settings.noTarget {
                            AppRuntime.shared.setTarget(bundleID: Settings.noTarget, name: "None")
                        } else if let row = state.pickerRows.first(where: { $0.bundleID == tag }) {
                            AppRuntime.shared.setTarget(bundleID: row.bundleID, name: row.name)
                        }
                    })) {
                    Text("None").tag(Settings.noTarget)
                    Divider()
                    ForEach(state.pickerRows, id: \.bundleID) { row in
                        rowLabel(row).tag(row.bundleID)
                    }
                    Divider()
                    Text("Choose from Applications…").tag(chooseTag)
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 6) {
                    if let row = selectedRow {
                        rowLabel(row)
                    } else {
                        Text("None").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, menuRowInset)
                .frame(maxWidth: .infinity, minHeight: menuRowHeight)
                .background(RoundedRectangle(cornerRadius: menuControlCornerRadius)
                    .fill(Color.primary.opacity(0.1)))
                .contentShape(Rectangle())
            }
            // .button with a plain button style renders the label as
            // authored; .borderlessButton keeps only its text and image.
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
        }
    }

    private var selectedRow: GamePickerRow? {
        let target = settings.targetBundleID
        return state.pickerRows.first { $0.bundleID == target }
    }

    // Icon, name, and a marker for a closed app, which stays selectable so
    // the jail attaches the moment it launches. One concatenated Text: a
    // menu item keeps only the first Text of its content.
    private func rowLabel(_ row: GamePickerRow) -> some View {
        HStack(spacing: 6) {
            Image(nsImage: icon(for: row))
                .resizable()
                .frame(width: 18, height: 18)
            (Text(row.label) + Text(row.isRunning ? "" : "  (not running)")
                .foregroundColor(.secondary))
                .lineLimit(1)
        }
    }

    // Icons resolve at render time: a running row uses the process's icon, a
    // closed one the installed bundle's (Launch Services knows every app that
    // has ever run), and only an app that is nowhere on disk falls back to
    // the generic icon.
    private func icon(for row: GamePickerRow) -> NSImage {
        let icon: NSImage
        if row.isRunning,
           let app = NSWorkspace.shared.runningApplications
               .first(where: { $0.bundleIdentifier == row.bundleID }),
           let appIcon = app.icon {
            icon = appIcon
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: row.bundleID) {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            icon = NSWorkspace.shared.icon(for: .applicationBundle)
        }
        // The pop-up draws the NSImage at its own size, ignoring the SwiftUI
        // frame, so size the image itself or it fills the bezel edge to edge.
        let sized = icon.copy() as! NSImage
        sized.size = NSSize(width: 18, height: 18)
        return sized
    }

    // MARK: Feature rows

    // Unavailable while ungranted only until the property is actually taken:
    // step 6 defers the first write to trust, so a checked toggle before then
    // would claim a curve that is still accelerating. Once held, a lost grant
    // does not release the property, so the toggle stays live. `held` is
    // accelHeld rather than the stored value: after a failed restore the
    // setting reads off while the properties are still held, and a click here is
    // the only retry of that restore the panel offers.
    private var accelToggle: some View {
        featureToggle("Disable mouse acceleration",
                      isOn: settings.accelerationOff,
                      failed: accelFailed,
                      unavailable: !state.trusted && !state.accelHeld,
                      held: state.accelHeld,
                      set: { AppRuntime.shared.setAccelerationOff($0) })
    }

    // One rendering rule for every feature toggle: unavailable reads
    // unchecked and disabled, failed reads unchecked with a red caption
    // rather than checked, and only a healthy feature shows its stored value.
    // A failed toggle reads unchecked, so a click would arrive as `true`
    // whatever is stored: while the feature still has an effect to undo
    // (`held`), that click
    // means "turn it off" and is routed as false; with nothing to turn off
    // the control is disabled, so a click cannot silently persist a
    // preference the checkbox never shows.
    private func featureToggle(_ title: String, isOn: Bool, failed: Bool,
                               unavailable: Bool? = nil, held: Bool,
                               set: @escaping (Bool) -> Void) -> some View {
        let unavailable = unavailable ?? !state.trusted
        // Master switch off: rows dim but keep their stored checkmarks (the
        // preferences are kept, and unchecked would read as cleared). The
        // one exception stays live: a failed toggle that still holds an
        // effect, whose click is the only retry of the failed release.
        let masterOff = !settings.enabled && !(failed && held)
        return staticRow {
            Toggle(title, isOn: Binding(
                get: { isOn && !unavailable && !failed },
                set: { value in set(failed ? false : value) }))
                .toggleStyle(.checkbox)
                .disabled(unavailable || (failed && !held) || masterOff)
            if failed {
                Spacer()
                Text("failed").font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var pointerSpeedRow: some View {
        SpeedSliderRow(title: "Pointer speed", scale: pointerSpeedScale,
                       thousandths: settings.pointerSpeedThousandths,
                       isDisabled: !(settings.enabled && settings.accelerationOff && state.accelHeld
                                     && state.pointerSpeedAvailable),
                       caption: pointerSpeedCaption,
                       set: { AppRuntime.shared.setPointerSpeedThousandths($0) })
    }

    private var pointerSpeedCaption: String? {
        guard state.accelHeld && !state.pointerSpeedAvailable else { return nil }
        if #available(macOS 14, *) { return "unavailable on this Mac" }
        return "needs macOS 14"
    }

    // Minus, value, plus: reads as "less or more" at a glance, which the
    // stacked stepper arrows do not. The value cell is fixed width so one-
    // and three-digit values leave the buttons in the same place.
    private func stepperRow(_ title: String, value: Int, range: ClosedRange<Int>,
                            set: @escaping (Int) -> Void) -> some View {
        staticRow {
            Text(title)
            Spacer()
            HStack(spacing: 2) {
                stepButton("minus", enabled: value > range.lowerBound) { set(value - 1) }
                Text("\(value)").monospacedDigit().frame(width: 30)
                stepButton("plus", enabled: value < range.upperBound) { set(value + 1) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityValue("\(value)")
    }

    private func stepButton(_ symbol: String, enabled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9, weight: .medium))
                .frame(width: 20)
        }
        .buttonStyle(BezelButtonStyle())
        .disabled(!enabled)
    }
}

let menuPanelWidth: CGFloat = 320
// Corner geometry: the window's corner radius and the inset of the rows from
// the edge, measured off the MenuBarExtra window on macOS 26 (zoomed
// capture), not documented anywhere. The row hover highlight reuses the
// window's radius, which on a 28-point row is a full pill, the shape
// Control Center's rows take; a concentric inner radius (14 minus the inset)
// read as a squarer corner than the panel's. Controls drawn inside the rows
// (the game dropdown, bezel buttons) share one smaller radius.
let menuPanelCornerRadius: CGFloat = 14
let menuPanelInset: CGFloat = 6
let menuControlCornerRadius: CGFloat = 6
let menuPanelShape = RoundedRectangle(cornerRadius: menuPanelCornerRadius, style: .continuous)
// Control Center's row hover: a translucent wash of the label color, white
// on the dark panel and black on the light one, eyeballed off the Wi-Fi
// module rather than read from any documented token.
let menuHoverFill = Color.primary.opacity(0.1)
let menuRowHeight: CGFloat = 28
let menuRowInset: CGFloat = 8

// The panel's ground. The MenuBarExtra window draws its own material
// beneath the content view; on macOS 26 that material is the system's glass,
// the same one native menus wear, so nothing is painted over it (a glass
// effect layered on top has nothing behind it to refract and reads flat).
// Earlier systems draw a brighter popover material, covered here with a
// near-black fill and a faint hairline for the Control Center look.
struct PanelBackground: View {
    private let fill = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.11, alpha: 0.97)
            : NSColor(white: 0.96, alpha: 0.97)
    })

    var body: some View {
        if #available(macOS 26, *) {
            Color.clear
        } else {
            menuPanelShape.fill(fill)
                .overlay(menuPanelShape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
        }
    }
}

// Drops the MenuBarExtra window's shadow, which on a dark panel paints a
// bright rim light along the edge that no content can cover (it sits above
// the content view; PanelBackground's hairline defines the edge instead).
// The hosting view learns its window in viewDidMoveToWindow.
struct PanelWindowStyle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { HostView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class HostView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.hasShadow = false
        }
    }
}

// The one bezel every right-aligned control in the panel wears (stepper
// buttons, the hotkey chord): a single height and corner radius so a column
// of them lines up, unlike the mixed stock control sizes.
struct BezelButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Bezel(configuration: configuration)
    }

    // A ButtonStyle is not a View, so an @Environment stored on the style
    // itself never resolves and reads its default (true); the body lives in
    // a nested View where the environment is real.
    private struct Bezel: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .frame(minWidth: 20, minHeight: 22)
                .background(RoundedRectangle(cornerRadius: menuControlCornerRadius)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.22 : 0.1)))
                .opacity(enabled ? 1 : 0.35)
                .contentShape(Rectangle())
        }
    }
}

// A command row that behaves like a Control Center item: full width, lifted
// by a faint translucent tint while hovered (the same wash Control Center's
// rows wear, not the accent-blue selection of a classic NSMenu), dimmed and
// inert while disabled. The title is a plain string so the button keeps an
// accessibility name; symbols are optional decorations before and after it.
struct MenuRow: View {
    let title: String
    var leadingSymbol: String? = nil
    var trailingSymbol: String? = nil
    var headline = false
    var tint: Color? = nil
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    private var highlighted: Bool { hovering && enabled }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let leadingSymbol { symbol(leadingSymbol) }
                Text(title).font(headline ? .headline : .body)
                if let trailingSymbol {
                    Spacer()
                    symbol(trailingSymbol)
                }
            }
            .frame(maxWidth: .infinity, minHeight: menuRowHeight, alignment: .leading)
            .padding(.horizontal, menuRowInset)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(!enabled ? Color.secondary : tint ?? Color.primary)
        .background(menuPanelShape.fill(highlighted ? menuHoverFill : Color.clear))
        .onHover { hovering = $0 }
        // A dismissal with the pointer still over the row (its own action
        // handing focus away, Escape, another app taking key) delivers no
        // exit event, and @State survives the close, so the highlight would
        // come back painted on the next open.
        .onDisappear { hovering = false }
        .accessibilityLabel(title)
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name).font(.caption.weight(.semibold))
    }
}

// MARK: - Hotkey recorder

// The jail toggle hotkey row. A local keyDown monitor, installed while
// recording, sees every key event before sendEvent dispatches it (command
// chords included, ahead of any key equivalent). Two rules hold on every
// exit: recording cancels keeping the previous chord when the panel
// dismisses (onDisappear), and the monitor is torn down on that same path,
// so a dismissed panel leaves nothing capturing keys.
struct HotkeyRow: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: Settings
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text("Cursor lock toggle hotkey")
            if state.hotkeyRegistrationFailed {
                Text("in use by another app").font(.caption).foregroundStyle(.red)
            }
            Spacer()
            Button {
                recording ? stopRecording() : startRecording()
            } label: {
                Text(recording
                        ? "Press keys…"
                        : hotkeyChordLabel(keyCode: settings.hotkeyKeyCode,
                                           modifiers: settings.hotkeyModifiers))
                    .monospacedDigit()
                    .lineLimit(1)
                    .padding(.horizontal, 6)
            }
            .buttonStyle(BezelButtonStyle())
            .help(recording ? "Esc cancels" : "Click, then press the new chord")
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        recording = true
        // Release the live registration so re-recording the current chord
        // reaches the monitor instead of being swallowed globally.
        AppRuntime.shared.beginHotkeyCapture()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event) ? nil : event
        }
    }

    // Idempotent teardown shared by capture, cancel, and panel dismissal.
    // Re-registers whatever chord is stored, which is the previous one unless
    // handle() persisted a new one first.
    private func stopRecording() {
        guard recording else { return }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        AppRuntime.shared.endHotkeyCapture()
    }

    // Returns true when the event was consumed. Escape cancels; a press
    // without a command-class modifier is swallowed but keeps recording, so
    // stray typing neither beeps nor becomes a system-wide bare-key hotkey.
    private func handle(_ event: NSEvent) -> Bool {
        guard recording else { return false }
        let mods = carbonModifiers(fromNSFlags: event.modifierFlags.rawValue)
        if Int(event.keyCode) == escapeKeyCode, mods == 0 {
            stopRecording()
            return true
        }
        guard isValidHotkeyChord(modifiers: mods) else { return true }
        AppRuntime.shared.setHotkey(keyCode: Int(event.keyCode), modifiers: mods)
        stopRecording()
        return true
    }
}
