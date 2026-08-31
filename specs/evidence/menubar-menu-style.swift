import SwiftUI
import AppKit

struct AppChoice: Identifiable, Hashable {
    let id: String   // bundle id
    let name: String
}

final class Model: ObservableObject {
    @Published var jail = true
    @Published var accelOff = true
    @Published var invertWheel = true
    @Published var scrollSpeed = 1.0
    @Published var target = "com.riotgames.LeagueofLegends.GameClient"
    @Published var choices: [AppChoice] = []

    func refresh() {
        var seen = Set<String>()
        var out: [AppChoice] = []
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular {
            guard let bid = app.bundleIdentifier, let name = app.localizedName else { continue }
            if seen.insert(bid).inserted { out.append(AppChoice(id: bid, name: name)) }
        }
        choices = out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

struct Panel: View {
    @ObservedObject var model: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Lock cursor to game window", isOn: $model.jail)
            Picker("Game", selection: $model.target) {
                ForEach(model.choices) { c in Text(c.name).tag(c.id) }
            }
            Divider()
            Toggle("Mouse acceleration off", isOn: $model.accelOff)
            Toggle("Invert wheel scrolling", isOn: $model.invertWheel)
            HStack {
                Text("Scroll speed")
                Slider(value: $model.scrollSpeed, in: 0.25...4.0)
                Text(String(format: "%.2fx", model.scrollSpeed)).monospacedDigit()
            }
            Divider()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .padding(12)
        .frame(width: 320)
        .onAppear { model.refresh() }
    }
}

struct TestApp: App {
    @StateObject var model = Model()
    var body: some Scene {
        MenuBarExtra("mj", systemImage: "cursorarrow.rays") {
            Panel(model: model)
        }
        .menuBarExtraStyle(.menu)
    }
}

TestApp.main()
