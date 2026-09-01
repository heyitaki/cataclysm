// Cataclysm app entry. `main()` dispatches on arguments before SwiftUI ever
// loads, so the watcher (`--watch`) and the acceptance gate (`--smoke-register`)
// never start UI, never touch AppKit state, and can run headless under launchd.
// A plain launch runs the spec's six startup steps in order: instance lock,
// cursor re-association, install-location gate, clamped settings load, trust
// check, and only then taps, the acceleration property, and agent
// registration. Steps 1-3 run before any UI, so a duplicate launch or a
// launch from the DMG never flashes a panel.

import SwiftUI

let cataclysmBundleID = "io.github.heyitaki.cataclysm"

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

// Published state the panel reads. Task 7 builds the real status rows; Task 6
// owns trusted/featuresRunning and the tap-creation results they need.
final class AppState: ObservableObject {
    @Published var trusted = false
    @Published var featuresRunning = false
    @Published var jailTapUp = false
    @Published var scrollTapUp = false
}

// MARK: - Startup sequence and feature lifecycle

final class AppRuntime {
    static let shared = AppRuntime()
    let state = AppState()

    private let lock: InstanceLock
    private var settings: Settings?
    private var pointerAccel: PointerAccel?
    private var refreshTimer: Timer?
    private var trustTimer: Timer?
    private var activationObserver: NSObjectProtocol?
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
        scrollVerticalConfig = s.verticalScrollConfig
        scrollHorizontalConfig = s.horizontalScrollConfig
        scrollAltDetection = s.altTrackpadDetection
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
        if let settings, settings.accelerationOff, pointerAccel == nil {
            let accel = PointerAccel()
            accel.enable()
            pointerAccel = accel
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

    // Task 10 implements SMAppService registration. The ordering hook is what
    // this task owns: called only after trust, so the agent is never
    // registered on a first launch that is still ungranted or quarantined.
    private func registerAgentsIfNeeded() {
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

// MARK: - Panel placeholder

struct CataclysmApp: App {
    var body: some Scene {
        // Placeholder panel; Task 7 builds the real layout. `.window` style is
        // a spec requirement: the scroll slider does not render in `.menu`.
        MenuBarExtra("Cataclysm") {
            PanelPlaceholderView()
        }
        .menuBarExtraStyle(.window)
    }
}

struct PanelPlaceholderView: View {
    @ObservedObject var state = AppRuntime.shared.state

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cataclysm")
            if !state.trusted {
                Text("Accessibility access is off; the jail and scroll "
                    + "filter are unavailable.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Onboarding") { AppRuntime.shared.showOnboarding() }
            }
        }
        .frame(width: 320)
        .padding()
    }
}
