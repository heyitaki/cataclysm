// The IOKit call pointer-and-scroll.md requires a bridging header for.
import Foundation
import IOKit
func setAccel(_ v: Int32) -> Bool {
    let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    var value = v
    guard let number = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &value) else { return false }
    let r = IOHIDEventSystemClientSetProperty(client, kIOHIDMouseAccelerationType as CFString, number); return r && v != 0
}


