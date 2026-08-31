# Pointer acceleration and scroll control

Spec for absorbing UnnaturalScrollWheels-class functionality into the mousejail codebase. Status: approved for implementation, phased.

## Goal

One macOS utility that owns three pointer behaviors:

1. **Pointer acceleration off.** Non-negotiable. Constant pointer speed regardless of hand velocity.
2. **Scroll direction inverted for the wheel only.** Non-negotiable. The trackpad keeps macOS natural scrolling.
3. **Scroll speed control.** Flatten each wheel notch to a fixed line count, then scale by a multiplier.

Plus the existing cursor jail, unchanged in behavior.

The immediate driver is replacing UnnaturalScrollWheels, which is currently installed and running. It solves 1 and 2 but has no speed multiplier, and it forces a fixed pixel amount per notch (see "What UnnaturalScrollWheels actually does" below).

## Non-goals

- Per-device configuration. One global setting set, matching how the machine is actually used.
- Any change to trackpad acceleration or trackpad scroll behavior. The trackpad is explicitly passed through untouched.
- Custom acceleration curves. The choice is accelerated or linear, nothing in between.
- Scroll acceleration curve shaping beyond flatten-and-multiply.
- Windows or Linux.

## Decisions taken

| Decision | Choice | Consequence |
| --- | --- | --- |
| Repo shape | One binary, feature flags, in the mousejail repo, renamed in phase 3 | One Accessibility grant, one process, shared tap lifecycle code |
| Scroll speed model | Fixed lines per notch, then a float multiplier | Needs a fractional remainder accumulator |
| Acceleration scope | Off always, while the process runs | Set at launch, restore on exit |
| Configuration | Menu bar app with a preferences window | Forces an .app bundle, retires the Hammerspoon supervisor |

Two taps, not one. The user-facing decision was one binary, which does not require one event tap. mousejail's tap is head-insert and the scroll tap should be tail-append so it sees whatever Logitech Options or similar produced and gets the last word. `CGEvent.tapCreate` takes a single placement, so combining them would force one of the two to change placement for no benefit. Two `CFMachPort`s on the same main run loop in the same process costs nothing and keeps each feature's placement independent. Their masks are disjoint, so they never see the same event.

## Architecture

Single Swift app bundle, `LSUIElement`, no Xcode project. Modules split out of today's single `main.swift`:

```
main.swift          arg dispatch (--release short circuit), then App.main()
App.swift           SwiftUI MenuBarExtra + Settings scene, app delegate
Settings.swift      UserDefaults-backed config, snapshot read by tap callbacks
PointerAccel.swift  IOHID acceleration property management
ScrollFilter.swift  scroll tap and event rewriting
Jail.swift          existing cursor confinement, verbatim behavior
TapHost.swift       shared tap creation, re-enable, teardown
```

`TapHost` factors out the lifecycle work that already exists in `main.swift` and would otherwise be duplicated: creating the tap, handling `.tapDisabledByTimeout` and `.tapDisabledByUserInput`, re-enabling on wake, and tearing down cleanly. This is the part that is genuinely hard to get right and it is already correct in the current code.

`TapHost` adds every tap's run loop source to the main run loop, which is what `main.swift` does today, so all tap callbacks run on the main thread. This is load-bearing, not incidental: the jail's `clampRect`, `virtualPos`, `engaged`, and `pendingWarp` are unsynchronized globals that are correct only because the callback, the 0.5s refresh timer, and the activation notification all run on the same thread. Hosting a tap on a private thread would make every one of them racy, so `TapHost` must not offer that option.

Config still travels to the callbacks as a snapshot guarded by `os_unfair_lock`. On the main run loop that lock is redundant, and it is kept only so a future thread change cannot silently introduce torn reads.

## Feature 1: pointer acceleration

### Mechanism

Set the HID event system's mouse acceleration property to a negative value. A negative value makes `IOHIDPointerScrollFilter` skip acceleration configuration entirely, which is what produces linear movement. This is the technique NoMouseAccel established and UnnaturalScrollWheels uses.

```swift
let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)  // type: IOHIDEventSystemClient
let key = kIOHIDMouseAccelerationType as CFString   // "HIDMouseAcceleration"
var value: Int32 = -1
guard let number = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &value) else { return }
let ok = IOHIDEventSystemClientSetProperty(client, key, number)
```

The Swift type is `IOHIDEventSystemClient`. `IOHIDEventSystemClientRef` is a hard error: it was obsoleted in Swift 3 and the compiler rejects it by name.

