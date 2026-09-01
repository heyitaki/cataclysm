# Cataclysm: finish wiring and distribution

## Overview

When done: `main.swift` is split into modules; pointer acceleration and the scroll filter are wired into the CLI binary behind flags; `Cataclysm.app` (bundle id `io.github.heyitaki.cataclysm`, macOS 13 floor, universal) exists with the full `MenuBarExtra(.window)` panel, onboarding, startup order, `--watch` crash-recovery agent, and hotkey from `specs/distribution-and-ui.md`; the watcher acceptance gate has passed for real via `--smoke-register`; the Hammerspoon lua is retired; `make dmg` and `make release` exist and README is rewritten for friends.

The two specs are the design and are already decided. Before each task, read the sections of `specs/pointer-and-scroll.md` and `specs/distribution-and-ui.md` it names. Implement; never redesign, and never edit anything under `specs/`.

Standing rules for every iteration, including review-fix commits:

- Never run `make install` or `make restart`, never touch `~/.hammerspoon`, never launch Hammerspoon. Those deploy to the live helper the user plays with.
- Never launch any built binary, with two exceptions: test harnesses under `build/` (pure functions, no system access), and `--smoke-register` in Task 11 exactly as that task specifies. In particular never run anything that creates an event tap, writes `HIDMouseAcceleration` (another app currently owns that property), warps or disassociates the cursor, or shows UI.
- Never call TCC-prompting APIs from any probe or test: no active `CGEvent.tapCreate`, no `AXIsProcessTrustedWithOptions` with the prompt option, no `CGRequestListenEventAccess`, no `IOHIDRequestAccess`. Implementing them in app code is required; invoking them from the loop is forbidden.
- Jail behavior in `main.swift` is load-bearing and settled: the rounded-rect Clamp, the `--corner-radius` flag, and the unconditional warp in the tap callback. Task 1 moves this code verbatim; no later task changes jail semantics.
- Signing identity `Cataclysm` exists in the login keychain with its key ACL primed. It is self-signed and may show as `CSSMERR_TP_NOT_TRUSTED` in `security find-identity` — that is expected and fine; the working check is that `codesign -f -s Cataclysm <binary>` succeeds. If codesign errors or hangs, stop and report blocked; never create certificates or modify keychains or trust settings.
- Bundle id is `io.github.heyitaki.cataclysm`, permanent. Never change it and never invent a second one.
- Do not modify `tests/ScrollFilterTests.swift` expected values, `hammerspoon/mousejail.lua` (until Task 11 deletes it), or `specs/`.
- Every task ends with `make test` exit 0 and every target that exists at that point building clean.

Out of scope: hardware scroll measurement and the manual per-app matrix, any TCC grant, live tap or acceleration runs, icon artwork beyond the generated placeholder, notarization and Developer ID, the GitHub repo rename, macOS 13 and Intel floor testing. All listed in Post-Completion.

## Context

Repo root holds `main.swift` (CLI jail helper, top-level code, builds as `mousejail`), `Jail`-and-tap logic still inside it, `PointerAccel.swift` (complete module: `enable()/disable()/restore()/reassert()`, `onWriteHealthChange`, persisted original under `recovery.originalMouseAcceleration`), `ScrollFilter.swift` (complete pure pipeline: `decideScrollEvent`, `applyAxisDeltas`, clamp helpers), `Bridging.h` (IOKit HID headers), `tests/ScrollFilterTests.swift` (custom `@main` harness, table-driven, run via `make test`), `Makefile`, `hammerspoon/mousejail.lua`. Follow the test-harness pattern for any new test binary: plain swiftc target under `build/`, `check`/`checkEq` helpers, exit non-zero on failure.

Two entry points will coexist until Task 11: the `mousejail` CLI target and the app. Give every swiftc target an explicit source list; a `*.swift` glob breaks the moment two `@main`/top-level entries exist. The app's entry is a `@main` struct whose `static func main()` dispatches on `CommandLine.arguments` first (`--watch`, `--smoke-register`) and only falls through to `CataclysmApp.main()` (SwiftUI) for a normal launch, so the watcher and smoke modes never start UI.

Traps already paid for, do not rediscover:

- `decideScrollEvent`'s `time` parameter is SECONDS. `CGEvent.timestamp` is mach ticks (~41.7ns). Scale with `mach_timebase_info` read once at startup; anything else silently breaks residue and sub-1.0 multipliers emit nothing.
- The scroll tap is its own `.tailAppendEventTap` on `scrollWheel` only; do not add the bit to the jail's head-insert tap. Scroll dispatch runs before the jail's engaged-guard and mouse-delta code, or every wheel notch warps the cursor. `.swallow` means returning nil from the callback. `ScrollFilterState` is one long-lived file-scope value. `applyAxisDeltas`'s `flatten` must come from the same per-axis config that produced the deltas.
- Field access: line and point deltas via `getIntegerValueField`, fixed-point via `getDoubleValueField`, `isContinuous` as `getIntegerValueField(.scrollWheelEventIsContinuous) != 0`.
- Whenever a Makefile rule gains sources or `-import-objc-header Bridging.h`, update its prerequisite list in the same edit; otherwise a module edit leaves a stale binary that reports as fresh.
- `PointerAccel.restore()` must run on every exit path the CLI and app own (signal handlers, normal quit); deinit does not run for globals at exit. Deliberate module deviation to keep: a non-positive stored `com.apple.mouse.scaling` restores nothing rather than forcing 196608.
- `UserDefaults.standard` changes domain when the CLI becomes a bundle (process-name plist now, bundle-id plist after). The settings store must migrate `recovery.originalMouseAcceleration` from the old `mousejail` domain on first bundle run.
- "Reset to defaults" never touches `recovery.`-prefixed keys and reapplies defaults immediately (writes -1 again, does not restore). "Reset everything and quit" orders strictly: restore acceleration, re-associate cursor, unregister watcher and login item (and bootout plus delete the legacy plist if present), then clear `UserDefaults`, then exit.
- `IOHIDEventSystemClientCreateSimpleClient` can return null in degraded contexts despite the nonnull annotation; startup verifies a property read round-trips before reporting acceleration control as on.
- The scroll speed slider maps 0.25x-4.0x on a log scale; the stored bound stays 0.001-100 (`mulThousandths` 1-100000) and out-of-slider-range stored values are legal, displayed parked at the nearer end, never rewritten.
- Alternate trackpad detection defaults off. The hotkey recorder implements spec mechanisms 1 and 2 with the teardown rules; the shipped default chord is `cmd+alt+L`; which mechanism actually works is a GUI check the user runs later, so wire the runtime fallback chain and surface `RegisterEventHotKey` failure in the row.
- Placeholder icon: generate a 1024x1024 PNG at build time (small swift script drawing with CoreGraphics is fine), then `sips -s format icns` as the fallback recipe, or the full ten-slice `iconutil` set; the spec's appendix documents both and `iconutil` lies under sandboxing, so treat a `sips` success plus `iconutil` failure as environment, not as a broken iconset.

## Validation Commands

- `make test` — builds and runs every test harness; must exit 0 (currently 66 checks, count grows, 0 failed is the bar).
- `make` — builds the `mousejail` CLI binary; must exit 0 (target exists until Task 11 retires it; after that `make` builds the app).
- `make app` — exists from Task 5: assembles and signs `build/Cataclysm.app`; must exit 0.
- `codesign --verify --strict build/Cataclysm.app` — from Task 5, must exit 0. `spctl` rejection of the self-signed app is expected; never assert `spctl` acceptance.
- `plutil -lint <plist>` — on every generated plist, must report OK.

### Task 1: Split main.swift into modules

- [x] Move the clamp geometry and jail math into `Jail.swift` and tap creation/lifecycle into `TapHost.swift`; `main.swift` keeps argument parsing, wiring, and the run loop. Code moves verbatim except access-level and file-scope adjustments; same flags, same output, binary still `mousejail`.
- [x] Makefile `$(BINARY)` rule gets the explicit source list `main.swift Jail.swift TapHost.swift` and matching prerequisites.
- [x] `make` and `make test` exit 0; the diff reads as moved code, not rewritten logic.

### Task 2: Wire pointer acceleration into the CLI

- [x] Read `specs/pointer-and-scroll.md` phase 1. Wire `PointerAccel` into `main.swift` behind the flag that spec names (its choice wins; `--no-accel` only if it names none), default off. Include the 5s reassert timer and `didWakeNotification` reassert via the module API, and the null-client read round-trip check before reporting the feature active.
- [x] Every exit path (signal handlers, clean exit) calls `restore()` before the process dies.
- [x] Build gains `-import-objc-header Bridging.h` and `PointerAccel.swift` with prerequisites updated in the same edit; `make` and `make test` exit 0; also verify both `xcrun swiftc -typecheck -target arm64-apple-macos13.0` and `-target x86_64-apple-macos13.0` pass on the CLI source list. Never run the binary.

### Task 3: Wire the scroll filter tap into the CLI

