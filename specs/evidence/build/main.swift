// Mirrors the spec: arg dispatch before the app starts, App.main() explicit
// because a module cannot have both main.swift and an @main type.
import AppKit
let args = CommandLine.arguments.dropFirst()
if args.contains("--release") {
    CGAssociateMouseAndMouseCursorPosition(1)
    exit(0)
}
if args.contains("--watch") {
    // recovery job: no UI, no tap
    CGAssociateMouseAndMouseCursorPosition(1)
    exit(0)
}
CataclysmApp.main()
