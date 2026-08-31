// Watcher-shaped probe for the legacy LaunchAgent fallback: proves launchd
// actually EXECUTES a job whose program carries only an ad-hoc signature,
// which is weaker than the self-signed identity phase 3a would use. Writes a
// marker naming its own signing status and exits.
import Foundation
import CoreGraphics
let marker = CommandLine.arguments.dropFirst().first ?? "/tmp/watchprobe.marker"
var code: SecStaticCode?
var desc = "unknown"
if let url = URL(string: "file://" + (Bundle.main.executablePath ?? "")),
   SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let c = code {
    var info: CFDictionary?
    if SecCodeCopySigningInformation(c, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
       let d = info as? [String: Any] {
        let flags = (d["flags"] as? UInt32) ?? 0
        let ident = (d["identifier"] as? String) ?? "none"
        desc = "identifier=\(ident) flags=0x\(String(flags, radix: 16))"
    }
}
// the one call the real watcher makes
let err = CGAssociateMouseAndMouseCursorPosition(1)
try? "ran pid=\(ProcessInfo.processInfo.processIdentifier) signing=\(desc) associate=\(err.rawValue)\n"
    .write(toFile: marker, atomically: true, encoding: .utf8)
exit(0)