This is a live property on the HID event system, not a stored preference. It takes effect immediately, needs no restart, and is invisible to `defaults read`. It is why the machine currently reports `com.apple.mouse.scaling = 3` and `com.apple.mouse.linear = 0` while acceleration is in fact off.

It applies to mice. The trackpad has a separate key, `kIOHIDTrackpadAccelerationType`, which we never touch.

### Requirements

- Read the original value with `IOHIDEventSystemClientCopyProperty` before overwriting.
- **Only persist the original when it is not -1.** After a wake, or if the app is restarted while acceleration is already disabled, reading back -1 and saving it as the original destroys the real value permanently. This guard also protects against the macOS 26 System Settings toggle, which drives the same knob.
- **When the read is -1 and nothing is stored yet, fall back to 196608.** The guard above has a bootstrap hole: if the first read of the app's life is already -1, no original is ever recorded and quitting restores nothing, leaving acceleration off with no way back short of a reboot. This is the expected state right after migration if UnnaturalScrollWheels is force-quit or trashed while running, since its own clean-quit path is what writes the value back. 196608 is 3.0 in 16.16 fixed point and matches `com.apple.mouse.scaling = 3` on this machine; deriving it from the live `com.apple.mouse.scaling` is equivalent and preferable.
- `IOHIDEventSystemClientCopyProperty` returns nil while the HID subsystem is still coming back after wake. Handle nil, do not force unwrap.
- **Check the `Boolean` that `IOHIDEventSystemClientSetProperty` returns.** The SDK declares it as returning success, and the spec's own menu reports the feature as on. Ignoring the result presents a failed write as a working feature, which is indistinguishable from the acceleration curve simply feeling different. On a false, surface it rather than retrying silently.
- Restore the saved original on quit and when the setting is turned off.
- Reapply on `NSWorkspace.didWakeNotification` (posted on `NSWorkspace.shared.notificationCenter`, not `NotificationCenter.default`), and on a slow timer (5s) that reads the current value and rewrites only if it is not -1. The property does not survive HID subsystem restarts or some device reconnects.
- **Adopt a non-(-1) reading that differs from the stored original as the new original.** The reassert timer otherwise cannot tell a deliberate System Settings tracking-speed change from a competing process, so it reverts the user's change within 5s and then restores the stale value on quit. Adopting first keeps the last-writer-wins contest with other processes while letting an intentional change stick.

### Build requirement

Needs `IOKit/hidsystem/IOHIDEventSystemClient.h` and `IOKit/hid/IOHIDProperties.h`, both present in the macOS SDK. Since the build is `swiftc` from a Makefile rather than an Xcode project, expose them with a bridging header:

```
xcrun swiftc -O -import-objc-header Bridging.h *.swift -o <binary>
```

## Feature 2: scroll direction and speed

### Wheel vs trackpad detection

Primary test: `scrollWheelEventIsContinuous != 0` means trackpad, pass the event through untouched.

Fallback test, exposed as a setting: treat the event as a trackpad event when either `scrollWheelEventMomentumPhase` or `scrollWheelEventScrollPhase` is non-zero. Some vendor drivers, Logitech's in particular, set the continuous flag on a physical wheel and defeat the primary test, and this machine does have a Logitech receiver (vendor 0x046d) attached, so the case is live rather than hypothetical.

The fallback is additive to the primary test, never a replacement for it. Dropping the continuous check in the alternate mode would rewrite active trackpad gestures, since a trackpad's `began` and `changed` events carry a scroll phase with a zero momentum phase and would be classified as wheel events. Trackpad pass-through is a non-negotiable, so the alternate mode widens what counts as a trackpad and never narrows it.

`scrollWheelEventScrollCount` is deliberately excluded, though the original draft included it. It has no documented semantics: `CGEventTypes.h` gives it only an `rdar://11259169` reference. If it is non-zero on this machine's real wheel events, including it classifies every wheel event as a trackpad event and silently turns the entire feature off.

**The alternate mode does not ship until the fields are measured.** Its whole premise is that a Logitech wheel sets the continuous flag, which is unverified here. Dump `isContinuous`, `scrollPhase`, `momentumPhase`, and `scrollCount` from both the real wheel and the trackpad in phase 2, record the four sets of values in this section, and only then decide the discriminator. If the wheel turns out to carry a scroll phase too, no field separates it from a trackpad gesture and the honest answer is to declare that hardware unsupported rather than to rewrite active trackpad input.

Never modify an event with a non-zero momentum phase.

### The delta fields, measured

A scroll event carries five per-axis delta families, not three:

