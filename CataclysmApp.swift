// Cataclysm app entry. `main()` dispatches on arguments before SwiftUI ever
// loads, so the watcher (`--watch`) and the acceptance gate (`--smoke-register`)
// never start UI, never touch AppKit state, and can run headless under launchd.
// Only a plain launch falls through to the SwiftUI app.

import SwiftUI

@main
struct CataclysmMain {
    static func main() {
        let args = CommandLine.arguments.dropFirst()
        if args.contains("--watch") {
            // Task 10 implements the re-association watcher loop.
            print("cataclysm --watch: not implemented yet")
            exit(0)
        }
        if args.contains("--smoke-register") {
            // Task 11 implements the SMAppService registration smoke gate.
            print("cataclysm --smoke-register: not implemented yet")
            exit(0)
        }
        CataclysmApp.main()
    }
}

struct CataclysmApp: App {
    var body: some Scene {
        // Placeholder panel; Task 7 builds the real layout. `.window` style is
        // a spec requirement: the scroll slider does not render in `.menu`.
        MenuBarExtra("Cataclysm") {
            Text("Cataclysm")
                .frame(width: 320)
                .padding()
        }
        .menuBarExtraStyle(.window)
    }
}

// Globals the shared Jail/TapHost modules read. The CLI derives them from
// arguments in main.swift; here they hold the spec defaults until Tasks 6-7
// wire them through the settings store. The taps are never started in this
// target yet, so these values are only ever read by the compiler.
let gameBundle = "com.riotgames.LeagueofLegends.GameClient"
let cornerRadius: CGFloat = 18
let scrollVerticalConfig = ScrollAxisConfig(
    invert: true, flatten: true, linesPerNotch: 1, mulThousandths: 1_000)
let scrollHorizontalConfig = ScrollAxisConfig(
    invert: false, flatten: true, linesPerNotch: 1, mulThousandths: 1_000)
let scrollAltDetection = false
let scrollDump = false

// TapHost calls this on tap-creation failure. Task 6 replaces the exit with
// the panel's unavailable-feature state; until the app starts taps it is dead
// code needed only to link.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
}
