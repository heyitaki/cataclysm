// Does hardened runtime, with no entitlements at all, block an active
// CGEventTap or the Accessibility APIs? Signed with --options runtime and run.
//
// The tap is attempted only when this process is already Accessibility
// trusted. Creating an active tap from an untrusted process raises the system
// "wants to receive keystrokes" dialog, and no check here may put a permission
// prompt on someone's screen. Untrusted behavior is a recorded measurement
// (appendix claim 3b), not something this script re-runs.
import Cocoa
let trusted = AXIsProcessTrusted()
print("AXIsProcessTrusted:", trusted)
if trusted {
    let mask: CGEventMask = (1 << CGEventType.mouseMoved.rawValue)
    let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                options: .defaultTap, eventsOfInterest: mask,
                                callback: { _, _, e, _ in Unmanaged.passUnretained(e) },
                                userInfo: nil)
    print("tapCreate:", tap == nil ? "nil (refused)" : "created")
} else {
    print("tapCreate: not attempted (untrusted process, would raise a permission dialog)")
}
let el = AXUIElementCreateSystemWide()
var v: CFTypeRef?
let err = AXUIElementCopyAttributeValue(el, kAXFocusedApplicationAttribute as CFString, &v)
print("AXUIElementCopyAttributeValue:", err.rawValue)