| Field | Type | Notes |
| --- | --- | --- |
| `scrollWheelEventDeltaAxis{1,2}` | integer, lines | writing this one rewrites the point and fixed-point fields, see below |
| `scrollWheelEventPointDeltaAxis{1,2}` | integer, pixels | drives `NSEvent.scrollingDeltaY` for continuous events |
| `scrollWheelEventFixedPtDeltaAxis{1,2}` | double, 16.16 fixed point | drives `NSEvent.scrollingDeltaY` for non-continuous events |
| `scrollWheelEventAcceleratedDeltaAxis{1,2}` | integer | reads 0 on synthesized events, unmeasured on real hardware |
| `scrollWheelEventRawDeltaAxis{1,2}` | integer | reads 0 on synthesized events, unmeasured on real hardware |

**Writing the line delta is not a local edit.** `setIntegerValueField(.scrollWheelEventDeltaAxis1, value: n)` also overwrites that axis's point and fixed-point fields, discarding whatever was there: a fresh one-line event with point 10 and a fresh three-line event with point 30 both come out with point -8 after the line delta is set to -1. CoreGraphics derives the point delta as 8 pixels per line, not the 10 that folklore reports. Writing the point delta or the fixed-point delta alone changes nothing else.

Two consequences the implementation must carry:

- **Write the line delta first**, then the point delta, then the fixed-point delta. Writing them in any order that ends with the line delta silently discards the other two.
- **Do not treat 10 as the pixels-per-line constant.** The number the OS itself uses is 8, and it is only relevant where a field has to be synthesized from nothing.

### What UnnaturalScrollWheels actually does

The original premise for this rewrite, that UnnaturalScrollWheels writes only the line delta and therefore leaves `NSEvent.scrollingDeltaY` un-inverted, is false. Disassembly of the installed 1.2.3 binary confirms it calls `CGEventSetIntegerValueField` only on fields 11 and 12, and its symbol table has no `CGEventSetDoubleValueField` at all. But because the line-delta setter propagates, that single write already flips the fixed-point field, and `NSEvent.scrollingDeltaY` on a non-continuous event follows the fixed-point field. Direction is consistent across apps.

What its `DisableScrollAccel` path does do is normalize the line delta to the sign times `ScrollLines`, which forces the point delta to exactly 8 pixels per notch no matter how far the wheel turned. That, not an un-inverted field, is the most likely explanation for the inconsistent feel across applications, since a pixel-reading view gets a fixed 8 pixels while a line-reading view gets a whole line. This has not been confirmed against a live tap and is recorded as the working hypothesis, not as fact.

The rewrite pipeline below is still worth building, for the multiplier, for explicit control of all three visible representations, and because flattening in the pixel channel is the behavior actually wanted. It is no longer justified by a direction bug that does not exist. Scroll Reverser's `MouseTap.m` remains the reference for the field handling.

### Rewrite pipeline

The pipeline is a per-axis function returning a decision, never a return from the tap callback. The callback runs it for Axis1 (vertical) and Axis2 (horizontal), each with its own inversion setting, and only then decides what to do with the event. Axis 3 is ignored.

**Idle test and effective source.** An axis is idle only when its line, point, and fixed-point deltas are all zero. Testing the line delta alone misses sub-line movement: an event with line 0, point 5, and fixed-point 0.5 reads as `NSEvent.scrollingDeltaY` 0.5 and would pass through with its original direction, which is exactly the shape a high-resolution or free-spin wheel produces. So the pipeline never reads `orig` directly. It first resolves an effective source magnitude and sign, from the line delta where there is one and from the fixed-point delta otherwise, and everything downstream, including the scale factor's denominator, uses those. Nothing in the pipeline may call `orig.signum()` or divide by `orig`, both of which are wrong precisely in the case this paragraph exists to handle.

**Accumulator.** All accumulation is integer. The unit is 1/65536 of a line, which is the event's own 16.16 fixed-point resolution, so a fixed-point delta converts into it exactly and the smallest representable movement the hardware can report is still representable here. The multiplier is stored as an integer count of thousandths, so 0.6 is exactly 600; binary floating point cannot represent it, and five same-direction notches at 0.6 sum to 2.9999999999999996, which truncates to 2 lines instead of 3.

Two rules the arithmetic has to obey, both of which a natural-looking implementation breaks:

- **Residue lives in product units, not in lines.** Dividing the product down to lines before adding the residue throws away everything below one line, so a permitted combination of small input and small multiplier stays dead forever: 2000 inputs of half a line at multiplier 0.001 total one line, and a divide-first version emits nothing at all with an empty residue. Divide only when computing the emitted line count.
- **Residue is a pair per axis, one slot per direction**, so a reversal parks the outstanding fraction instead of destroying it. A single shared slot reset on reversal makes alternating scrolling below multiplier 1 emit nothing. Reset both slots on a configuration change and on a burst boundary, defined as an idle gap on that axis of roughly 250ms.

