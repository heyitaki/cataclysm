// Cataclysm app entry. `main()` dispatches on arguments before SwiftUI ever
// loads, so the watcher (`--watch`) and the acceptance gate (`--smoke-register`)
// never start UI, never touch AppKit state, and can run headless under launchd.
// A plain launch runs the spec's six startup steps in order: instance lock,
// cursor re-association, install-location gate, clamped settings load, trust
// check, and only then taps, the acceleration property, and agent
// registration. Steps 1-3 run before any UI, so a duplicate launch or a
// launch from the DMG never flashes a panel.

import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

let cataclysmBundleID = "io.github.heyitaki.cataclysm"
let watcherPlistName = "\(cataclysmBundleID).watch.plist"

// MARK: - Runtime globals shared with Jail/TapHost

// The CLI derives these from arguments in main.swift; the app loads them from
// the settings store during startup step 4, before any tap can read them.
var gameBundle = Settings.Default.targetBundleID
var cornerRadius = CGFloat(Settings.Default.cornerRadius)
var scrollVerticalConfig = ScrollAxisConfig(
    invert: true, flatten: true, linesPerNotch: 1, mulThousandths: 1_000)
var scrollHorizontalConfig = ScrollAxisConfig(
    invert: false, flatten: true, linesPerNotch: 1, mulThousandths: 1_000)
var scrollAltDetection = false
var scrollDump = false

@main
struct CataclysmMain {
    static func main() {
        let args = CommandLine.arguments.dropFirst()
        if args.contains("--watch") {
            runWatcher()
        }
        if args.contains("--smoke-register") {
            exit(SmokeGate().run())
        }
        // The CLI's scroll measurement flag lives on in the app: it only sets
        // the dump global, then the launch proceeds normally.
        if args.contains("--dump-scroll") {
            scrollDump = true
        }
        AppRuntime.shared.preflight()
        AppRuntime.shared.start()
        CataclysmApp.main()
    }

