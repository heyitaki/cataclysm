// Does an untrusted process (no Accessibility grant) still get to call
// CGAssociateMouseAndMouseCursorPosition(1)? Only the re-associate direction
// is exercised: it is the direction crash recovery uses and it cannot freeze
// a cursor.
//
// This probe deliberately makes no TCC-gated call. An earlier version also
// called CGEvent.tapCreate here, which raised the system "wants to receive
// keystrokes" dialog on every run and left a row in System Settings. That
// measurement was taken once and is recorded in the spec's appendix as claim
// 3b instead of being repeated: an untrusted bundle gets nil from an active
// tap while these two calls succeed.
import Cocoa
let out = "/tmp/assocprobe.txt"
var lines: [String] = []
lines.append("trusted=\(AXIsProcessTrusted())")
lines.append("bundle=\(Bundle.main.bundleIdentifier ?? "nil")")
let err = CGAssociateMouseAndMouseCursorPosition(1)
lines.append("CGAssociateMouseAndMouseCursorPosition(1) -> \(err.rawValue) (success=\(err == .success))")
lines.append("tapCreate=not-attempted (recorded measurement, see appendix claim 3b)")
try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
exit(0)