```swift
let fx = 65536                       // accumulator unit: 1/65536 line
// resolve the effective source: line delta, else fixed-point, else point at 8px/line
let source: (magnitude: Int, sign: Int)? =
    orig != 0        ? (min(abs(Int(orig)), maxLineDelta) * fx, orig > 0 ? 1 : -1) :
    origFixedPt != 0 ? (min(Int((abs(origFixedPt) * Double(fx)).rounded()), maxLineDelta * fx),
                        origFixedPt > 0 ? 1 : -1) :
    origPointDelta != 0 ? (min(abs(Int(origPointDelta)) * fx / 8, maxLineDelta * fx),
                           origPointDelta > 0 ? 1 : -1) : nil
guard let src = source, src.magnitude > 0 else { return .idle }

// residue: [Int] of length 2 per axis, [0] positive direction, [1] negative
let magnitude = flatten ? lines * fx : src.magnitude
let direction = src.sign * (invert ? -1 : 1)
let slot = direction > 0 ? 0 : 1
let want = direction * (magnitude * mulThousandths) + residue[slot]   // units: fx-thousandths
let unit = fx * 1000
let emitLines = want / unit          // Swift integer division truncates toward zero
residue[slot] = want - emitLines * unit
```

Note the guard: a magnitude that resolves to zero is the idle case, and it is the only thing standing between a sub-line event and a zero denominator in the field write below. Resolving the source through all three representations rather than the line delta alone is what makes it reachable.

Verified against every case that broke an earlier version of this pipeline: five notches at 0.6 emit `[0, -1, 0, -1, -1]` for exactly 3 lines; 20 notches emit exactly 12; 20 alternating notches emit 12 non-zero events where a floating-point accumulator emitted none; a fixed-point delta of 1/65536 resolves to magnitude 1 rather than 0, so its scale factor is 0.0 rather than NaN; a point-only event of 16 pixels emits 2 inverted lines; 2000 half-line inputs at multiplier 0.001 emit exactly 1 line; a fully idle axis returns idle; and a 50000-line delta at multiplier 100 clamps and emits 100000 without overflow.

**Field writes, in this order.** Under flatten, the point and fixed-point deltas are derived from `emit` rather than scaled from the originals. Scaling by `s = emit / orig` is what breaks flattening: `orig` is a rounded integer, so `s` carries its quantization error into the pixel channel, and under flatten the pixel channel then still tracks `orig` after the line channel has stopped doing so. Measured: at flatten 1 line and multiplier 1, a one-line notch with point 10 emits point -10 while a three-line flick with point 90 emits point -30, so a pixel-reading app still scrolls three times further on the fast flick, which is precisely the behavior flattening is meant to remove. The quantization half of this is independent of scroll acceleration: a 1.4-line notch (`orig` 1, point 14) and a 1.5-line notch (`orig` 2, point 15) emit point -14 and point -8, a 1.75x jump across a boundary the hand cannot feel.

Capture `orig`, `origPointDelta`, and `origFixedPt` before any setter runs. Reading them after the line-delta write returns the values that write synthesized, not the hardware's.

```swift
event.setIntegerValueField(deltaField, value: Int64(emitLines))   // must be first
if !flatten {
    // denominator is the effective source in signed lines, never orig, which
    // can be 0 while the axis is moving. The guard above makes it non-zero.
    let srcLines = Double(src.sign * src.magnitude) / Double(fx)
    let s = Double(emitLines) / srcLines
    let scaledPoint = origPointDelta == 0 ? Double(emitLines) * 8 : Double(origPointDelta) * s
    if let p = Int64(exactly: scaledPoint.rounded()) {
        event.setIntegerValueField(pointDeltaField, value: p)
    }
    if origFixedPt != 0 {
        event.setDoubleValueField(fixedPtDeltaField, value: origFixedPt * s)
    }
}
```

Both original-is-zero guards exist for the same reason: when a representation arrives empty, the value to write comes from `emitLines`, not from scaling nothing. The point delta needs an explicit `emitLines * 8` because nothing else supplies it, while the fixed-point delta needs only to be left alone, since the line-delta setter has already synthesized it correctly. Without the guard, a point-only event (line 0, point 16, fixed-point 0) comes out as line -2, point -16, fixed-point 0, because `origFixedPt * s` is zero times the scale factor and overwrites the -2.0 the line write had just produced.

