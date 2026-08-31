# Cataclysm: menu bar UI and distribution

Spec for turning the tool into something a friend installs from a DMG and never configures. Status: reviewed round by round against a second model, ready to implement.

Companion to `pointer-and-scroll.md`, which owns the three pointer behaviors and their implementation. This document supersedes that spec's "Settings and UI" and "Build and packaging" sections, and splits its phase 3. Everything else in that document still stands, including "Crash recovery", whose separate recovery job this document adopts and details.

## Goal

A League player on macOS downloads one DMG, drags the app to Applications, opens it, grants one permission, and is done. On a stock macOS install none of it works correctly out of the box: the cursor leaves the window, the mouse accelerates, the wheel scrolls the wrong way. The app fixes all of it with defaults, and everything adjustable lives in the menu bar dropdown.

## What changes from `pointer-and-scroll.md`

| Decision there | Decision here | Why |
| --- | --- | --- |
| `MenuBarExtra` plus a `Settings` scene | One `MenuBarExtra` panel, no preferences window | Every setting must be reachable in the dropdown |
| Default `.menu` style implied | `.menuBarExtraStyle(.window)` required | The scroll speed slider does not render in `.menu` style, measured below |
| `SettingsLink` raises the floor to macOS 14 | Floor stays at macOS 13 | With no `Settings` scene there is nothing to link to |
| Self-signed certificate | Self-signed in 3a. In 3b, Developer ID plus notarization if the membership is bought, otherwise the same local signature plus a README step | A self-signed signature is not notarized, so a friend's first launch is a malware warning. Both give a designated requirement stable across rebuilds, which is what 3a needs |
| Jail bundle id as a preferences text field | Jail target is a picker over running apps | Friends do not know what a bundle id is |
| Preferences item "hide menu bar icon" | Dropped | The panel is the app's only surface, so hiding the icon makes every setting unreachable |
| Name open, `mousetamer` proposed | `Cataclysm`, decided | See "Naming". That open item in the companion is retired |
| Multiplier bound 0.001 to 100 | Same stored bound, slider exposes 0.25x to 4.0x | The stored bound is the safety bound and stays; the slider is the useful range |
| Crash recovery job undecided between two shapes | The separate `--watch` job, which that document already recommends | See "Crash recovery and the watcher" |
| The jail toggle hotkey moves into settings and the menu | Same, unless a `MenuBarExtra(.window)` panel cannot become key, in which case the chord ships fixed at `cmd+alt+L` | A hotkey recorder needs key focus the panel may not give. Conditional on the check in "Open"; the recorder is tried two ways first |
| Re-association is the absolute first startup operation | One operation precedes it: the duplicate-instance check | Re-association exists to thaw a cursor a dead instance left frozen. When a live instance is already jailing, there is nothing to thaw and thawing would break it. See "Startup order" |
| Audience is this machine | Audience is other people's machines | Intel hardware, older macOS, no failure path may end in stderr |

## The dropdown

### Style, measured

`MenuBarExtra { ... }.menuBarExtraStyle(.window)` renders `Toggle`, `Picker`, `Slider`, `Divider`, and `Button` together in one panel. Built and run on macOS 26.3 with Swift 6.3.3, `xcrun swiftc -O App.swift -o uitest`, no bundle, no Xcode project.

The same source with `.menuBarExtraStyle(.menu)` renders an `NSMenu` and the slider is gone: the `HStack` holding it breaks into three separate menu items, the "Scroll speed" label and the "1.00x" readout come out dimmed and disabled, and the slider itself becomes an empty row with a submenu arrow. The `Picker` fares better and becomes a working submenu, and the toggles become checkmarked items.

So `.window` is a requirement, not a preference. The cost is that the panel is an `NSPanel`, not a real menu: no keyboard menu navigation, no type-select, and it dismisses on any outside click. That dismissal is load-bearing for three decisions below (no live scroll preview, the hotkey recorder, the "Choose from Applications…" row), so it is stated once here and referred to rather than rediscovered.

The measurement is on macOS 26.3 only. `MenuBarExtra` behaves differently enough across 13 through 26 that the panel itself is one of the things the floor test has to look at, not just the install flow.

### Layout

```
┌──────────────────────────────────────┐
│  Cataclysm                           │
│  Accessibility granted               │
├──────────────────────────────────────┤
│  [✓] Lock cursor to game window      │
│      Game  [ 🎮 League of Legends ▾] │
├──────────────────────────────────────┤
│  [✓] Mouse acceleration off          │
│  [✓] Invert wheel scrolling          │
│      Scroll speed ──●──────  1.00x ↺ │
├──────────────────────────────────────┤
│  ▸ Advanced                          │
├──────────────────────────────────────┤
│  [✓] Launch at login                 │
│  Quit                                │
└──────────────────────────────────────┘
```

Four settings in the default view (jail on, acceleration off, invert wheel, scroll speed) plus the game picker, which is the whole point. Width fixed at 320 points so the panel never reflows as values change.

