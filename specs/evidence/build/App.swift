// Fixture: the panel plan-v1 specifies, reduced to the API surface whose
// availability at the macOS 13 floor is load-bearing. Not the real app.
import SwiftUI
import AppKit
import ServiceManagement
import Carbon.HIToolbox
import ApplicationServices

struct Target: Hashable, Identifiable {
    let id: String      // bundle id
    let name: String
}

final class Model: ObservableObject {
    @AppStorage("jailEnabled") var jailEnabled = true
    @AppStorage("accelOff") var accelOff = true
    @AppStorage("invertWheel") var invertWheel = true
    @AppStorage("launchAtLogin") var launchAtLogin = false
    @AppStorage("mulThousandths") var mulThousandths = 1000
    @AppStorage("targetBundleId") var targetBundleId = "com.riotgames.LeagueofLegends.GameClient"
    @AppStorage("targetName") var targetName = "League of Legends"
    @Published var running: [Target] = []
    @Published var trusted = AXIsProcessTrusted()

    func rebuild() {
        var seen = Set<String>()
        var out: [Target] = [Target(id: targetBundleId, name: targetName)]
        seen.insert(targetBundleId)
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular {
            guard let bid = app.bundleIdentifier, !seen.contains(bid) else { continue }
            seen.insert(bid)
            out.append(Target(id: bid, name: app.localizedName ?? bid))
        }
        running = out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func observe() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                       object: nil, queue: .main) { _ in self.rebuild() }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                       object: nil, queue: .main) { _ in self.rebuild() }
        nc.addObserver(forName: NSWorkspace.didWakeNotification,
                       object: nil, queue: .main) { _ in }
    }

    func promptForTrust() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    func openAccessibilityPane() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    func chooseFromApplications() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url,
           let bundle = Bundle(url: url), let bid = bundle.bundleIdentifier {
            targetBundleId = bid
            targetName = url.deletingPathExtension().lastPathComponent
        }
    }

    // The LaunchAgent registration the crash-recovery job needs.
    func registerAgent() throws {
        let agent = SMAppService.agent(plistName: "com.example.cataclysm.watch.plist")
        if agent.status != .enabled { try agent.register() }
    }

    func setLoginItem(_ on: Bool) throws {
        let app = SMAppService.mainApp
        if on { try app.register() } else { try app.unregister() }
    }
}

// Carbon hotkey: needs no extra permission, per pointer-and-scroll.md.
func installHotkey() {
    var hotKeyRef: EventHotKeyRef?
    var id = EventHotKeyID(signature: OSType(0x43544c4d), id: 1)
    let mods = UInt32(cmdKey | optionKey)
    RegisterEventHotKey(UInt32(kVK_ANSI_L), mods, id, GetEventDispatcherTarget(), 0, &hotKeyRef)
    _ = id
}

struct Panel: View {
    @ObservedObject var model: Model
    @State private var advanced = false

    // Log-scale slider position <-> multiplier, 0.25x .. 4.0x.
    private var sliderPos: Binding<Double> {
        Binding(get: { log2(Double(model.mulThousandths) / 1000.0) },
                set: { model.mulThousandths = Int((pow(2.0, $0) * 1000).rounded()) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cataclysm").font(.headline)
            if model.trusted {
                Text("Accessibility granted").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("Accessibility not granted").font(.caption)
                    Button("Fix") { model.promptForTrust() }
                }
            }
            Divider()
            Toggle("Lock cursor to game window", isOn: $model.jailEnabled)
            Picker("Game", selection: $model.targetBundleId) {
                ForEach(model.running) { t in Text(t.name).tag(t.id) }
                Divider()
                Text("Choose from Applications…").tag("__choose__")
            }
            Divider()
            Toggle("Mouse acceleration off", isOn: $model.accelOff)
            Toggle("Invert wheel scrolling", isOn: $model.invertWheel)
            HStack {
                Text("Scroll speed")
                Slider(value: sliderPos, in: -2.0...2.0)
                Text(String(format: "%.2fx", Double(model.mulThousandths) / 1000))
                    .monospacedDigit()
                Button { model.mulThousandths = 1000 } label: { Image(systemName: "arrow.counterclockwise") }
            }
            Divider()
            DisclosureGroup("Advanced", isExpanded: $advanced) {
                Toggle("Invert horizontal", isOn: .constant(false))
                Stepper("Lines per notch: 1", value: .constant(1), in: 1...1000)
                Button("Choose from Applications…") { model.chooseFromApplications() }
                Button("Reset everything and quit") { NSApp.terminate(nil) }
            }
            Divider()
            Toggle("Launch at login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { on in model.launchAtLogin = on; try? model.setLoginItem(on) }))
            Button("Quit") { NSApp.terminate(nil) }
        }
        .padding(12)
        .frame(width: 320)
        .onAppear { model.rebuild(); model.observe(); installHotkey(); try? model.registerAgent() }
    }
}

struct CataclysmApp: App {
    @StateObject private var model = Model()
    var body: some Scene {
        MenuBarExtra("Cataclysm", systemImage: "cursorarrow.rays") {
            Panel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