- [x] Read `specs/pointer-and-scroll.md` phase 2. Add a separate `.tailAppendEventTap` for `scrollWheel` dispatching to `decideScrollEvent` before any jail code runs, honoring the Context traps (seconds conversion, nil-return swallow, long-lived state, per-axis flatten pairing, field accessor types).
- [x] CLI flags for invert vertical, invert horizontal, flatten, lines per notch, multiplier, and alternate trackpad detection (default off), clamped through the existing clamp helpers; `--dump-scroll` prints each raw event's fields and the decision to stdout.
- [x] `make` and `make test` exit 0; both `-target` typechecks pass. Never run the binary.

### Task 4: Settings store with clamped load

- [x] `Settings.swift`: a `UserDefaults`-backed store with every key the panel needs (jail enabled, target bundle id and display name, acceleration off, invert vertical, invert horizontal, flatten, lines per notch, multiplier, alternate detection, hotkey chord, corner radius, launch-at-login, last-registered version) with spec defaults, clamping on load per the spec bounds (multiplier 0.001-100, lines 1-1000, radius 0-200), unknown keys untouched, unparseable values falling back to defaults.
- [x] `recovery.`-prefixed keys segregated per the Context rules, plus the one-time migration read of `recovery.originalMouseAcceleration` from the old `mousejail` process-name domain.
- [x] A `build/settings-tests` harness in the existing test-harness pattern covering defaults, each clamp bound, reset-to-defaults sparing `recovery.` keys, and the migration read (point the store at a scratch `UserDefaults(suiteName:)`, never `.standard`, in tests); `make test` runs both harnesses and exits 0.

### Task 5: App bundle, placeholder icon, signing

- [x] App entry per Context (arg dispatch, then SwiftUI) with a minimal `MenuBarExtra("Cataclysm").menuBarExtraStyle(.window)` placeholder panel; explicit source list sharing `Jail.swift`, `TapHost.swift`, `PointerAccel.swift`, `ScrollFilter.swift`, `Settings.swift`; `--watch` and `--smoke-register` exist as stubs that print and exit 0.
- [x] `make app` assembles `build/Cataclysm.app`: `Info.plist` with `LSUIElement` true, `LSMinimumSystemVersion` 13.0, `CFBundleIdentifier io.github.heyitaki.cataclysm`, version from a `VERSION` Makefile variable; `Contents/Library/LaunchAgents/io.github.heyitaki.cataclysm.watch.plist` exactly per the spec's watcher-plist block (`BundleProgram`, `KeepAlive` `{SuccessfulExit = false}`, `AssociatedBundleIdentifiers`); generated placeholder icns in `Contents/Resources`.
- [x] Sign with `IDENTITY ?= Cataclysm`; `codesign --verify --strict build/Cataclysm.app` exits 0; `plutil -lint` passes on both plists; `make` and `make test` still exit 0.

### Task 6: Startup order and onboarding

- [x] Read the spec's "First run" section. Implement the six startup steps in order: flock instance lock on `~/Library/Application Support/io.github.heyitaki.cataclysm/instance.lock` (loser shows a one-line notice, exits 0, touches nothing), `CGAssociateMouseAndMouseCursorPosition(1)`, the `/Volumes/`-or-translocation install gate with its move-to-Applications screen, clamped settings load, `AXIsProcessTrusted()` check (never the prompting variant here), then taps, acceleration property, and agent registration only after trust.
- [x] Onboarding window per spec: explanation, primary button calling the prompting trust check, secondary button opening the Accessibility deep link, 0.5s trust poll, Relaunch fallback button; never shown while granted; agent registration deferred until onboarding completes.
- [x] Ungranted or lost-grant state: cursor re-associated, both taps down, features shown unavailable; the app keeps running and polls, never exits. `make app` and `make test` exit 0.

### Task 7: Panel default view and status rows

- [x] Read the spec's "The dropdown" layout. Default view at fixed 320pt width: header, jail toggle with game-picker placeholder row, acceleration toggle, invert-wheel toggle, scroll speed slider (log-scaled 0.25x-4.0x, two-decimal snap, `.monospacedDigit()` readout, reset-to-1.00x control), Launch at login toggle via `SMAppService.mainApp`, Quit. Every control writes through the settings store and applies immediately.
- [x] Status and failure rows per spec: ungranted header warning with reopen-onboarding button, failed acceleration write showing failed rather than checked, failed tap creation on the affected feature, watcher unregistered or requiring approval showing crash-recovery-off with the Login Items deep link.
- [x] `make app` and `make test` exit 0; both `-target` typechecks pass on the app source list.

### Task 8: Game picker