    // The watcher process (spec "Crash recovery and the watcher"): no UI, no
    // taps, no property writes, and no instance lock — it only ever calls the
    // idempotent release, so it can never conflict with a live app instance.
    // Deliberately tiny: launchd restarts a crashed KeepAlive job at most
    // about every 10s, so the less here that can crash, the better.
    static func runWatcher() -> Never {
        var previous: Bool?
        let timer = Timer(timeInterval: 1.0, repeats: true) { _ in
            let present = !NSRunningApplication
                .runningApplications(withBundleIdentifier: cataclysmBundleID)
                .isEmpty
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

// Published state behind the panel's status and failure rows (spec "Status
// and failures"). Every failure the app can have surfaces here, because the
// panel is the app's only surface.
final class AppState: ObservableObject {
    @Published var trusted = false
    @Published var featuresRunning = false
    @Published var jailTapUp = false
    @Published var scrollTapUp = false
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
    @Published var watcherRegistered = false
    @Published var watcherRequiresApproval = false
    // register() threw (SMAppService path) and the legacy bootstrap failed
    // too, or the legacy write itself failed. Lands in the panel's status
    // area, never in a log nobody reads.
    @Published var watcherError: String?
    @Published var loginItemError: String?
    // RegisterEventHotKey refused the chord (another app owns it). Shows in
    // the hotkey row rather than leaving a recorded chord that does nothing.
    @Published var hotkeyRegistrationFailed = false
}

// Mirror of the stored settings the panel binds to. AppRuntime is the only
// writer: its setters persist through Settings, update the live feature, and
// keep this mirror in sync, so a control can never show a value that did not
// reach storage.
final class SettingsModel: ObservableObject {
    @Published var jailEnabled = true
    @Published var accelOff = true
    @Published var invertVertical = true
    @Published var launchAtLogin = true
    @Published var mulThousandths = 1_000
    @Published var targetName = ""
    @Published var targetBundleID = ""
    @Published var pickerRows: [GamePickerRow] = []
    @Published var invertHorizontal = false
    @Published var flattenNotches = true
    @Published var linesPerNotch = 1
    @Published var altTrackpadDetection = false
    @Published var cornerRadiusSetting = Settings.Default.cornerRadius
    @Published var hotkeyKeyCode = Settings.Default.hotkeyKeyCode
    @Published var hotkeyModifiers = Settings.Default.hotkeyModifiers
}

// MARK: - Startup sequence and feature lifecycle

final class AppRuntime {
    static let shared = AppRuntime()
    let state = AppState()
    let panel = SettingsModel()

    private let lock: InstanceLock
    private var settings: Settings?
    private var pointerAccel: PointerAccel?
    private let hotkeyCenter = HotkeyCenter()
    private var refreshTimer: Timer?
    private var trustTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var pickerObservers: [NSObjectProtocol] = []
    private var onboarding: OnboardingController?
    private var signalSources: [DispatchSourceSignal] = []

    private init() {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        lock = InstanceLock(path: base
            .appendingPathComponent(cataclysmBundleID)
            .appendingPathComponent("instance.lock").path)
    }

    // Steps 1-3. The loser of the lock and a blocked install location both
    // show one screen and exit 0 having touched nothing: no cursor writes
    // beyond step 2's release, no acceleration property, no agent, and the
    // exit restorers are deliberately not installed yet.
    func preflight() {
        if !lock.acquire() {
            showDuplicateNotice()
            exit(0)
        }
        // Thaw a cursor a dead instance left frozen. Needs no Accessibility
        // grant (measured, spec appendix), so this works ungranted.
        CGAssociateMouseAndMouseCursorPosition(1)
        if isBlockedInstallLocation(Bundle.main.bundlePath) {
            showMoveToApplicationsScreen()
            exit(0)
        }
    }

    // Steps 4-6. The trust poll runs for the whole process lifetime: it
    // dismisses onboarding on a fresh grant and catches a revoked one.
    func start() {
        let loaded = Settings()
        settings = loaded
        applySettings(loaded)
        // The hotkey needs no Accessibility grant, so it registers before
        // trust; toggling while ungranted just flips the stored preference.
        hotkeyCenter.onHotkey = { [weak self] in
            guard let self else { return }
            self.setJailEnabled(!(self.settings?.jailEnabled ?? true))
        }
        applyHotkey()
        installExitRestorers()
        state.trusted = AXIsProcessTrusted()
        if state.trusted {
            startFeatures()
            registerAgentsIfNeeded()
        } else {
            // The window needs the run loop; this fires once SwiftUI starts it.
            DispatchQueue.main.async { self.showOnboarding() }
        }
        trustTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) {
            [weak self] _ in self?.trustTick()
        }
        // Keep the game picker fresh for the panel's whole lifetime (spec
        // "Game picker"): a target quitting while the panel is open drops to
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
    }

    // Reopened from the panel's warning row after a lost grant; never shown
    // while granted.
    func showOnboarding() {
        guard !state.trusted else { return }
        if onboarding == nil { onboarding = OnboardingController() }
        onboarding?.show()
    }

    private func applySettings(_ s: Settings) {
        gameBundle = s.targetBundleID
        cornerRadius = CGFloat(s.cornerRadius)
        jailEnabled = s.jailEnabled
        scrollVerticalConfig = s.verticalScrollConfig
        scrollHorizontalConfig = s.horizontalScrollConfig
        scrollAltDetection = s.altTrackpadDetection
        reloadPanel()
    }

    // Refresh the panel's mirror from storage; called at startup and every
    // panel open, so a value changed behind the panel (a later hotkey, a
    // reset) is never shown stale.
    func reloadPanel() {
        guard let settings else { return }
        panel.jailEnabled = settings.jailEnabled
        panel.accelOff = settings.accelerationOff
        panel.invertVertical = settings.invertVertical
        panel.launchAtLogin = settings.launchAtLogin
        panel.mulThousandths = settings.mulThousandths
        panel.targetName = settings.targetDisplayName
        panel.targetBundleID = settings.targetBundleID
        panel.invertHorizontal = settings.invertHorizontal
        panel.flattenNotches = settings.flattenNotches
        panel.linesPerNotch = settings.linesPerNotch
        panel.altTrackpadDetection = settings.altTrackpadDetection
        panel.cornerRadiusSetting = settings.cornerRadius
        panel.hotkeyKeyCode = settings.hotkeyKeyCode
        panel.hotkeyModifiers = settings.hotkeyModifiers
        rebuildGamePicker()
    }

    // Snapshot the running .regular apps into pure picker rows. Called on
    // panel open (via reloadPanel) and on every workspace launch/terminate
    // notification.
    func rebuildGamePicker() {
        guard let settings else { return }
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { GamePickerCandidate(bundleID: $0.bundleIdentifier,
                                       name: $0.localizedName) }
        panel.pickerRows = buildGamePickerRows(
            storedBundleID: settings.targetBundleID,
            storedName: settings.targetDisplayName,
            running: running, ownBundleID: cataclysmBundleID)
    }

    private func trustTick() {
        let trusted = AXIsProcessTrusted()
        guard trusted != state.trusted else { return }
        state.trusted = trusted
        if trusted {
            onboarding?.close()
            onboarding = nil
            startFeatures()
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
        if let settings, settings.accelerationOff {
            startAcceleration()
        }
        state.jailTapUp = startTap()
        state.scrollTapUp = startScrollTap()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            refresh()
            reviveScrollTap()
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { _ in refresh() }
        refresh()
        state.featuresRunning = true
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
        clampArea = nil
        setEngaged(false)
        // setEngaged(false) only re-associates from the engaged state; make
        // the release unconditional.
        CGAssociateMouseAndMouseCursorPosition(1)
        state.jailTapUp = false
        state.scrollTapUp = false
        state.featuresRunning = false
    }

    private func startAcceleration() {
        guard pointerAccel == nil else { return }
        let accel = PointerAccel()
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

    // Re-probe on panel open: a HID client that recovers without ever passing
    // through a failing write never fires onWriteHealthChange, so the latched
    // unresponsive flag has to be re-read when someone looks.
    func refreshAccelHealth() {
        guard let pointerAccel else { return }
        state.accelUnresponsive = !pointerAccel.clientResponsive
        state.accelWriteFailing = pointerAccel.writeFailing
    }

    // Called only after trust (Task 6 owns the ordering), so no agent is ever
    // registered on a first launch that is still ungranted or quarantined.
    private func registerAgentsIfNeeded() {
        syncLoginItem()
        registerWatcher()
    }

    // MARK: - Watcher registration

    // Label, plist path, and executable path all come from the shared
    // derivations in Watcher.swift, the same ones the smoke gate validates.

    private var legacyWatcherLabel: String {
        watcherJobLabel(bundleID: cataclysmBundleID)
    }

    private var legacyWatcherPlistURL: URL {
        legacyWatcherPlistLocation(
            home: FileManager.default.homeDirectoryForCurrentUser,
            bundleID: cataclysmBundleID)
    }

    // The absolute path the legacy plist carries; derived from bundleURL every
    // read so a moved bundle is noticed, never cached.
    private var watcherExecutablePath: String {
        watcherExecutable(inBundle: Bundle.main.bundleURL)
    }

    private func appVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    // The watcher agent always runs; it is not a user setting. A version
    // change unregisters first: SMAppService may not launch an agent whose
    // executable changed unless it is re-registered, and every release
    // changes the executable.
    private func registerWatcher() {
        guard let settings else { return }
        let agent = SMAppService.agent(plistName: watcherPlistName)
        let version = appVersion()
        let plan = watcherRegistrationPlan(
            statusEnabled: agent.status == .enabled,
            versionChanged: needsWatcherReregistration(
                lastRegistered: settings.lastRegisteredVersion, current: version))
        if plan.unregisterFirst {
            try? agent.unregister()
        }
        if plan.register {
            do {
                try agent.register()
                settings.lastRegisteredVersion = version
                state.watcherError = nil
                // A legacy job left over from a build SMAppService refused is
                // now redundant; two watchers are harmless but one shows as a
                // stray Login Item.
                bootOutLegacyWatcher()
            } catch {
                // register() also throws while the agent sits in Login
                // Items awaiting approval or switched off there. That is
                // the user's decision: never route around it with the
                // legacy job, which needs no approval at all.
                // refreshWatcherStatus() below surfaces the approval row.
                if agent.status == .requiresApproval {
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
        reconcileLegacyWatcherIfMoved()
        refreshWatcherStatus()
    }

    // Writes the legacy plist with the current absolute executable path and
    // bootstraps it. Boots out first: launchd keeps the loaded definition, so
    // rewriting the file alone never reaches a job already bootstrapped.
    // Returns a failure description, or nil on success.
    private func installLegacyWatcher() -> String? {
        do {
            let data = try legacyWatcherPlistData(
                label: legacyWatcherLabel, bundleID: cataclysmBundleID,
                executablePath: watcherExecutablePath)
            try FileManager.default.createDirectory(
                at: legacyWatcherPlistURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            runLaunchctl(["bootout", "gui/\(getuid())/\(legacyWatcherLabel)"])
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
    private func reconcileLegacyWatcherIfMoved() {
        guard let data = try? Data(contentsOf: legacyWatcherPlistURL),
              let stored = legacyWatcherExecutablePath(inPlistData: data),
              stored != watcherExecutablePath else { return }
        if let failure = installLegacyWatcher() {
            state.watcherError = "Crash recovery failed after the app moved: \(failure)"
        }
    }

    // Launch at login is SMAppService.mainApp, independent of the watcher
    // agent. register()/unregister() throw; the failure lands in the panel's
    // status area, never in a log.
    private func syncLoginItem() {
        guard let settings else { return }
        do {
            let status = SMAppService.mainApp.status
            if settings.launchAtLogin, status != .enabled {
                try SMAppService.mainApp.register()
            } else if !settings.launchAtLogin, status == .enabled {
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

    private func legacyWatcherLoaded() -> Bool {
        FileManager.default.fileExists(atPath: legacyWatcherPlistURL.path)
            && runLaunchctl(["print", "gui/\(getuid())/\(legacyWatcherLabel)"]).code == 0
    }

    // MARK: - Panel write-through

    // Every control writes through the settings store and applies
    // immediately (spec "The dropdown"). Setters are safe to call while
    // ungranted: they persist the preference, and the live half applies when
    // startFeatures() runs.

    func setJailEnabled(_ on: Bool) {
        settings?.jailEnabled = on
        panel.jailEnabled = on
        jailEnabled = on
        if state.featuresRunning { refresh() }
    }

    // Persist the bundle id and the display name together (spec "Game
    // picker"): the synthesized row needs both when the target is absent.
    func setTarget(bundleID: String, name: String) {
        settings?.targetBundleID = bundleID
        settings?.targetDisplayName = name
        panel.targetBundleID = bundleID
        panel.targetName = name
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
            guard response == .OK, let url = chooser.url,
                  let bundle = Bundle(url: url),
                  let id = bundle.bundleIdentifier else { return }
            let name = (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle.infoDictionary?["CFBundleName"] as? String)
                ?? url.deletingPathExtension().lastPathComponent
            self?.setTarget(bundleID: id, name: name)
        }
    }

    func setAccelerationOff(_ on: Bool) {
        settings?.accelerationOff = on
        panel.accelOff = on
        if on {
            // The enable half waits for trust: startup step 6 owns when the
            // property is first taken.
            guard state.featuresRunning else { return }
            startAcceleration()
        } else if pointerAccel != nil {
            // disable() restores the original and stops the reassert timer.
            // Runs even while ungranted: a revoked grant leaves pointerAccel
            // holding the property (stopFeatures keeps it under control), so
            // the off half must not wait for featuresRunning.
            pointerAccel?.disable()
            pointerAccel = nil
            state.accelHeld = false
            state.accelWriteFailing = false
            state.accelUnresponsive = false
        }
    }

    func setInvertVertical(_ on: Bool) {
        settings?.invertVertical = on
        panel.invertVertical = on
        applyScrollConfigs()
    }

    func setMulThousandths(_ thousandths: Int) {
        settings?.mulThousandths = thousandths
        // Read back so the mirror carries what storage actually clamped to.
        panel.mulThousandths = settings?.mulThousandths ?? thousandths
        applyScrollConfigs()
    }

    func setLaunchAtLogin(_ on: Bool) {
        settings?.launchAtLogin = on
        panel.launchAtLogin = on
        syncLoginItem()
    }

    func setInvertHorizontal(_ on: Bool) {
        settings?.invertHorizontal = on
        panel.invertHorizontal = on
        applyScrollConfigs()
    }

    func setFlattenNotches(_ on: Bool) {
        settings?.flattenNotches = on
        panel.flattenNotches = on
        applyScrollConfigs()
    }

    func setLinesPerNotch(_ lines: Int) {
        settings?.linesPerNotch = lines
        // Read back so the mirror carries what storage actually clamped to.
        panel.linesPerNotch = settings?.linesPerNotch ?? lines
        applyScrollConfigs()
    }

    func setAltTrackpadDetection(_ on: Bool) {
        settings?.altTrackpadDetection = on
        panel.altTrackpadDetection = on
        applyScrollConfigs()
    }

    func setCornerRadius(_ radius: Double) {
        settings?.cornerRadius = radius
        panel.cornerRadiusSetting = settings?.cornerRadius ?? radius
        cornerRadius = CGFloat(panel.cornerRadiusSetting)
        // The clamp rebuilds from the global on the next refresh; force one so
        // the new arc applies now rather than on the 0.5s tick.
        if state.featuresRunning { refresh() }
    }

    // MARK: - Hotkey

    // Persist first, then register: a chord another app owns still stores and
    // displays, with the failure shown in the row (spec's recorder rules).
    func setHotkey(keyCode: Int, modifiers: Int) {
        settings?.hotkeyKeyCode = keyCode
        settings?.hotkeyModifiers = modifiers
        panel.hotkeyKeyCode = keyCode
        panel.hotkeyModifiers = modifiers
        applyHotkey()
    }

    // The recorder releases the registration while capturing: an active
    // RegisterEventHotKey swallows its own chord globally, so re-recording
    // the current chord would otherwise never reach either mechanism.
    func beginHotkeyCapture() { hotkeyCenter.unregister() }
    func endHotkeyCapture() { applyHotkey() }

    private func applyHotkey() {
        guard let settings else { return }
        state.hotkeyRegistrationFailed = !hotkeyCenter.apply(
            keyCode: settings.hotkeyKeyCode, modifiers: settings.hotkeyModifiers)
    }

    // MARK: - Resets

    // "Reset to defaults" per the spec: erase chosen settings (never
    // recovery.-prefixed keys; the store enforces that) and reapply the
    // defaults immediately. For acceleration that means writing -1 again,
    // not restoring: the default is on, so a running feature keeps holding
    // and a stopped one starts.
    func resetToDefaults() {
        guard let settings else { return }
        settings.resetToDefaults()
        applySettings(settings)
        applyHotkey()
        syncLoginItem()
        if state.featuresRunning {
            if settings.accelerationOff, pointerAccel == nil { startAcceleration() }
            refresh()
        }
    }

    // Strict order from the spec: restore acceleration and re-associate the
    // cursor BEFORE clearing UserDefaults, or the only record of the real
    // acceleration value is destroyed while the live property is still -1.
    // Then unregister the watcher agent and the login item (and boot out the
    // legacy plist if one exists), then clear everything, then exit.
    func resetEverythingAndQuit() -> Never {
        pointerAccel?.restore()
        CGAssociateMouseAndMouseCursorPosition(1)
        try? SMAppService.agent(plistName: watcherPlistName).unregister()
        bootOutLegacyWatcher()
        try? SMAppService.mainApp.unregister()
        UserDefaults.standard.removePersistentDomain(
            forName: Bundle.main.bundleIdentifier ?? cataclysmBundleID)
        exit(0)
    }

    // Boots out and deletes the legacy job. Run by "Reset everything and
    // quit" and after a successful SMAppService registration that makes a
    // leftover legacy job redundant.
    private func bootOutLegacyWatcher() {
        guard FileManager.default.fileExists(atPath: legacyWatcherPlistURL.path)
        else { return }
        runLaunchctl(["bootout", "gui/\(getuid())/\(legacyWatcherLabel)"])
        try? FileManager.default.removeItem(at: legacyWatcherPlistURL)
    }

    private func applyScrollConfigs() {
        guard let settings else { return }
        scrollVerticalConfig = settings.verticalScrollConfig
        scrollHorizontalConfig = settings.horizontalScrollConfig
        scrollAltDetection = settings.altTrackpadDetection
    }

    // Menu Quit per the spec: restore the acceleration property, re-associate
    // the cursor, exit 0. The atexit restorer runs the same two calls again,
    // which is fine because both are idempotent.
    func quit() -> Never {
        pointerAccel?.restore()
        CGAssociateMouseAndMouseCursorPosition(1)
        exit(0)
    }

    // Restore on every exit path: a stale disconnect leaves the cursor frozen
    // and a stale -1 leaves acceleration off. Raw signal handlers calling
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
    // versions (spec keeps the button until the poll is verified enough).
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
        let other = NSRunningApplication
            .runningApplications(withBundleIdentifier: cataclysmBundleID)
            .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        _ = NSApplication.shared
        let alert = NSAlert()
        alert.messageText = "\(other?.localizedName ?? "Cataclysm") is already running"
        alert.informativeText =
            "This copy will quit. The running instance keeps control of the "
            + "cursor and pointer settings."
        alert.runModal()
    }

    private func showMoveToApplicationsScreen() {
        _ = NSApplication.shared
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

struct CataclysmApp: App {
    var body: some Scene {
        // `.window` style is a spec requirement: the scroll slider does not
        // render in `.menu`.
        MenuBarExtra("Cataclysm") {
            PanelView(state: AppRuntime.shared.state, model: AppRuntime.shared.panel)
        }
        .menuBarExtraStyle(.window)
    }
}

// The default view (spec "The dropdown"): header, jail toggle with the game
// row, acceleration toggle, invert-wheel toggle, scroll speed slider, Launch
// at login, Quit. Width fixed at 320 points so the panel never reflows as
// values change. The Advanced DisclosureGroup is Task 9.
struct PanelView: View {
    @ObservedObject var state: AppState
    @ObservedObject var model: SettingsModel
    // View-local drag state; committed to storage on release, since the panel
    // dismisses on outside clicks and live preview is impossible anyway.
    @State private var sliderPos = 0.0
    @State private var draggingSlider = false

    // Ungranted: both taps are down, so the jail and the scroll filter read
    // unavailable rather than on. The acceleration property needs no grant
    // but is only applied after trust (startup step 6), so its failure states
    // can only exist while trusted.
    private var jailFailed: Bool { state.featuresRunning && !state.jailTapUp }
    private var scrollFailed: Bool { state.featuresRunning && !state.scrollTapUp }
    private var accelFailed: Bool { state.accelWriteFailing || state.accelUnresponsive }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if state.trusted && !state.watcherRegistered { watcherRow }
            if let watcherError = state.watcherError {
                Text(watcherError).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            jailSection
            Divider()
            scrollSection
            Divider()
            advancedSection
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 320)
        .onAppear {
            AppRuntime.shared.reloadPanel()
            AppRuntime.shared.refreshWatcherStatus()
            AppRuntime.shared.refreshAccelHealth()
            sliderPos = sliderPosition(
                forMultiplier: Double(model.mulThousandths) / 1_000)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Cataclysm").font(.headline)
            if state.trusted {
                Text("Accessibility granted")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Label("Accessibility not granted",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button("Grant…") { AppRuntime.shared.showOnboarding() }
                }
            }
        }
    }

    private var watcherRow: some View {
        HStack {
            Label(state.watcherRequiresApproval
                    ? "Crash recovery needs approval"
                    : "Crash recovery is off",
                  systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
            Spacer()
            Button("Login Items…") {
                let link = "x-apple.systempreferences:"
                    + "com.apple.LoginItems-Settings.extension"
                if let url = URL(string: link) { NSWorkspace.shared.open(url) }
            }
        }
    }

    private var jailSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            featureToggle("Lock cursor to game window",
                          isOn: model.jailEnabled,
                          failed: jailFailed,
                          set: { AppRuntime.shared.setJailEnabled($0) })
            gameRow.padding(.leading, 18)
        }
    }

    // Sentinel tag for the chooser row; a bundle id can never be empty here
    // because rows without one are excluded from the list.
    private let chooseTag = ""

    // Rows tagged by bundle id, never by name, so two apps with the same
    // display name stay distinguishable. Selecting the chooser row opens the
    // NSOpenPanel and leaves the stored selection untouched until it returns.
    private var gameRow: some View {
        Picker("Game", selection: Binding(
            get: { model.targetBundleID },
            set: { tag in
                if tag == chooseTag {
                    AppRuntime.shared.chooseTargetFromApplications()
                } else if let row = model.pickerRows.first(where: { $0.bundleID == tag }) {
                    AppRuntime.shared.setTarget(bundleID: row.bundleID, name: row.name)
                }
            })) {
            ForEach(model.pickerRows, id: \.bundleID) { row in
                HStack(spacing: 6) {
                    Image(nsImage: icon(for: row))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(row.label)
                }
                .tag(row.bundleID)
            }
            Divider()
            Text("Choose from Applications…").tag(chooseTag)
        }
    }

    // Icons resolve at render time: running rows use NSRunningApplication's
    // icon, the synthesized stored row falls back to the generic app icon.
    private func icon(for row: GamePickerRow) -> NSImage {
        if row.isRunning,
           let app = NSWorkspace.shared.runningApplications
               .first(where: { $0.bundleIdentifier == row.bundleID }),
           let appIcon = app.icon {
            return appIcon
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }

    private var scrollSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            accelToggle
            featureToggle("Invert wheel scrolling",
                          isOn: model.invertVertical,
                          failed: scrollFailed,
                          set: { AppRuntime.shared.setInvertVertical($0) })
            sliderRow
        }
    }

    // Unavailable while ungranted only until the property is actually taken:
    // step 6 defers the first write to trust, so a checked toggle before then
    // would claim a curve that is still accelerating. Once held, a lost grant
    // does not release the property, so the toggle stays live.
    private var accelToggle: some View {
        featureToggle("Mouse acceleration off",
                      isOn: model.accelOff,
                      failed: accelFailed,
                      unavailable: !state.trusted && !state.accelHeld,
                      set: { AppRuntime.shared.setAccelerationOff($0) })
    }

    // One rendering rule for every feature toggle: unavailable reads
    // unchecked and disabled, failed reads unchecked with a red caption
    // rather than checked, and only a healthy feature shows its stored value.
    private func featureToggle(_ title: String, isOn: Bool, failed: Bool,
                               unavailable: Bool? = nil,
                               set: @escaping (Bool) -> Void) -> some View {
        let unavailable = unavailable ?? !state.trusted
        return HStack {
            Toggle(title, isOn: Binding(
                get: { isOn && !unavailable && !failed },
                set: set))
                .toggleStyle(.checkbox)
                .disabled(unavailable)
            if failed {
                Spacer()
                Text("failed").font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var sliderRow: some View {
        // While dragging the readout previews the snapped release value;
        // parked, it shows the stored value even beyond the slider's range.
        let readout = draggingSlider
            ? mulThousandths(forMultiplier: multiplier(forSliderPosition: sliderPos))
            : model.mulThousandths
        return HStack(spacing: 6) {
            Text("Scroll speed")
            Slider(value: $sliderPos, in: sliderPositionRange) { editing in
                draggingSlider = editing
                if !editing { commitSlider() }
            }
            Text(multiplierLabel(forThousandths: readout))
                .monospacedDigit()
            Button {
                AppRuntime.shared.setMulThousandths(1_000)
                sliderPos = sliderPosition(forMultiplier: 1.0)
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .help("Reset to 1.00x")
        }
        .disabled(!state.trusted || scrollFailed)
    }

    private func commitSlider() {
        let thousandths = mulThousandths(
            forMultiplier: multiplier(forSliderPosition: sliderPos))
        AppRuntime.shared.setMulThousandths(thousandths)
        sliderPos = sliderPosition(
            forMultiplier: Double(AppRuntime.shared.panel.mulThousandths) / 1_000)
    }

    // The Advanced group (spec "The dropdown"): collapsed by default, holding
    // the knobs a player has no reason to touch. Scroll knobs share the
    // slider's disabled rule; the hotkey row, corner radius, and the commands
    // stay live because they are preference writes, not tap-dependent.
    private var advancedSection: some View {
        DisclosureGroup("Advanced") {
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    featureToggle("Invert horizontal scrolling",
                                  isOn: model.invertHorizontal,
                                  failed: scrollFailed,
                                  set: { AppRuntime.shared.setInvertHorizontal($0) })
                    featureToggle("Flatten scroll notches",
                                  isOn: model.flattenNotches,
                                  failed: scrollFailed,
                                  set: { AppRuntime.shared.setFlattenNotches($0) })
                    stepperRow("Lines per notch",
                               value: model.linesPerNotch, range: 1...1000,
                               set: { AppRuntime.shared.setLinesPerNotch($0) })
                        .disabled(!state.trusted || scrollFailed)
                    featureToggle("Alternate trackpad detection",
                                  isOn: model.altTrackpadDetection,
                                  failed: scrollFailed,
                                  set: { AppRuntime.shared.setAltTrackpadDetection($0) })
                }
                HotkeyRow(state: state, model: model)
                stepperRow("Corner radius",
                           value: Int(model.cornerRadiusSetting), range: 0...200,
                           set: { AppRuntime.shared.setCornerRadius(Double($0)) })
                    .help("Radius of the jail's rounded corners; 0 disables corner clamping")
                Divider()
                Button("Check for updates…") {
                    // Canonical post-rename URL; the repo rename is a
                    // release-checklist item that makes it live.
                    let releases = "https://github.com/heyitaki/cataclysm/releases"
                    if let url = URL(string: releases) { NSWorkspace.shared.open(url) }
                }
                Button("Reset to defaults") {
                    AppRuntime.shared.resetToDefaults()
                    // sliderPos is view-local drag state; resync it to the
                    // freshly reset stored multiplier.
                    sliderPos = sliderPosition(forMultiplier:
                        Double(AppRuntime.shared.panel.mulThousandths) / 1_000)
                }
                Button("Reset everything and quit") {
                    AppRuntime.shared.resetEverythingAndQuit()
                }
            }
            .padding(.top, 6)
        }
    }

    private func stepperRow(_ title: String, value: Int, range: ClosedRange<Int>,
                            set: @escaping (Int) -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(value)").monospacedDigit()
            Stepper(title, value: Binding(get: { value }, set: set), in: range)
                .labelsHidden()
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Launch at login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { AppRuntime.shared.setLaunchAtLogin($0) }))
                .toggleStyle(.checkbox)
            if let error = state.loginItemError {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Quit") { AppRuntime.shared.quit() }
        }
    }
}

// MARK: - Hotkey recorder

// The jail toggle hotkey row (spec's recorder rules). Mechanism 1 is a local
// keyDown monitor installed while recording; mechanism 2 is the first-
// responder KeyCaptureNSView sitting invisibly in the row, armed on the same
// flag. Whichever fires first wins via the single handle() path. Two rules
// hold on every exit: recording cancels keeping the previous chord when the
// panel dismisses (onDisappear), and the monitor and responder are torn down
// on that same path, so a dismissed panel leaves nothing capturing keys.
struct HotkeyRow: View {
    @ObservedObject var state: AppState
    @ObservedObject var model: SettingsModel
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text("Jail toggle hotkey")
            if state.hotkeyRegistrationFailed {
                Text("in use by another app").font(.caption).foregroundStyle(.red)
            }
            Spacer()
            KeyCapture(recording: recording, onKey: handle)
                .frame(width: 0, height: 0)
            Button(recording
                    ? "Press keys… (Esc cancels)"
                    : hotkeyChordLabel(keyCode: model.hotkeyKeyCode,
                                       modifiers: model.hotkeyModifiers)) {
                recording ? stopRecording() : startRecording()
            }
            .monospacedDigit()
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

// SwiftUI host for mechanism 2's NSView. Arming takes first responder on the
// next runloop turn because the view may not be in a window yet on the first
// update; disarming returns key focus to the window.
struct KeyCapture: NSViewRepresentable {
    let recording: Bool
    let onKey: (NSEvent) -> Bool

    func makeNSView(context: Context) -> KeyCaptureNSView { KeyCaptureNSView() }

    func updateNSView(_ view: KeyCaptureNSView, context: Context) {
        view.onKey = onKey
        if recording {
            DispatchQueue.main.async {
                view.window?.makeFirstResponder(view)
            }
        } else if view.window?.firstResponder === view {
            view.window?.makeFirstResponder(nil)
        }
    }
}
