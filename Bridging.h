// IOKit HID headers for the pointer acceleration property; swiftc gets this
// via -import-objc-header since there is no Xcode project.
#import <IOKit/hidsystem/IOHIDEventSystemClient.h>
#import <IOKit/hid/IOHIDProperties.h>
// proc_pidpath, for the smoke gate's proof that launchd spawned the watcher
// from the executable inside the bundle.
#import <libproc.h>