**Under flatten there is nothing to write after the line delta.** The line-delta setter's own derivation is exactly `point = line * 8` and `fixedPt = Double(line)`, verified across line values from -5 to 20, which is the same result an explicit flatten write would produce. Writing the two fields again is harmless but redundant, so the flatten path is a single setter call. This is worth stating because it inverts the design's starting assumption: for the flattened case, the "write all three consistently" work is done by CoreGraphics, and the explicit writes are needed only where the emitted amount is not a whole number of lines.

Without flatten the scale factor is correct, since preserving the OS's own unit relationship is then the whole point. The zero-point-delta synthesis stays for that path, at 8 pixels per line rather than 10.

**Every conversion and every multiplication is bounded.** `Int64(someDouble)` traps on NaN and on infinity: `Int64(Double.nan)` terminates the process with exit 133. Integer multiplication traps on overflow just as hard: `Int64.max * 8` also exits 133. In the tap callback either one kills the app while the jail may hold the cursor disassociated, which is the frozen-cursor failure the design works hardest to avoid. Use `Int64(exactly:)` for conversions, clamp the incoming line delta to `maxLineDelta`, and rely on the settings bounds below for the rest. With lines per notch at most 1000, `maxLineDelta` 1000, and the multiplier at most 100 (`mulThousandths` at most 100000), the largest intermediate is `1000 * 65536 * 100000`, which is about 6.6e12 against an `Int64` ceiling of about 9.2e18. Verified at the bound: a 50000-line delta clamps to 1000 and emits 100000 at multiplier 100 without trapping.

**Swallowing.** Swallow only when the whole event carries nothing: every non-idle axis emitted zero, and the event carries no scroll-phase or momentum-phase metadata. Two constraints make this narrower than it looks:

- A per-axis zero must not swallow the event. A vertical axis emitting zero while the horizontal axis emits 1 would otherwise discard real movement.
- A non-continuous event can still carry a non-zero scroll phase, and swallowing it leaves a phase-tracking scroll view mid-gesture with a began that never ends. Never swallow a phase-bearing event: pass it through with coherent zero deltas instead.

### Defaults

Inverted vertical, natural horizontal, flatten on at 1 line, multiplier 1.0, primary detection method. These map one to one onto the live UnnaturalScrollWheels settings on this machine, with one deliberate difference: its `DisableScrollAccel` has no separate control here, because flattening to a fixed line count is what replaces it. Its binary carries exactly one HID key, `HIDMouseAcceleration`, so nothing is being dropped at the HID layer; the scroll-acceleration disable lives entirely in its event rewrite. Turning flatten off restores OS scroll acceleration on both the line and the pixel channels, and that is the intended meaning of the setting.

The switchover should be close to a no-op to the hand, but it is not measurably one: the pixel-channel behavior differs (8 pixels per notch before, `emit * 8` after, which is the same only at multiplier 1), so treat "feels identical" as something to verify rather than something the defaults guarantee.

## Feature 3: cursor jail

Behavior is unchanged. The code moves into `Jail.swift` and adopts `TapHost` for its tap lifecycle. Its enable state, target bundle id, and toggle hotkey move from `mousejail.lua` into settings and the menu.

Watch for one interaction: the jail warps the cursor and compensates for warp displacement folding into the next event's delta. Disabling pointer acceleration changes the magnitude of raw deltas but not that mechanism, so no change is expected. The compensation is unit-consistent by construction, since `pendingWarp` is built from `virtualPos` differences in cursor points and subtracted from `mouseEventDeltaX/Y`, which are also cursor points, so both sides rescale together. Verify anyway, since it is the one place the two features touch the same state and the argument has not been checked against a live acceleration change.

## Settings and UI

`MenuBarExtra` plus a `Settings` scene, SwiftUI. Verified to compile and link with `xcrun swiftc -O App.swift main.swift`, with `App.main()` called explicitly from `main.swift`. `MenuBarExtra` is macOS 13; opening the preferences window from the menu with `SettingsLink` raises the floor to macOS 14, and the pre-14 `NSApp.sendAction(Selector(("showSettingsWindow:")))` also compiles against a 13 target. On a 26.3 machine either works, so use `SettingsLink`. This is roughly 80 lines against roughly 200 for the equivalent programmatic AppKit, and it does not require a storyboard or an Xcode project.

Menu: jail on/off, invert scroll on/off, acceleration off on/off, Preferences, Quit.