`Advanced` is a `DisclosureGroup` in the same panel, collapsed by default, holding the knobs a player has no reason to touch: invert horizontal, flatten notches, lines per notch, alternate trackpad detection (if phase 2's measurement kept it), jail toggle hotkey, jail corner radius, check for updates, reset to defaults, reset everything and quit. Keeping them in the panel satisfies "everything modifiable in the dropdown" without making the default view a control surface.

Jail corner radius is the fourth jail setting to migrate out of `mousejail.lua`, beyond the three the companion names (enable state, target bundle id, toggle hotkey). It is the radius in points of the rounded-corner arc the clamp follows, default 18, bounded 0 to 200, where 0 turns corner clamping off.

Every control writes through to `UserDefaults` and takes effect immediately, as `pointer-and-scroll.md` already requires.

**The hotkey recorder is the one control the panel's dismissal genuinely threatens.** Recording a shortcut means holding key focus while the user presses a chord, in a panel that closes on any outside click and has no menu keyboard navigation. Three mechanisms, in the order they are tried, all inside the same dropdown:

1. A button that enters recording mode and captures with `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` while the panel is key. Simplest, and it works only if the panel becomes key.
2. If the panel becomes key but the monitor never fires, an `NSViewRepresentable` wrapping a custom `NSView` that returns true from `acceptsFirstResponder`, takes first responder when recording starts, and overrides `keyDown(with:)` and `performKeyEquivalent(with:)`. `performKeyEquivalent` is what catches chords that the responder chain would otherwise route to a menu.
3. If the panel never becomes key at all, the hotkey ships fixed at the `cmd+alt+L` that `hammerspoon/mousejail.lua` uses today, and the Advanced row shows the chord as text rather than as a recorder. That is a declared departure from the companion's requirement that the toggle hotkey move into settings, carried in the changes table above, and it is conditional: it applies only if both mechanisms above fail. Restoring configurability would then need a key-capturing window opened from the panel, which changes the shape of the "no separate window" decision and is the user's call, not this document's.

Whichever mechanism lands, two rules hold. Recording cancels and keeps the previous chord when the panel dismisses, so a lost panel can never leave a half-recorded binding, and the monitor or first responder is torn down on the same path, so a dismissed panel leaves nothing capturing keys. `RegisterEventHotKey` can also fail because another app already owns the chord: that failure shows in the row rather than leaving a recorded chord that does nothing.

Moving the recorder to 3b would not help, since 3b keeps the same panel. The fallback is mechanism 3, not a later phase.

### Game picker

Contents: the stored target first, then every running application whose `activationPolicy` is `.regular`, deduped by bundle id, sorted by `localizedName` with a case-insensitive compare, each row carrying `NSRunningApplication.icon` at 16 points. Rows are tagged by bundle id, never by name, so two apps with the same display name stay distinguishable; when two visible rows would carry the same name, both get the bundle id appended in the label. An application with no bundle id is left out of the list, since the jail matches frontmost by bundle id and has nothing to match on.

Cataclysm filters itself out of its own list. Selecting it would jail the cursor to the panel.

**The stored target must appear even when it is not running.** League's game client, `com.riotgames.LeagueofLegends.GameClient`, exists only while a match is running. The processes present between games are `Riot Client` and `LeagueClientUx`, under different bundle ids: with the launcher open, `osascript -e 'tell application "System Events" to get name of every application process whose background only is false'` returned `Google Chrome, Finder, Spotify, Discord, Obsidian, Microsoft Outlook, Messages, Orca, Riot Client, LeagueClientUx` and no entry named "League of Legends". That is a name-level query rather than the `NSWorkspace.runningApplications` filter the picker uses, so the picker's own list is confirmed only by the prototype's behavior: its selection rendered empty on the shipped default, which is the same absence seen from the other direction. Persist the bundle id and the display name together, and synthesize the row from the stored name when the app is absent.

A target that is uninstalled rather than merely closed behaves identically: the synthesized row stays selected, the jail never engages, and nothing reports an error, because the two states are indistinguishable from outside and neither is a failure.

Rebuild the list when the panel opens, and on `didLaunchApplicationNotification` and `didTerminateApplicationNotification`, both posted on `NSWorkspace.shared.notificationCenter` rather than `NotificationCenter.default`. A target quitting while the panel is open therefore drops out of the running section and reappears as the synthesized stored row, with the selection unchanged.

Beyond the ask, and cheap: a final "Choose from Applications…" row opening an `NSOpenPanel` restricted to `.app`, reading the bundle id out of the chosen bundle. Without it there is no way to target a game that is installed but not currently running, which is the state a player is in while deciding to try the tool. The open panel takes focus and therefore dismisses the Cataclysm panel; the rule is that the chooser applies its result to `UserDefaults` directly and does not assume the panel survived, and the player reopens the panel to see the new selection. Cut the row if the picker should stay literally a list of open apps.

### Scroll speed slider

Range 0.25x to 4.0x on a logarithmic scale, so 0.5x and 2.0x sit the same distance either side of 1.0x. A linear slider would park the default at 20% of the track and hand three quarters of the travel to speeds above 1x.

The slider's range is not the persisted bound. `pointer-and-scroll.md` bounds the stored multiplier to 0.001 through 100 (`mulThousandths`, an integer 1 through 100000) and its test harness exercises both ends. That stored bound stays exactly as it is: it is the safety bound that keeps the accumulator's intermediates inside `Int64` and stops a hand-edited plist from reaching the tap. A stored value outside 0.25 to 4.0 is legal, is not rewritten on load, and displays with the slider parked at the nearer end. Only a value outside 0.001 to 100 is clamped.

Snap to two decimals. Render the readout with `.monospacedDigit()` so the panel does not shift as the number changes. A reset control returns it to exactly 1.00x.

Live preview is not available. The panel dismisses on outside clicks, so scrolling another window to feel the setting closes it. The multiplier applies on release and the player checks it afterwards.

### Status and failures

The panel is the only surface this app has, so it is where every failure has to appear. `pointer-and-scroll.md` requires surfacing a false return from `IOHIDEventSystemClientSetProperty` and not exiting quietly on a lost Accessibility grant, without saying where. Here:

- Accessibility not granted: the header becomes a warning row with a button that reopens onboarding. Both taps are down, so the jail and the scroll filter are inert, and their toggles read as unavailable rather than on.
- The acceleration property write returned false: the toggle shows as failed, not as checked. A checked toggle over a failed write is indistinguishable from the curve simply feeling different, which is the failure this rule exists to prevent.
- Tap creation failed: same treatment on the affected feature.
- The watcher agent is not registered or awaiting approval: a row saying crash recovery is off, with a button opening `x-apple.systempreferences:com.apple.LoginItems-Settings.extension`.

Each of these states has a test row in "Testing". A status rule with no way to reach it in a test is a rule that silently rots.

## First run

No terminal, no stderr, no silent exit. `main.swift` today writes "accessibility permission missing" to stderr and exits 1, which under Hammerspoon surfaces as an alert and as a standalone app surfaces as nothing at all.

**Startup order.** Every rule below is about global state that outlives the process, so the order is part of the design rather than an implementation detail.

1. **Take ownership, atomically.** Open `~/Library/Application Support/<bundle-id>/instance.lock` and take an exclusive non-blocking advisory lock on it (`flock(LOCK_EX|LOCK_NB)`, or `fcntl` `F_SETLK`), held open for the whole process lifetime. Acquiring the lock is what makes this instance the owner; the kernel releases it on any exit, `SIGKILL` included, so no stale lock can lock the app out. A process that does not get the lock shows a one-line notice, exits 0, and touches nothing at all: not the cursor, not the acceleration property, not the agent.

   A `NSRunningApplication.runningApplications(withBundleIdentifier:)` check is not enough on its own and is not what this rule uses. It is a read with no ownership: two copies launched at the same moment can each look, each see nothing, and each proceed to write the acceleration property and re-associate the cursor. The lock is the decision; the running-applications query only supplies the other instance's name for the notice.

   This step precedes re-association, which is the one place this document departs from the companion's "re-association is the absolute first startup operation". The reason that rule exists is to thaw a cursor a dead instance left frozen; when a live instance is jailing, there is nothing to thaw and re-associating would break the running jail mid-match. The watcher takes no lock and needs none: it only ever calls the idempotent release.
2. **Re-associate the cursor**, `CGAssociateMouseAndMouseCursorPosition(1)`. Needs no Accessibility grant, measured: a bundled app whose bundle id has never been granted anything gets `kCGErrorSuccess` from it, so this step works on a build that has lost or never had its grant.
3. **Install location gate.** If `Bundle.main.bundleURL` sits under `/Volumes/` or its path contains `AppTranslocation`, show one screen saying to drag the app to Applications first, and stop: no taps, no acceleration write, no agent registration. Three measured reasons. The mounted image is read-only. Two DMGs with the same volume name mount at `/Volumes/Cataclysm` and `/Volumes/Cataclysm 1`, so the path is not stable across mounts. And ejecting the volume out from under a registered agent leaves a job whose executable is gone. Running from `~/Downloads` is allowed, because `BundleProgram` (below) makes the agent's executable path bundle-relative, but the screen still offers to move the app.
4. **Load and clamp settings**, so nothing downstream reads an out-of-range value.
5. **Check trust**, and show onboarding if it is false.
6. **Start the taps, apply the acceleration property, register the agent.**

Steps 1 through 3 run before any UI, so a duplicate launch or a launch from the DMG never flashes a panel.

Onboarding window, shown when `AXIsProcessTrusted()` is false:

- One screen. Says that macOS requires Accessibility for any app that repositions the cursor or reads mouse events, and that the app does nothing else with it.
- Primary button calls `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])`, which raises the system prompt with the app pre-listed.
- Secondary button opens `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`. Still resolvable on macOS 26.3, verified in the appendix; the floor test confirms it on 13.
- Poll `AXIsProcessTrusted()` every 0.5s, dismiss and start the taps on success. Whether the trusted state updates within the process lifetime on macOS 26 is unverified; keep a "Relaunch" button as the fallback and remove it only after the check named in "Open" says polling is enough.
- Not shown again while the grant holds. The lost-grant path reopens it from the header warning row.

The watcher agent is registered only after onboarding completes, never on a first launch that is still ungranted or still quarantined. A friend's first open is what clears quarantine, and registering an agent whose binary Gatekeeper has not yet cleared is how a crash-recovery job turns into a dialog nobody is there to answer.

## Crash recovery and the watcher

`pointer-and-scroll.md` establishes the failure that matters: the process dies while the jail holds the cursor disassociated, leaving the cursor frozen system-wide, and `SIGKILL` defeats every in-process protection. It also rules out making the app itself the KeepAlive job, because `KeepAlive` implies `RunAtLoad`, which welds crash recovery to launch-at-login, and because a Finder-launched instance is not the launchd job at all. This document takes the design that document recommends and pins the details.

**Two independent registrations.**

- The watcher: `SMAppService.agent(plistName:)` over `Contents/Library/LaunchAgents/<bundle-id>.watch.plist`. It always runs. It is not a user setting.
- Launch at login: `SMAppService.mainApp`, the toggle in the panel, with no effect on the watcher.

**The watcher process.** The same binary under `--watch`. It starts no UI, installs no tap, writes no acceleration property, and needs no Accessibility grant.

Its loop: sample once a second for a live application with the app's bundle id. **On its own startup, if the app is already absent, re-associate once before entering the loop.** Then re-associate once on every present-to-absent transition. The startup release is not redundant with the transition rule and is the case that matters most: a watcher that is itself killed, or that launchd has just restarted, or that starts at login after a crash the previous session left behind, observes `absent` followed by `absent` and would never see a transition. Without the startup release, the exact scenario the watcher exists for, a `SIGKILL` that takes the app while the cursor is disassociated, recovers only if the watcher happened to be alive across it.

A redundant release after a clean quit is harmless, since the call is idempotent.

**Re-association needs no Accessibility grant, measured rather than assumed.** An ad-hoc signed, hardened-runtime app bundle whose id has never been granted anything reports `AXIsProcessTrusted: false`, was refused an active event tap when that was measured once (`CGEvent.tapCreate` with `.defaultTap` returned nil), and still gets `kCGErrorSuccess` from both `CGAssociateMouseAndMouseCursorPosition(1)` and `CGWarpMouseCursorPosition`. So the watcher works ungranted, and so does the app's own recovery path after a revoked grant. One trap this measurement exposes: a `.listenOnly` tap *is* created in the same untrusted process, so a permission test written against a listen-only tap reports success on a build that cannot actually run the jail.

**The plist.** `Label` matching the file name, `KeepAlive` as `{ SuccessfulExit = false }` so a watcher told to stop stays stopped, `AssociatedBundleIdentifiers` set to the app's bundle id so System Settings shows the job under the app's name, and, importantly:

```xml
<key>BundleProgram</key><string>Contents/MacOS/cataclysm</string>
<key>ProgramArguments</key>
<array><string>cataclysm</string><string>--watch</string></array>
```

`BundleProgram` is an app-bundle-relative executable path that `launchd.plist(5)` supports only for plists installed through `SMAppService`, and its stated purpose is to let a user relocate the app after installation. A hardcoded `/Applications/Cataclysm.app/...` in `ProgramArguments` would break for every friend who keeps the app anywhere else, which is exactly the `~/Downloads` case.

**Registration is fallible, and its failures are visible.** `SMAppService` requires the app to be code signed, which is why signing moves into 3a. `register()` throws, and `status` can come back `.requiresApproval` when the user has denied the job in System Settings. Both land in the panel's status area, never in a log nobody reads.

**Every app update must unregister and re-register the watcher.** The `SMAppService` header states that when an app changes either the plist or the executable of a registered agent, the service must be re-registered or it may not launch, and recommends unregistering first when the executable changed. Every release changes the executable, so this is not an edge case: it is a step in the update path, run once at launch when the running build's version differs from the version recorded in `UserDefaults`.

**Throttle.** launchd restarts a KeepAlive job at most about every 10 seconds. A watcher that crashes in a loop can therefore leave a frozen cursor for that long, which is the honest worst case to put in the README. The watcher is deliberately tiny for this reason: a poll loop and one CoreGraphics call.

**The app deleted while the agent is registered.** The job survives in launchd with an unresolvable `BundleProgram` and simply fails to spawn. It is visible and removable in System Settings, Login Items, which is why `AssociatedBundleIdentifiers` is set. The clean path is "Reset everything and quit" before dragging the app to the Trash, and the README says so.

## Packaging

### Bundle

`Cataclysm.app`, `LSUIElement` true, `LSMinimumSystemVersion` 13.0, version string from a Makefile variable, `Contents/Library/LaunchAgents/<bundle-id>.watch.plist`, and a `.icns` in `Contents/Resources`.

The icon is built with `iconutil -c icns <name>.iconset`, where the `.iconset` directory holds the ten conventionally named sizes (`icon_16x16.png` through `icon_512x512@2x.png`) generated from a 1024px source with `sips`. That full set is what both phases build, and the Makefile target generates it rather than hand-maintaining ten files. `iconutil` also accepts an iconset holding only `icon_512x512@2x.png`, verified in the appendix, but a menu bar icon draws at 16 to 18 points and a downscale from 1024 is not what a hand-tuned small slice looks like, so the one-slice form is a fallback for a placeholder and never the shipped recipe. 3a ships a placeholder; 3b replaces the artwork.

**The bundle id is chosen once and never changed.** TCC keys the Accessibility grant to it: the grant table's primary key includes the client identifier, and the stored requirement blob names the identifier explicitly, so a later change silently revokes every installed copy and orphans `~/Library/Preferences/<bundle-id>.plist` along with it. Pick a reverse-DNS prefix that will still be true in three years.

**Universal binary.** The Makefile builds host-native today, which on this machine means arm64 only, and an arm64-only app will not launch on an Intel Mac at all. Build both slices explicitly, keeping the bridging header `pointer-and-scroll.md` requires for the IOKit HID calls, and join them:

```
xcrun swiftc -O -target arm64-apple-macos13.0  -import-objc-header Bridging.h *.swift -o build/cataclysm-arm64
xcrun swiftc -O -target x86_64-apple-macos13.0 -import-objc-header Bridging.h *.swift -o build/cataclysm-x86_64
lipo -create build/cataclysm-arm64 build/cataclysm-x86_64 -output Cataclysm.app/Contents/MacOS/cataclysm
```

The `-target` triple also sets the deployment floor, so this is where macOS 13 is actually enforced rather than only declared in the plist. Verified: both slices build clean against the macOS 13 floor with the panel's whole API surface, and `otool -l` reports `minos 13.0` on each. See the appendix.

### Signing and notarization

Gatekeeper's first-launch check applies to any quarantined app, and the container does not matter: a DMG and a zip are treated the same. Quarantine propagates out of a mounted image onto the copy the friend drags to Applications, measured in the appendix. Signing alone does not satisfy the check: an ad-hoc signed, hardened-runtime app is `rejected` by `spctl -a -t exec`, before and after the DMG round trip.

**What that measures, exactly.** An unsigned or ad-hoc signed app is refused, and quarantine survives the DMG. It does not isolate notarization: a Developer ID signature without notarization was not tested, because no Developer ID certificate exists on this machine. Apple's documented rule is that software distributed outside the App Store must be notarized to open without the warning, and every third-party app on this machine that opens cleanly is notarized, but this document has not measured the Developer-ID-without-notarization case and does not claim to have. The check that would settle it is one Developer ID signed, unnotarized, quarantined build assessed with `spctl -a -vvv -t exec`.

So for the drag-and-open flow the app is signed with a Developer ID Application certificate, notarized, and stapled. Release path:

```
codesign --force --options runtime --timestamp -s "Developer ID Application: <name>" Cataclysm.app
hdiutil create ...                       # see DMG below
codesign --force --timestamp -s "Developer ID Application: <name>" Cataclysm.dmg
xcrun notarytool submit Cataclysm.dmg --keychain-profile <profile> --wait
xcrun stapler staple Cataclysm.dmg
```

- Hardened runtime (`--options runtime`) is mandatory for notarization. Event taps and the Accessibility APIs are gated by TCC rather than by entitlements: a binary signed `--options runtime` with no entitlements at all creates a `.cghidEventTap` and reads `AXIsProcessTrusted()` normally, executed in the appendix. No entitlement is expected to be needed, and the real notarization run is where that stops being an expectation.
- Store the notary credentials with `xcrun notarytool store-credentials` into the login keychain and reference the profile by name. No credential appears in the Makefile, in the repo, or in a log.
- Staple the DMG so a first launch works offline. Stapling without a notarization ticket fails outright (`Error 65`, ticket not found), so this step is also the release's own check that notarization actually happened.
- Drop `--deep`, which is deprecated for signing and has no nested code to reach here. The bundled LaunchAgent plist is a resource, not nested code.

**Sufficiency is unverified too**, and an `spctl` call on the build machine would not establish it: what is promised is a friend opening the app offline on a machine that has never seen it. The check is the whole flow, on a different Mac, with networking off: download or copy the stapled DMG so it carries quarantine, mount it, drag the app to Applications, open it, and see no warning. Offline is the part that tests stapling specifically, because an online machine can fetch the ticket from Apple and hide a stapling failure. `spctl -a -vvv -t exec` printing `accepted` with `source=Notarized Developer ID` is the cheap precondition, not the test.

Without a Developer ID membership, everything above still builds and the app still works. The single difference is that the friend clears one malware warning by hand, and the README has to walk them through it. This is the only thing the $99 buys, and it buys exactly the "drag it over and open it" flow.

**Registering the watcher is a hard 3a gate, with a second mechanism behind it.** The `SMAppService` header says only that an app using the API "must be code signed", which does not settle whether a self-signed certificate satisfies it. So the first thing 3a does after the bundle assembles is: sign with the local identity, call `agent.register()`, and read back `SMAppService.agent(...).status` plus `launchctl print gui/$UID/<label>` to confirm launchd resolved `BundleProgram` to the executable inside the bundle.

If `SMAppService` refuses the self-signed identity, the fallback is the mechanism it replaced, not the Hammerspoon supervisor: the app writes the same job to `~/Library/LaunchAgents/<label>.plist` and runs `launchctl bootstrap gui/$UID <plist>`. That path has no code-signing requirement at all, and it is measured to run, not merely to load: launchd bootstrapped a legacy job whose program was an ad-hoc signed, hardened-runtime binary (`flags=0x10002`, a weaker signature than the self-signed identity 3a would use), executed it, and the program wrote its marker and got `kCGErrorSuccess` from the same re-association call the real watcher makes (appendix 17). Two differences the implementation has to carry. `BundleProgram` is supported only for plists installed through `SMAppService`, so the legacy plist needs an absolute `ProgramArguments` path, written by the app at registration time from `Bundle.main.bundleURL` and rewritten whenever the app notices it has moved. And "Reset everything and quit" has to `bootout` and delete that file as well as unregistering the `SMAppService` job.

**The Hammerspoon supervisor is not a fallback for this.** `hammerspoon/mousejail.lua` starts the helper as its own child and releases the cursor when that child exits; it has no way to notice a Finder-launched `Cataclysm.app` dying, because that app is not its child. Keeping the lua around would produce the appearance of crash recovery and none of the substance, so 3a retires it once either watcher path is live, and one of the two always is.

**3a signs with a self-signed certificate, and needs one to exist.** Two independent reasons, neither of which waits for 3b. `SMAppService` refuses to work for an app that is not code signed, and the watcher is 3a scope. And TCC keys the grant to the code requirement: an ad-hoc signature's designated requirement is a per-slice cdhash disjunction that changes with any real code change, measured in the appendix, so every rebuild would drop Accessibility. A certificate-backed identity gives `identifier "<bundle id>" and certificate leaf ...`, which does not move. On this machine `security find-identity -v -p codesigning` currently reports `0 valid identities found`, so creating the certificate is a real step in 3a rather than an assumed prerequisite.

The shape a Developer ID signature gives is worth seeing concretely, because it is why a friend's grant survives updates. Hammerspoon's stored Accessibility requirement on this machine reads `anchor apple generic and identifier "org.hammerspoon.Hammerspoon" and (certificate leaf[field.1.2.840.113635.100.6.1.9] exists or certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = VQCYSNZB89)`: bundle id plus team, with no reference to the binary's contents.

### DMG

Staging folder holding `Cataclysm.app` and a symlink to `/Applications`, then `hdiutil create -volname Cataclysm -srcfolder stage -ov -format UDZO Cataclysm.dmg`.

That produces a working drag-to-install DMG with Finder's default layout, verified in the appendix. The arrow-and-background presentation needs the window geometry written into the volume's `.DS_Store`, which means driving Finder over AppleScript. Use the `create-dmg` tool for it rather than hand-rolling that; it is a build-machine dependency only, it never ships, and it is not installed on this machine today. The plain `hdiutil` line stays as the fallback so a release is never blocked on it.

### Release

Two release targets, because the membership decision is still open and a build must not silently produce the wrong artifact.

- `make dmg VERSION=x.y.z` builds the universal binary, assembles the bundle, signs it with `IDENTITY` (whatever identity is configured, local or Developer ID), and produces the DMG. It never notarizes.
- `make release VERSION=x.y.z` runs `make dmg` and then notarizes and staples. It requires both a Developer ID `IDENTITY` and a `NOTARY_PROFILE`, and it fails immediately with a message naming what is missing rather than emitting an unnotarized artifact under a name that promises otherwise. The stapler step doubles as the check that notarization actually happened, since it refuses without a ticket.

With the membership, releases go out from `make release`. Without it, they go out from `make dmg` and the README carries the Open Anyway walkthrough. Either way the artifact goes on a GitHub Release with a body that leads with what the app fixes rather than how it works.

No auto-update. Sparkle is out of scope for a tool that changes a few times a year. A "Check for updates" item in Advanced opening the releases page is enough.

## Failure and edge-case rules

The rules above cover the paths a friend walks. These are the ones a friend falls into. Each is a stated rule or an explicit exclusion, not a hope.

**TCC grant lifecycle.**

- Revoked while running: the taps stop delivering and the app must not treat that as a crash. On `AXIsProcessTrusted()` going false, re-associate the cursor, drop both features into the unavailable state, show the header warning, and keep polling. Never exit. The re-association in that sequence is measured to work without a grant (appendix 3b), which is what makes this recovery real rather than hopeful; the same measurement shows the active tap is refused, so the features genuinely are down and the UI must say so.
- A version update dropping the grant: prevented by the certificate-stable designated requirement, and by never changing the bundle id. If it happens anyway the app sees an ungranted state on launch and re-onboards, which is the same path as a first run.
- The app moved after being granted: TCC matches on the identifier and the requirement, not on a path, so the grant is expected to survive a move. Expected, not verified: the floor and Intel test passes are where it gets exercised, by granting in `/Applications` and then running the same bundle from `~/Downloads`.
- Bundle id changed: the grant is gone and unrecoverable, and the settings plist is orphaned with it. This is why the id is chosen once.
- First launch where a previous version was granted: the app must not assume that a first launch means an ungranted one. The trust check decides, not a "has run before" flag.

**Acceleration property ownership.** `pointer-and-scroll.md` owns the mechanism, the -1 guard, the 196608 bootstrap, the adopt rule, and the 5s reassert. Three consequences belong here because they are about this app's lifecycle rather than the property:

- Killed with `SIGKILL` while the property is -1: the watcher does not restore acceleration, only the cursor. The property stays -1 until the next launch, which reads the stored original out of `UserDefaults` and restores it. So the original has to be persisted rather than held in memory, and the -1 guard is what makes the next launch's read safe.
- The stored original acceleration value is recovery metadata, not a preference. It lives under its own key prefix, and **"Reset to defaults" never touches it**: that command resets the settings a person chose, while the app is still running with the property at -1, and erasing the only record of the real value there would strand the machine with acceleration off. "Reset to defaults" also reapplies the defaults immediately, which means writing -1 again rather than restoring.
- "Reset everything and quit" restores acceleration and re-associates the cursor *before* clearing `UserDefaults`. Clearing first destroys the stored original and leaves the machine with acceleration off and nothing that remembers the old value.
- Two copies running: on launch, if another running application carries the same bundle id, the new instance shows a one-line notice and exits 0 without touching the cursor or the property. Two instances fighting over the acceleration property and over cursor association is the one multi-instance case that damages state rather than merely duplicating UI.

System Settings tracking-speed changes and wake-from-sleep are the companion's adopt rule and its `didWakeNotification` reassert, unchanged.

**Quit versus the watcher.** Menu Quit restores the acceleration property, re-associates the cursor, and exits 0. The watcher is a different process and is unaffected: it notices the app is gone, calls re-association once more, and idles. There is no respawn race, because the watcher never launches the app. "Reset everything and quit" additionally unregisters both the watcher agent and the login item before clearing settings, so nothing is left to respawn or to appear in Login Items.

**Picker and target state.** Covered in "Game picker": absent target, uninstalled target, duplicate display names, missing bundle id, target quitting with the panel open, and the app itself as target.

**Settings persistence.** Every numeric setting is clamped on load, not only in the UI, as `pointer-and-scroll.md` requires: multiplier to 0.001 through 100, lines per notch to 1 through 1000, corner radius to 0 through 200. A value of the right type but semantically impossible is clamped by the same rule, since the bounds exclude 0 for the multiplier and for lines per notch. Keys absent from an older version's plist take their defaults; keys the current version does not know are left untouched rather than pruned, so a downgrade does not lose the newer version's settings. A plist that fails to parse at all is ignored and the defaults apply.

**Install and first run.** The `/Volumes` and translocation gate above covers running from the mounted image and both-versions-mounted. Running from `~/Downloads` is supported through `BundleProgram`. The quarantined-binary case is handled by not registering the agent until onboarding has completed at least once.

**Out of scope, deliberately.** Multiple user accounts on one Mac sharing an install: each account gets its own agent registration and its own settings, which is correct, and nothing is done to coordinate them. Fast user switching while the jail holds the cursor: untested and unspecified. A managed Mac where an MDM profile blocks Accessibility or login items: the app shows its normal failure states and does nothing clever.

## Uninstall and recovery

A friend needs a clean exit, and the app holds three pieces of state that outlive it badly: cursor association, the acceleration property, and two launchd registrations.

- Quit restores the acceleration property and re-associates the cursor, and exits 0.
- "Reset everything and quit" in Advanced: restore acceleration, re-associate the cursor, unregister the watcher agent and the login item, clear `UserDefaults`, in that order. Then the app is safe to drag to the Trash.
- README covers the frozen cursor case: the watcher notices the dead app and re-associates within about a second, with roughly 10 seconds as the worst case if the watcher itself has to be restarted by launchd. Failing that, log out.

## What friends' machines have that this one does not

Widening the audience is the actual risk in this phase, more than any single API.

- **Intel hardware.** Covered by the universal binary above. The x86_64 slice builds and lipos here; that it launches is untested until someone runs it, under Rosetta at worst.
- **Older macOS.** Floor is 13, and the whole API surface compiles against it (appendix). What compiling cannot tell us is runtime behavior, so the floor pass covers the panel rendering, the System Settings deep link, agent registration, and login item registration, not just the install.
- **No Logitech receiver.** The alternate trackpad detection exists because of one on this machine, and only if phase 2's measurement kept the feature at all. Default stays on the primary test.
- **A laptop with no mouse at all.** The scroll filter only touches non-continuous events, so it is already a no-op on a trackpad. `HIDMouseAcceleration` is a mouse key and the trackpad has its own, which the app never writes. Confirm the app is inert rather than assuming it.
- **A second display.** The jail confines the cursor to one window's rect, so the other display is unreachable while League is frontmost. That is the intended behavior and it will surprise someone. One README line.
- **A different corner radius.** The 18 point default is measured off Riot's window and is a window-server constant rather than a resolution-dependent one, so it should hold. Worth one check at a second resolution.
- **Riot's terms.** The app clamps and rewrites the player's own input and synthesizes none of it, and macOS League does not run Vanguard. Say plainly in the README what it does and does not do, so nobody has to guess.

## Naming

`Cataclysm`, after Jarvan IV's ultimate: terrain that closes into an arena a champion cannot leave. Repo `cataclysm`, app `Cataclysm.app`, binary `cataclysm`. GitHub redirects the old `mousejail` URL, so nothing breaks. This settles the companion's open "Name" item.

The name carries the cursor jail and not the scroll and acceleration work, so the README's first line does the explaining: fixes the mouse for League of Legends on macOS.

## Phasing

Phase 3 of `pointer-and-scroll.md` splits, because shipping to other people is a different job from having a menu bar app.

| Phase | Content | Estimate |
| --- | --- | --- |
| 3a | App bundle, self-signed identity created and signing wired into the Makefile, single-instance lock, `MenuBarExtra` panel with all settings, game picker, onboarding window, install-location gate, `--watch` agent and login item, hotkey. Rename to Cataclysm. The Hammerspoon lua is retired once a watcher path is live, `SMAppService` or the legacy plist, and not before. | 5-6h |
| 3b | Universal binary, icon artwork, `make dmg`, README rewritten for friends. With the membership: Developer ID signing, then `make release` for notarization and stapling, plus the offline install test on a second Mac. Without it: `make dmg` with the local identity is the release, and the README carries the Open Anyway walkthrough. | 2-3h |

3a is usable by the author at the end of it, in the same sense phases 0 through 2 are: signed with a local certificate, so the Accessibility grant survives rebuilds, and with crash recovery actually running rather than promised. The acceptance gate is a registered watcher, by either mechanism; until one is registered, the lua stays and 3a is not finished. It is not sendable, and nothing in 3a assumes it is.

The estimate for 3a is above the companion's 3-4h for the whole of phase 3 because 3a absorbed the onboarding window, the picker, the watcher agent, and the install gate, and kept the signing-identity setup rather than deferring it.

## Testing

Adds to the matrix in `pointer-and-scroll.md`.

Install and platform:

- Install from the DMG on a fresh user account, as a friend would: mount, drag, open, grant, play. Nothing may require a terminal.
- The same on an Intel Mac, or under Rosetta as a partial substitute, to confirm the x86_64 slice launches.
- Whichever release branch is in use: `make release` must refuse outright when the notary profile is missing rather than emitting an unnotarized DMG, and `make dmg` must produce an image that installs with the documented Open Anyway step.
- The same on the macOS deployment floor, checking specifically that the panel renders as it does on 26, that the Accessibility deep link opens the right pane, that agent registration succeeds, and that the login item toggle works.
- Open the app directly from the mounted DMG volume, and from `~/Downloads`: the first must refuse with the move-to-Applications screen, the second must work with a registered agent that still resolves after the app is moved.
- Grant Accessibility with the app in `/Applications`, then run the same bundle from `~/Downloads`, to see whether the grant follows the identity or the path.

Panel and state:

- Game picker with League closed, with League open at the launcher, and with a match running. The stored target must stay selected in all three.
- Revoke Accessibility while the app runs: the header must become the warning row, both feature toggles must read unavailable, the cursor must be re-associated, and the app must still be running.
- Force the acceleration write to fail: the toggle must show failed rather than checked.
- Deny the watcher agent in System Settings, then relaunch: the panel must show crash recovery as off and offer the Login Items link.
- Record a hotkey: the panel must take the chord, cancel cleanly when the panel is dismissed mid-recording, leave nothing monitoring keys afterwards, and show a failure in the row when `RegisterEventHotKey` refuses a chord another app owns.
- Hand-edit `~/Library/Preferences/<bundle-id>.plist` to a multiplier of 0, lines per notch of 0, and a negative corner radius, then launch: every value clamped, nothing dead, no crash.

Lifecycle:

- Quit, then confirm acceleration is restored and the cursor is associated. Then relaunch and confirm the original acceleration value was not overwritten with -1.
- `SIGKILL` the app while the jail holds the cursor: the watcher must re-associate within about a second. Then relaunch and confirm acceleration is restored from the stored original.
- `SIGKILL` the app and the watcher together, cursor disassociated, then let launchd restart the watcher: it must release on startup, having never seen a present-to-absent transition. This is the case a transition-only watcher silently fails.
- Log out and back in with the cursor left disassociated by a `SIGKILL`: the watcher must release at login for the same reason.
- Revoke Accessibility while the jail holds the cursor: the cursor must be released, which is what makes the revocation path safe rather than a freeze.
- "Reset to defaults" while acceleration is off: the settings return to defaults, acceleration stays off because that is the default, and the stored original value survives. Then quit and confirm the original is restored, not -1.
- 3a acceptance, run before the Hammerspoon lua is retired: sign with the local identity, register the watcher through `SMAppService`, and confirm `launchctl print gui/$UID/<label>` shows the executable resolved inside the bundle. If registration is refused, run the same check against the `~/Library/LaunchAgents` fallback, including moving the app and confirming the absolute path is rewritten.
- Whichever hotkey mechanism the panel supports, test that branch: a recorded chord if the panel takes key focus, or the fixed chord toggling the jail if it does not.
- Launch a second copy while one runs, with the first jailing an active match: the second must exit without re-associating the cursor, without writing the acceleration property, and without registering anything. A cursor that unlocks mid-match is the visible symptom of getting this wrong.
- Launch two copies genuinely at once (`open -n` twice from one command line, repeated in a loop): exactly one must acquire the lock every time. A check that only tests a second launch after the first has settled cannot see this failure.
- Ship a version bump: confirm the watcher agent is unregistered and re-registered, and still launches after the update.
- "Reset everything and quit", then confirm the login item and the watcher agent are both gone from System Settings and `UserDefaults` is empty.

## Verification appendix

Everything below was executed on this machine (macOS 26.3 build 25D2125, Swift 6.3.3, arm64, SDK 26.5) and is reproducible with `verify.sh` in `specs/evidence/build/`, which carries the fixture sources next to it (copied there, into the repo tree for committing, from the review run's working area at `.claude/pairs/distribution-ui-spec/evidence/build/`; the `MenuBarExtra` style fixtures sit in `specs/evidence/`, with their screenshots left in the untracked run directory). The `App.swift` fixture is the panel this document specifies, reduced to the API surface whose availability is load-bearing.

The script copies its fixtures into a fresh temporary directory and refuses to continue if any fixture is missing, so no artifact from an earlier run and no half-set-up directory can be read as a result. It reports PASS, FAIL, or SKIP per claim, prints the three totals, and exits non-zero if anything failed.

No check in the script may raise a user-facing permission dialog. Creating an active event tap from an untrusted process raises the system "wants to receive keystrokes" prompt and leaves a row in System Settings for a throwaway bundle, so that measurement was taken once, is recorded below as claim 3b, and is not repeated: the script attempts a tap only from an already trusted process and the untrusted probe now calls nothing TCC-gated. The same rule rules out `CGRequestListenEventAccess`, `IOHIDRequestAccess`, screen recording, and `AXIsProcessTrustedWithOptions` with the prompt option set, in the reproducer and in any future probe. Where a claim can only be settled by raising a prompt, it is marked unverified with the check named rather than fired.

Distinguishing an environment limit from a failed claim is done with a positive test rather than by trusting an error message, because two of the tools here lie about the cause. `iconutil` prints `Invalid Iconset` when its mach lookups are denied, so the script asserts all ten slice filenames and their exact pixel sizes and runs `sips -s format icns` as an independent canary; only a complete iconset plus a working canary licenses a SKIP, and an incomplete iconset FAILs whatever the canary says. The disk-image, Full Disk Access, GUI-session, and Gatekeeper-service limits are detected the same way, from the specific condition rather than from any non-zero exit.

Last full run on this machine: 40 checks, 40 passed, 0 failed, 0 skipped, and no permission dialog. Every executed claim below has a check in that script, including claim 17, whose probe job is uniquely labelled, runs exactly once, writes a marker, and is booted out and deleted along with its binary by the script's exit trap even if the script dies.

| # | Claim | Result |
| --- | --- | --- |
| 1 | The whole panel API surface compiles at the macOS 13 floor | `swiftc -target arm64-apple-macos13.0` and `-target x86_64-apple-macos13.0` both build clean (one unused-`var` warning) with `MenuBarExtra`, `.menuBarExtraStyle(.window)`, `DisclosureGroup`, `Slider`, `Picker`, `AppStorage`, `.monospacedDigit()`, `SMAppService.agent(plistName:)`, `SMAppService.mainApp`, `AXIsProcessTrustedWithOptions`, Carbon `RegisterEventHotKey`, `NSOpenPanel.allowedContentTypes`, and the `NSWorkspace` launch, terminate, and wake notifications |
| 2 | The universal recipe works, bridging header included | `-import-objc-header Bridging.h` with the IOKit HID headers compiles on both slices; `lipo -create` produces `x86_64 arm64`; `otool -l` shows `minos 13.0` on both |
| 3a | Hardened runtime needs no entitlement for an active event tap | A binary signed `--options runtime`, with `codesign -d --entitlements -` printing none, creates an active `.cghidEventTap` (`options: .defaultTap`) in a trusted context |
| 3b | TCC is the gate, not entitlements, and re-association sits outside it | The same code in an ad-hoc signed bundle whose id has never been granted anything: `trusted=false`, `.defaultTap` returns nil, and `CGAssociateMouseAndMouseCursorPosition(1)` and `CGWarpMouseCursorPosition` both return `kCGErrorSuccess`. A `.listenOnly` tap is created even there, which is why a listen-only permission test is misleading. **The tap and warp halves are a recorded one-time measurement**, taken on this machine under bundle id `com.example.assocprobe.never-granted`: attempting the tap raises a permission dialog, so the script no longer repeats it and asserts only the two calls that raise nothing. Re-taking it means accepting one dialog |
| 4 | Signing alone does not clear Gatekeeper | Ad-hoc signed, hardened-runtime `Cataclysm.app`: `spctl -a -vvv -t exec` returns `rejected` |
| 5 | Quarantine reaches the copied app through a DMG | `com.apple.quarantine` set on the image, mounted, app copied out: the copy carries `com.apple.quarantine: 0281;00000000;;` and `spctl` returns `rejected`. The app inside the read-only image carries only `com.apple.provenance` |
| 6 | Stapling requires a real ticket | `xcrun stapler staple` on an unnotarized DMG: `Could not find base64 encoded ticket`, `Error 65` |
| 7 | An ad-hoc designated requirement moves with the code | Universal ad-hoc bundle: `designated => cdhash H"..." or cdhash H"..."`, one per slice. A comment-only edit that produced a byte-identical binary kept both hashes; a one-line behavior change produced two new ones |
| 8 | TCC keys the grant to identifier plus requirement | `access` table primary key is `(service, client, client_type, indirect_object_identifier)` with a `csreq` blob. Hammerspoon's row decodes to `anchor apple generic and identifier "org.hammerspoon.Hammerspoon" and (... certificate leaf[subject.OU] = VQCYSNZB89)`, which names no code hash |
| 9 | No signing identity exists here yet | `security find-identity -v -p codesigning`: `0 valid identities found` |
| 10 | The DMG recipe produces a drag-to-install image | `hdiutil create -volname Cataclysm -srcfolder stage -ov -format UDZO` mounts with `Cataclysm.app` and an `Applications` symlink; the app's signature verifies on the mounted volume |
| 11 | Two same-named images collide predictably | Mounted at `/Volumes/Cataclysm` and `/Volumes/Cataclysm 1`, both `read-only` |
| 12 | The System Settings deep link identifiers still exist, statically | System Settings owns `x-apple.systempreferences`; the Privacy and Security extension declares `allowsXAppleSystemPreferencesURLScheme` and `legacyBundleIdentifier com.apple.preference.security`, and its binary contains the `Privacy_Accessibility` anchor; Login Items is `com.apple.LoginItems-Settings.extension`. That either URL actually navigates to the right pane is **not** tested here: it needs a GUI session, and it is in the floor test |
| 13 | `BundleProgram` is real and is the relocatable path | `launchd.plist(5)`: app-bundle-relative, "only supported for plists that are installed using SMAppService". The `SMAppService.h` header repeats it and adds that apps using the API "must be code signed", that the plist lives in `Contents/Library/LaunchAgents`, and that an updated executable "must be re-registered" |
| 14 | The icon recipe | From a fresh 1024x1024 PNG (`sips -g pixelWidth -g pixelHeight` confirms the dimensions first), `iconutil -c icns` accepts a one-slice iconset holding only `icon_512x512@2x.png` (302941 bytes out) and the full ten-slice set (585443 bytes out) |
| 16 | `iconutil`'s "Invalid Iconset" also means "sandboxed" | The same iconset that converts at exit 0 unsandboxed returns `one.iconset:Invalid Iconset.` and exit 1 under `sandbox-exec` with a profile denying mach lookups. The message names the iconset for a failure that has nothing to do with it, so the script now runs `sips -s format icns` on the same source as a canary and reports SKIP, not FAIL, when sips succeeds and iconutil does not |
| 17 | The legacy LaunchAgent path runs an ad-hoc signed job | `launchctl bootstrap gui/$UID` on a `~/Library/LaunchAgents` plist whose program is an ad-hoc signed, hardened-runtime binary (`Signature=adhoc`, `flags=0x10002`) returned 0, launchd **ran** it (`RunAtLoad`, marker file written naming the process's own signing flags, `last exit code = 0`), the process got `kCGErrorSuccess` from `CGAssociateMouseAndMouseCursorPosition(1)`, and `bootout` plus the exit trap left nothing behind. An ad-hoc signature is weaker than the self-signed identity 3a would use, so the fallback holds a fortiori. Section 9b of the script |
| 18 | `sips` builds an icns without `iconutil` | `sips -s format icns icon-1024.png --out canary.icns` produces a 303441 byte icns, and it works inside the restricted sandbox where `iconutil` does not |
| 15 | The expected failures are asserted as failures | The script asserts the failing outcomes explicitly rather than reading a non-zero exit as a pass: Gatekeeper `rejected` for the ad-hoc bundle, `Error 65` for stapling without a ticket |

Not verified, and why: notarization end to end and the Developer-ID-without-notarization case (both need the $99 membership), live `AXIsProcessTrusted()` updates (needs a GUI grant toggle), `MenuBarExtra` panel key focus for the hotkey recorder (needs a GUI session), `SMAppService` registration with a self-signed identity (needs the certificate, and registering mutates real login-item state, so it is 3a's first acceptance gate instead), whether the deep links navigate (needs a GUI session), anything on macOS 13 or on Intel (needs the hardware), and App Translocation behavior (needs a quarantined GUI launch).

## Open

- **Developer ID membership.** Yes gives the clean drag-and-open flow. No ships the same DMG with one malware warning and a README step. It blocks nothing in 3a; it decides whether 3b's definition of done includes notarization or the README workaround.
- **Bundle id prefix.** Chosen once, permanently.
- **Icon artwork.** 3a ships a placeholder.
- Whether "Choose from Applications…" belongs in the game picker.
- **Does `AXIsProcessTrusted()` update within the process lifetime on macOS 26?** Check: launch a bundled build from `/Applications` that polls and prints on change, toggle the app's Accessibility checkbox in System Settings, watch whether the value flips without a relaunch. Yes removes the Relaunch button from onboarding; no keeps it.
- **Does a `MenuBarExtra(.window)` panel become key, and can it capture a key chord?** Check, in order: add a `keyDown` local monitor to the prototype, open the panel, press a chord, see whether the monitor fires; if it does not, put a first-responder `NSView` overriding `keyDown` and `performKeyEquivalent` in the panel and repeat. If neither fires, the chord ships fixed at `cmd+alt+L` and the changes table's conditional row applies. Deferring the recorder to 3b is not an option, since 3b keeps the same panel.
- **Is notarization necessary on top of a Developer ID signature?** Measured: unsigned and ad-hoc are rejected, and quarantine survives the DMG. Not measured: Developer ID signed but unnotarized. Check: sign one build with the certificate, do not notarize it, quarantine it, and run `spctl -a -vvv -t exec`.
- **Is Developer ID plus notarization plus stapling sufficient for the promised flow?** Check: on a second Mac with networking off, mount the stapled DMG, drag the app to Applications, open it, and see no warning. Offline is the part that tests stapling rather than Apple's servers.
- **Does a self-signed signature satisfy `SMAppService`'s code-signing requirement?** This is 3a's first acceptance gate rather than a background question: sign with the self-signed identity, call `agent.register()`, read `status`, and confirm `launchctl print gui/$UID/<label>` resolved `BundleProgram` inside the bundle. A refusal switches the watcher to the legacy `~/Library/LaunchAgents` job described above, which needs no signature and is verified to load. Either way 3a is incomplete until one of the two is registered, and the Hammerspoon lua stays until then; it is never the fallback, since it cannot see a Finder-launched app die.