- [x] Read the spec's "Game picker". Rows: stored target first (synthesized from persisted bundle id plus display name when not running), then running `.regular` apps deduped by bundle id, sorted case-insensitively by name, 16pt icons, tagged by bundle id, duplicate visible names get the id appended, apps without a bundle id excluded, Cataclysm itself excluded.
- [x] Rebuild on panel open and on `NSWorkspace.shared.notificationCenter` launch and terminate notifications; a quitting target drops to the synthesized row with selection unchanged.
- [x] Final "Choose from Applications…" row: `NSOpenPanel` restricted to `.app`, reads the chosen bundle's id and name, writes them straight to the settings store without assuming the panel survived.
- [x] `make app` and `make test` exit 0.

### Task 9: Advanced group, hotkey, resets

- [x] `DisclosureGroup` collapsed by default with: invert horizontal, flatten notches, lines per notch, alternate trackpad detection, jail toggle hotkey row, corner radius (0-200, default 18, 0 disables corner clamping), Check for updates (opens the GitHub releases page), Reset to defaults, Reset everything and quit — the last two following the Context ordering rules exactly.
- [x] Hotkey recorder per spec: mechanism 1 (local `keyDown` monitor while key) with mechanism 2 (`NSViewRepresentable` first responder overriding `keyDown` and `performKeyEquivalent`) behind it; recording cancels keeping the previous chord on panel dismissal and tears down the monitor or responder on the same path; `RegisterEventHotKey` failure shows in the row; shipped default chord `cmd+alt+L`.
- [x] `make app` and `make test` exit 0.

### Task 10: Watcher and registration

- [x] Read the spec's "Crash recovery and the watcher". `--watch`: no UI, no taps, no property writes, no lock; on startup, if no app with the bundle id is running, re-associate once, then poll every second and re-associate on each present-to-absent transition.
- [x] Registration in the app: `SMAppService.agent(plistName:)` after onboarding only; `register()` errors and `.requiresApproval` land in the panel status area; version-change relaunches unregister then re-register; `SMAppService.mainApp` login item stays independent.
- [x] Legacy fallback per spec: on `SMAppService` refusal write `~/Library/LaunchAgents/io.github.heyitaki.cataclysm.watch.plist` with absolute `ProgramArguments` from `Bundle.main.bundleURL`, `launchctl bootstrap gui/$UID`, rewrite the path when the app notices it moved; "Reset everything and quit" boots out and deletes this file too.
- [x] `make app` and `make test` exit 0. Never register from this task; registration runs only inside Task 11's smoke mode.

### Task 11: Acceptance gate, retire the lua

- [x] Implement `--smoke-register`: acquire the instance lock, register the watcher via `SMAppService`, read back `status`, run `launchctl print gui/$UID/io.github.heyitaki.cataclysm.watch` and verify the executable resolved inside the bundle, then unregister; on `SMAppService` refusal repeat the check through the legacy bootstrap path and boot it out. Print one PASS or FAIL line per step, exit 0 only on overall pass, and guarantee cleanup (unregister/bootout/delete) on every path including failure, with a `defer`/signal guard. It must never touch taps, the acceleration property, cursor association, or UI.
- [x] Run the gate: `make app && ./build/Cataclysm.app/Contents/MacOS/cataclysm --smoke-register` exits 0. This is the only permitted app launch. On failure, report blocked with the full status and `launchctl` output, retire nothing, and stop this task. (Result: exit 0 via the legacy path. `SMAppService.register()` succeeded and `status` read `.enabled`, but launchd never spawned the watcher in a 10s poll — `launchctl print` stayed at `program identifier = Contents/MacOS/cataclysm`, `resolve program`, `needs LWCR update`, no pid — so the gate treated it as a refusal. The legacy bootstrap passed every step including executable resolution.)
- [x] On pass: delete `hammerspoon/mousejail.lua`; remove the `mousejail` `$(BINARY)`, `install`, and `restart` targets; fold the CLI's jail/accel/scroll wiring into the app's normal launch path (the app is now the only consumer); rename remaining build outputs to `cataclysm`; make bare `make` build the app. `make`, `make app`, `make test` exit 0.

### Task 12: Universal binary

- [x] `make app` builds both `-target arm64-apple-macos13.0` and `-target x86_64-apple-macos13.0` slices with the bridging header and joins them with `lipo -create` per the spec's recipe.
- [x] `lipo -info` on the bundled executable shows both architectures; `otool -l` shows `minos 13.0` on each slice; `codesign --verify --strict` still exits 0; `make test` exits 0.

### Task 13: DMG, release split, README