Preferences: invert vertical, invert horizontal, flatten notches, lines per notch, multiplier, disable pointer acceleration, alternate trackpad detection, jail bundle id, jail hotkey, launch at login, hide menu bar icon.

Persistence in `UserDefaults`. Every setting takes effect immediately, with no restart.

Numeric settings are bounded at both ends, and the bound is enforced on the value loaded from `UserDefaults`, not only on the UI control: a plist edited by hand or left over from an older build reaches the tap callback unchecked otherwise.

| Setting | Bound | Why the upper bound exists |
| --- | --- | --- |
| Lines per notch | integer, 1 to 1000 | feeds the largest intermediate in the accumulator |
| Multiplier | 0.001 to 100, stored as `mulThousandths`, an integer 1 to 100000 | same, and it keeps the multiplier exactly representable |
| Incoming line delta | clamped to `maxLineDelta`, 1000 | it comes from outside the process and is not a setting |

Both bounds matter for behavior, not just for hygiene: zero for either setting swallows every scroll event with no error shown, a non-finite multiplier reaches an `Int64` conversion that terminates the process, and an unbounded product overflows into the same crash.

## Build and packaging

Keep the Makefile and `swiftc`. Assemble the `.app` bundle by hand: `Contents/MacOS/<binary>`, `Contents/Info.plist` with `LSUIElement` set, `Contents/Resources` for the icon.

`main.swift` checks `CommandLine.arguments` before starting the app, so `--release` still works by invoking the binary inside the bundle directly from a terminal. This requires the SwiftUI `App` struct to omit `@main` and be started explicitly with `App.main()`, since a module cannot have both `main.swift` and an `@main` type.

**Sign with a certificate, not ad hoc.** TCC keys the Accessibility grant to the code's designated requirement, and an ad-hoc signature's designated requirement is the code directory hash: `codesign -s - --force` on a hand-assembled bundle yields `designated => cdhash H"..."`, and changing a single line of Swift and re-signing yields a different hash. Every rebuild that changes the binary therefore drops Accessibility and every tap stops working, which no amount of care in the Makefile can prevent. For comparison, the installed UnnaturalScrollWheels has `designated => anchor apple generic and identifier "com.theron.UnnaturalScrollWheels" and certificate leaf ...`, which does not move when the binary does.

Create a self-signed code-signing certificate in the login keychain once (Keychain Access, Certificate Assistant, "Code Signing" type), then sign with `codesign -s "<cert name>" --force`. The designated requirement becomes bundle id plus certificate leaf and survives rebuilds. If that is not wanted, the spec must say plainly that Accessibility has to be removed and re-added in System Settings after every changed build, and the phase 3 estimate must carry that cost.

Drop `--deep`: it is deprecated for signing, and the bundle has no nested code for it to reach.

## Permissions and migration

Today the helper inherits Hammerspoon's Accessibility grant by running as its child. As a standalone app it needs its own grant, listed under its own name, which is an improvement.

Migration steps, in order:

1. Quit UnnaturalScrollWheels from its own menu, so its restore path writes `HIDMouseAcceleration` back to 196608, and confirm the property is no longer -1 before going further. Force-quitting or trashing it while running skips that restore and leaves the property at -1 with the original recoverable only from its `OriginalAccel` preference. Then uninstall: both processes writing the same HID acceleration property would fight.
2. Grant Accessibility to the new app.
3. Remove `require("mousejail")` from `~/.hammerspoon/init.lua` and delete `~/.hammerspoon/mousejail.lua` and `~/.hammerspoon/mousejail/`.

## Crash recovery

The failure mode that matters: the process dies while the jail has the cursor disassociated, leaving the cursor frozen system-wide. Acceleration and scroll settings have no equivalent risk, since a dead process just means the OS behaves normally again, and the acceleration property is restored on any clean exit and reset by a reboot.

Existing protections carry over: signal handlers via dispatch sources, `atexit`, and re-association at startup. Together they cover everything except `SIGKILL`.

**Re-association must be the first thing startup does**, before the Accessibility check, before any UI, before reading settings. Today `main.swift` checks `AXIsProcessTrusted()` and exits at line 199 before reaching the re-association at line 205. That ordering is harmless under Hammerspoon, whose grant the helper inherits, but fatal for a standalone app: after a rebuild drops the TCC grant (see Build and packaging), the relaunched process exits on the trust check and never thaws the cursor, which is exactly the case the recovery path exists for. `CGAssociateMouseAndMouseCursorPosition(1)` needs no permission, so nothing is lost by doing it first.

