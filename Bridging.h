// IOKit HID headers for the pointer acceleration property; swiftc gets this
// via -import-objc-header since there is no Xcode project.
#import <IOKit/hidsystem/IOHIDEventSystemClient.h>
#import <IOKit/hidsystem/IOHIDServiceClient.h>
#import <IOKit/hid/IOHIDProperties.h>

// Not in the public headers, but exported by IOKit and what LinearMouse and
// its kin ship on. The public "simple" client (the one the acceleration
// property goes through) neither reads nor writes
// HIDUseLinearScalingMouseAcceleration: reads answer nil and writes return
// false, on macOS 26 with a mouse attached, while a passive client reads
// the flag from every mouse service and the system, writes it, and reads
// the write back. Only the passive type is used here.
typedef CF_ENUM(int, IOHIDEventSystemClientType) {
    kIOHIDEventSystemClientTypeAdmin,
    kIOHIDEventSystemClientTypeMonitor,
    kIOHIDEventSystemClientTypePassive,
    kIOHIDEventSystemClientTypeRateControlled,
    kIOHIDEventSystemClientTypeSimple,
};
CF_RETURNS_RETAINED IOHIDEventSystemClientRef _Nullable IOHIDEventSystemClientCreateWithType(
    CFAllocatorRef _Nullable allocator, IOHIDEventSystemClientType type,
    CFDictionaryRef _Nullable attributes);
// Scheduling is what Apple's IOHIDEventSystemMonitor does before it
// enumerates services, so the client can follow mice as they attach and
// detach. Unscheduled, the list is the snapshot taken at creation: a
// detached mouse stayed in it as a dead service whose writes answered
// false (observed). Whether scheduling alone keeps the list current is
// inferred, not measured; PointerAccel's fresh-client retry is what
// guarantees the write. Exported by IOKit alongside CreateWithType.
void IOHIDEventSystemClientScheduleWithRunLoop(
    IOHIDEventSystemClientRef _Nonnull client, CFRunLoopRef _Nonnull runLoop,
    CFStringRef _Nonnull runLoopMode);
void IOHIDEventSystemClientUnscheduleWithRunLoop(
    IOHIDEventSystemClientRef _Nonnull client, CFRunLoopRef _Nonnull runLoop,
    CFStringRef _Nonnull runLoopMode);
