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
            // Task 10 implements the re-association watcher loop. The watcher
            // takes no instance lock by design: it only ever calls the
            // idempotent release.
            print("cataclysm --watch: not implemented yet")
            exit(0)
        }
        if args.contains("--smoke-register") {
            // Task 11 implements the SMAppService registration smoke gate.
            print("cataclysm --smoke-register: not implemented yet")
            exit(0)
        }
        AppRuntime.shared.preflight()
        AppRuntime.shared.start()
        CataclysmApp.main()
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
    @Published var watcherRegistered = false
    @Published var watcherRequiresApproval = false
    @Published var loginItemError: String?
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
}

// MARK: - Startup sequence and feature lifecycle

final class AppRuntime {
    static let shared = AppRuntime()
    let state = AppState()
    let panel = SettingsModel()

    private let lock: InstanceLock
    private var settings: Settings?
    private var pointerAccel: PointerAccel?
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
    }

    // Re-probe on panel open: a HID client that recovers without ever passing
    // through a failing write never fires onWriteHealthChange, so the latched
    // unresponsive flag has to be re-read when someone looks.
    func refreshAccelHealth() {
        guard let pointerAccel else { return }
        state.accelUnresponsive = !pointerAccel.clientResponsive
        state.accelWriteFailing = pointerAccel.writeFailing
    }

    // Task 10 implements SMAppService watcher registration. The ordering hook
    // is what Task 6 owns: called only after trust, so no agent is ever
    // registered on a first launch that is still ungranted or quarantined.
    // The login item half is live already: reconcile the stored preference
    // once trust lets startup finish.
    private func registerAgentsIfNeeded() {
        syncLoginItem()
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

    // Read-only status probe for the crash-recovery row; registration itself
    // is Task 10's. Until it lands, status reads .notRegistered and the row
    // truthfully says crash recovery is off.
    func refreshWatcherStatus() {
        let status = SMAppService.agent(plistName: watcherPlistName).status
        state.watcherRegistered = status == .enabled
        state.watcherRequiresApproval = status == .requiresApproval
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
        guard state.featuresRunning else { return }
        if on {
            startAcceleration()
        } else {
            // disable() restores the original and stops the reassert timer.
            pointerAccel?.disable()
            pointerAccel = nil
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
            Divider()
            jailSection
            Divider()
            scrollSection
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

    private var accelToggle: some View {
        featureToggle("Mouse acceleration off",
                      isOn: model.accelOff,
                      failed: accelFailed,
                      unavailable: false,
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