For `SIGKILL`, bundle a LaunchAgent plist in `Contents/Library/LaunchAgents/` and register it with `SMAppService.agent(plistName:)`. Three launchd constraints rule out the obvious shape:

- **`KeepAlive` implies `RunAtLoad`, and so does `SuccessfulExit`.** `launchd.plist(5)` states both. A registered KeepAlive agent therefore always launches at login, so crash recovery and launch at login cannot be independent settings on one job. Unregistering the job to honor a launch-at-login-off preference also removes crash recovery.
- **Unconditional `KeepAlive` breaks Quit**, relaunching the app the moment the user chooses it. `KeepAlive = { SuccessfulExit = false }` fixes that (Quit then exits 0 after restoring the cursor and the acceleration property) but does not fix the point above.
- **A Finder-launched instance is not the launchd job**, so after a Quit, a manually relaunched app is unmonitored and its `SIGKILL` recovers nothing.
- **launchd throttles respawns to roughly 10 seconds from job start.** A process killed after running a while relaunches promptly, so "within a second or so" holds for the normal case, but a crash loop in the first seconds after launch will not recover at that speed.

The design that survives all four is a **separate recovery job**, not the app itself: the same binary registered as a KeepAlive agent running with a `--watch` flag, which starts no UI, installs no tap, and does nothing but notice that no jailing instance is alive and call `CGAssociateMouseAndMouseCursorPosition(1)` once. It is then free to run at login always, it is unaffected by quitting the app, and it covers a Finder-launched instance as well as a login-launched one. This is the job the Hammerspoon supervisor does today, kept rather than dissolved into the app; launch at login for the app itself becomes an ordinary `SMAppService.mainApp` login item, independent of it.

The alternative, folding recovery into the app and accepting that recovery requires launch at login, is acceptable only if the preferences window says so plainly on the same line as the setting. Pick one before phase 3 rather than discovering the coupling during it.

Whichever is chosen, test the four scenarios that distinguish them: `SIGKILL` while the jail holds the cursor, `SIGKILL` after a Finder launch, deliberate Quit, and launch at login turned off. Registration can also fail (consent, signing, placement), so handle the error rather than assuming the agent is live.

The jail hotkey moves in-app via Carbon `RegisterEventHotKey`, which needs no additional permission.

## Phasing

Ordered so the non-negotiables ship before the packaging work, which is the long pole.

| Phase | Content | Estimate |
| --- | --- | --- |
| 0 | Split `main.swift` into modules, extract `TapHost`, add the scroll-field test harness. No behavior change, still CLI under Hammerspoon, binary still named `mousejail`. | 1h |
| 1 | Pointer acceleration, behind a CLI flag. | 1h |
| 2 | Scroll filter, behind CLI flags. Both non-negotiables now working. | 2-4h |
| 3 | App bundle, menu bar, preferences, login item, hotkey. Rename the binary and repo. Retire the Hammerspoon lua. | 3-4h |

**The rename moved to phase 3.** Phases 0 through 2 still run under the Hammerspoon supervisor, and `hammerspoon/mousejail.lua` hardcodes the helper as `hs.configdir .. "/mousejail/mousejail"` and kills orphans with the anchored pattern `^<HELPER>( |$)`, while the Makefile `install` target hardcodes `$(HS_DIR)/mousejail/mousejail` and `$(HS_DIR)/mousejail.lua`. Renaming in phase 0 leaves the supervisor launching a path that no longer exists, so phase 0 would not leave a working program. Phase 3 retires the lua anyway, which is where the rename costs nothing.

Estimates are agent-loop hours including test cycles, not human coding time. Phase 2 dominates because the delta-field work needs hands-on verification across applications rather than reasoning. Phase 3 grew to absorb the rename and the signing-identity setup.

## Testing

The rewrite pipeline is a pure function and gets a real test harness. Only the OS integration is manual.

**Harness, built in phase 0.** A `swiftc`-runnable table-driven test over the pipeline function, asserting exact output triples (line, point, fixed-point) for given inputs. Every defect found while reviewing this spec was found by running exactly this and none of them would have been caught by the manual matrix, so the harness is the cheaper half of the testing by a wide margin. Cases it must cover:

| Case | Asserts |
| --- | --- |
| Slow notch versus fast flick under flatten | identical output in all three channels, not just the line channel |
| Cumulative output at multiplier 0.3, 0.6, and 1.5 over 20 notches | exact line totals, no floating-point under-emission |
| Alternating direction at multiplier 0.6 | scrolling still happens, which the same-direction case cannot show |
| Both axes non-idle, one emitting zero | the other axis's movement survives |
| Line delta 0 with non-zero point and fixed-point deltas | inverted, not passed through |
| A fixed-point delta of 1/65536 | a non-zero source magnitude, a finite scale factor, never NaN |
| A point-only event, line and fixed-point both 0, point 16, inverted | the full output triple: line -2, point -16, fixed-point -2.0, all three agreeing on two inverted lines |
| 2000 half-line inputs at the lowest permitted multiplier | exactly one line emitted, not zero |
| Non-continuous event carrying a scroll phase | never swallowed |
| Field write order | the point and fixed-point values written survive the line-delta write |
| Residue across a 250ms idle gap, and across a settings change | both direction slots reset, no leftover fraction entering a later gesture |
| Invalid settings: multiplier 0, NaN, infinity, lines 0, lines and multiplier at their upper bounds | rejected at load, no trap, no overflow, no silent dead scrolling |

**Instrumentation.** A `--dump-scroll` mode logging all five delta families before and after the rewrite. Without it the manual matrix below is unfalsifiable by eye, since nothing visible distinguishes the line channel from the pixel channel.

**Manual matrix**, run at the end of phases 1 and 2, for OS integration only.

Applications, chosen because they read different delta fields: Safari, Xcode or another native `NSScrollView`, a terminal, VS Code or another Electron app, Preview.

Per application, with the wheel: direction correct, speed matches the configured lines and multiplier, no stalls or dead zones at a fractional multiplier such as 0.6 or 1.5, fast flicks travel proportionally to slow ones (which is what flattening buys), judged from the `--dump-scroll` output rather than by feel.

Per application, with the trackpad: direction, speed, and momentum all identical to the app not running. This is the regression that matters most, since the whole point is leaving the trackpad alone.

Acceleration: move the mouse the same physical distance slowly and quickly, confirm the cursor lands in the same place. Confirm the setting survives sleep and wake. Confirm the original value is restored on quit rather than left at -1.

Jail: existing behavior in League windowed mode, plus a check that acceleration being off has not changed the warp compensation.

## Risks

**TCC grant lost on rebuild.** Any change to the designated requirement drops Accessibility and every feature silently stops. Ad-hoc signing cannot mitigate this, since its designated requirement is the code directory hash and every changed build produces a new one. Mitigation: a certificate-backed signing identity (see Build and packaging), plus a startup check on `AXIsProcessTrusted()` that surfaces an alert rather than exiting quietly, after the cursor has been re-associated.

**Acceleration property fights another process.** UnnaturalScrollWheels, Logitech Options, or the System Settings toggle all write the same knob. Last writer wins. Mitigation: the 5s reassert timer, and uninstalling the competitors.

**Original acceleration value lost.** Covered by the -1 guard plus the 196608 bootstrap fallback. The value on this machine is **196608**, which is 3.0 in 16.16 fixed point and matches `com.apple.mouse.scaling = 3`. Recorded here so it can be restored by hand if both are ever defeated.

**Both taps disabled together.** Under sustained load or on wake, macOS disables taps. `TapHost` must handle re-enable for each tap independently, and the wake path must poke both.

**Swallowed scroll events.** Returning nil for a zero-emit event is correct but means a low multiplier can make scrolling feel dead. The residue accumulator prevents this only for sustained motion in one direction; a single residue reset on every reversal makes alternating scrolling at any multiplier below 1 emit nothing at all, forever, which is why residue is a per-direction pair. Verify at multiplier 0.3 that scrolling still moves both in a sustained direction and while alternating. The same-direction check alone passes with the bug present.

## Open

**Name.** The repo is `mousejail`, which no longer describes the scope. Default proposal `mousetamer`, alternatives `mouseworks` or `micetrap`. The rename is mechanical and GitHub redirects the old URL, so this blocks nothing; it lands in phase 3 with the Hammerspoon retirement.

**Accelerated and raw delta fields.** `scrollWheelEventAcceleratedDeltaAxis{1,2}` and `scrollWheelEventRawDeltaAxis{1,2}` exist and both read 0 on synthesized events. Whether the HID stream populates them on real wheel events, and whether any application reads them, is unmeasured. Check with `--dump-scroll` in phase 2; if they carry values, the rewrite has to decide about them, since leaving them at their originals is the same class of inconsistency this design set out to remove.

**The actual UnnaturalScrollWheels defect.** The forced 8 pixels per notch is the working hypothesis for the inconsistent feel, not a measured cause. Confirming it needs a tap comparing all three field families with the app running and stopped. Worth doing before phase 2, since it is the only remaining evidence that the pixel-channel behavior is what the user is actually reacting to.