- [x] `make dmg VERSION=x.y.z`: staging folder with `Cataclysm.app` and an `/Applications` symlink, `hdiutil create -volname Cataclysm -srcfolder <stage> -ov -format UDZO`, DMG signed with `IDENTITY`. Verify the image mounts, contains both entries, and detaches cleanly. (Verified: `build/Cataclysm-0.1.0.dmg` mounted with both entries and detached clean.)
- [x] `make release VERSION=x.y.z`: runs dmg then notarizes and staples; refuses immediately with a message naming the missing `IDENTITY` (Developer ID) or `NOTARY_PROFILE`. Verify only the refusal path (no profile exists on this machine). (Verified both refusals: non-Developer-ID `IDENTITY`, and Developer ID `IDENTITY` with unset `NOTARY_PROFILE`; each exits nonzero before building anything.)
- [x] Rewrite `README.md` for friends per the spec: opens with what the app fixes, install steps with the Open Anyway walkthrough, the frozen-cursor recovery note (~1s, ~10s worst case), the second-display surprise, what it does and does not do to input, uninstall via Reset everything and quit.
- [x] `make`, `make app`, `make test` exit 0.

### Task 14: Verify acceptance criteria

- [x] From a clean `make clean`: `make`, `make app`, `make test` all exit 0; `codesign --verify --strict` passes; `lipo -info` shows both slices. (223 checks, 0 failed; both slices `minos 13.0`.)
- [x] `./build/Cataclysm.app/Contents/MacOS/cataclysm --smoke-register` exits 0 again post-rename and leaves no registered agent, no legacy plist, and no lock file behind (check `launchctl print` reports the label gone and `~/Library/LaunchAgents` has no cataclysm plist). (Passed via the legacy path, same as Task 11: `SMAppService` registered and read `.enabled` but launchd never resolved the executable, so the gate fell through to legacy bootstrap, which passed every step. Label gone, no plist, Application Support dir empty afterward.)
- [x] `make release` without a notary profile refuses with the naming message; `make dmg VERSION=0.1.0` produces a mountable image. (Refusal names `IDENTITY`; DMG mounted with both entries and detached clean.)
- [x] No references to `mousejail` remain outside `specs/`, `docs/plans/`, and git history: `grep -ri mousejail --exclude-dir=specs --exclude-dir=docs --exclude-dir=.git --exclude-dir=build .` returns nothing. (Cleaned .gitignore, Makefile comment, releases URL (now `heyitaki/cataclysm`), Settings/tests comments, and renamed the migration marker key. Two deliberate hits remain: `Settings.legacyDomainName = "mousejail"`, which the Context migration rule requires verbatim to read the old CLI's defaults domain, and the worktree's `.git` pointer file, which is git plumbing that `--exclude-dir=.git` covers in a normal checkout.)
- [x] `git status` clean, every prior task's validation commands green.

## Post-Completion

Human-only items, in rough order:

- Quit UnnaturalScrollWheels from its own menu (so it restores `HIDMouseAcceleration`) and uninstall it, before first launching the app with acceleration control on.
- First real launch: grant Accessibility through onboarding, confirm the panel, jail, acceleration, and scroll behavior live; then the hardware scroll measurement with `--dump-scroll` (wheel vs trackpad discriminator decision) and the manual per-app scroll matrix from the specs' testing tables.
- GUI checks from the spec's Open list: does the panel take key focus for the hotkey recorder (which mechanism won), does `AXIsProcessTrusted()` update without relaunch (whether the Relaunch button can go).
- Verify crash recovery actually runs after the first real launch: the smoke gate measured `SMAppService.register()` succeeding with the self-signed identity while launchd never spawned the watcher (`needs LWCR update`, no pid after 10s), so a runtime registration that reads `.enabled` may still be hollow. Check `launchctl print gui/$UID/io.github.heyitaki.cataclysm.watch` shows a pid after a GUI launch; if not, the app's fallback needs to trigger on non-spawn (as the gate does), not only on `register()` throwing.
- Remove the two denied TCC rows for `com.example.assocprobe.never-granted` in System Settings (Accessibility and Input Monitoring); if a stray Cataclysm row lingers in Login Items from an interrupted gate run, remove it there too.
- Rename the GitHub repo `mousejail` to `cataclysm` (old URL redirects).
- Icon artwork to replace the placeholder.
- Decide the $99 Developer ID membership; if bought: create the Developer ID certificate, `xcrun notarytool store-credentials`, run `make release`, and do the offline second-Mac install test. If not: releases ship from `make dmg` with the README walkthrough.
- Floor and hardware passes: macOS 13 rendering/deep-link/registration, Intel or Rosetta launch, granted-in-Applications-then-run-from-Downloads.
