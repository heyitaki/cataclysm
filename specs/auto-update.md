# In-app updates

Decided 2026-09-01; re-decided 2026-09-02 around Sparkle. Cataclysm updates itself over the air with [Sparkle 2](https://sparkle-project.org): it checks an appcast on a six-hour schedule, downloads and verifies a newer build in the background, and installs it when no game is running. The "Check for updates…" row in the panel runs the same machinery on demand. No Developer ID is needed; the roots of trust are the self-signed `Cataclysm` certificate the app is already signed with and an EdDSA key that Sparkle's tools generate.

Depends on the website plan (`specs/cataclysm-website.md`) only for the first public release (w.6). The feed is a GitHub release asset, so no Worker route is involved.

Every platform claim below was measured on 2026-09-02 unless it is listed under "Unverified claims"; the probe is `.claude/pairs/auto-update-spec/evidence/sparkle-probe.sh` (gitignored, with its transcript beside it; evidence stays out of the repo by the user's call) and the results are summarised under "Measured facts".

## Why Sparkle, and not a hand-rolled updater

The previous version of this spec built the updater from Foundation and Security framework calls: feed fetch, capped download, extraction inside a sparse disk image to bound archive bombs, `SecStaticCodeCheckValidity` against a captured designated requirement, `renamex_np` swap, a relaunch helper that waits for the old pid. About four hundred lines of spec, most of it security-sensitive install-path edge cases, plus two test harnesses whose job was to cover what the signature check does not.

Sparkle already does all of that and has been hardening it in public for fifteen years: appcast parsing and version comparison, background download, archive extraction, EdDSA and code-signature verification of the unpacked bundle, quarantine release, ownership matching, an atomic `renamex_np` swap, a helper that waits for the host to exit before swapping and relaunching, and install-on-quit. It is the updater behind most non-App-Store menu bar utilities. Owning that surface ourselves was the expensive part, and it bought nothing Sparkle does not provide.

What the old objections cost in practice, measured: embedding the framework in the raw `swiftc` build is a `-F`, a `-framework`, an rpath flag, one `ditto`, and four `codesign` lines. The dialogs go away because Sparkle 2 takes a custom `SPUUserDriver`, so every callback lands in panel state and nothing is ever shown by Sparkle itself. The one real cost is a 2.6 MB framework inside the bundle.

## Trust model

Sparkle validates a downloaded update against the *running* app with two independent anchors, from `SUUpdateValidator.m`:

- **EdDSA.** The archive's `sparkle:edSignature` in the appcast must verify against the `SUPublicEDKey` in the running app's `Info.plist`. This binds the exact bytes of the archive to the private key on the release Mac.
- **Code signing.** The unpacked bundle must satisfy the running app's designated requirement (`SecCodeCopyDesignatedRequirement` of the old bundle, checked with `kSecCSCheckAllArchitectures | kSecCSCheckNestedCode`). For Cataclysm that requirement is `identifier "io.github.heyitaki.cataclysm" and certificate leaf = H"<sha1 of the Cataclysm certificate>"`, and a self-signed keychain identity satisfies it like any other; nothing in Sparkle requires an Apple anchor.

An update is accepted when **either** anchor holds, and it is always rejected when the old app is code signed and the new bundle is not, or when the EdDSA check passes but the new bundle's own signature is broken. This is Sparkle's stated policy: either root of trust can be rotated, one at a time, without stranding installed copies, and neither can be removed.

Consequences:

- **Both private keys are roots of trust.** The `Cataclysm` identity's private key in the login keychain, and the EdDSA private key that `generate_keys` stores there. Each needs an offline backup. Losing one is survivable only while the other still works.
- **The certificate expiry trap is defused for the updater, not for Accessibility.** The `Cataclysm` certificate expires 2027-09-01; the previous spec measured that a bundle signed while it was valid still verifies afterwards, but no new release can be signed with it. After that date a new certificate has a new leaf hash, so the code-signing anchor fails, but the EdDSA anchor still passes and installed copies keep updating. What does not survive is the Accessibility grant, which TCC keys to the code requirement: every user re-grants once, on the first launch after the certificate changes. That is why u.0 (a long-lived certificate before the first public release) is still recommended, but it is a one-time re-grant across the fleet now, not a manual reinstall, and it no longer blocks w.6.
- **The feed and the download must be `http` or `https`.** Sparkle rejects a `file:` feed URL outright (measured: "The download request URL must use http or https"). Cataclysm sets no App Transport Security exception, so in practice the released feed is `https:`; the loopback `http://127.0.0.1` case used for testing is the only plaintext one, and it was measured to work.
- **Sparkle's code-signing check is not strict**, in the `kSecCSStrictValidate` sense the old spec insisted on. That matters only for a bundle with bytes appended after its signature, which fails the EdDSA anchor anyway because the archive bytes changed. Both anchors sit behind TLS to `github.com`.

## Release artifacts and the feed

`make dmg` produces, as today, `build/Cataclysm-<version>.dmg`, and additionally `build/Cataclysm-<version>.zip` (via `ditto -c -k --keepParent`, measured by the previous spec to preserve the signature, nested code and symlinks) and `build/Cataclysm.dmg`, a byte-identical copy of the DMG under a version-stable name for the website plan's fallback redirect.

`make appcast` runs `build/sparkle/bin/generate_appcast` over a staging directory holding only that zip, with `--download-url-prefix https://github.com/heyitaki/cataclysm/releases/download/v<version>/`, `--maximum-deltas 0`, and `--link https://akshath.me/cataclysm`, writing `build/appcast.xml`. It reads the EdDSA private key from the login keychain (Sparkle's own item, account `ed25519`), so it can raise a keychain prompt and is a user-present release step rather than part of `make dmg`. Each release gets a fresh single-item appcast: Sparkle only needs the newest item, deltas are a non-goal, and a cumulative appcast would need the previous one fetched back into the staging directory first. `generate_appcast` reads `LSMinimumSystemVersion` (13.0) and the architecture slices from the bundle and writes them into the item, so a user on an older macOS is never offered a build that will not run.

Every release carries four assets: `Cataclysm-<version>.dmg`, `Cataclysm.dmg`, `Cataclysm-<version>.zip`, `appcast.xml`. The `.zip.sha256` asset from the previous version of this spec is gone; the appcast's `length` and `sparkle:edSignature` cover it.

`SUFeedURL` is `https://github.com/heyitaki/cataclysm/releases/latest/download/appcast.xml`. GitHub redirects that path to the asset of that name on the newest non-prerelease, non-draft release with no API call (a fact the website plan records), and Sparkle follows redirects. The URL depends on nothing but the release existing, which is why it is preferred over a route on `akshath.me`: an update needs no Worker to be up, and a Worker route (for counting update checks, say) can be added later and switched to by shipping one update whose plist names it. A release that forgets the appcast asset makes the feed 404, which Sparkle reports as a check error and the panel shows only on a manual check.

Versions are `CFBundleVersion` (`major.minor.patch`, the same string as `CFBundleShortVersionString` in this build), compared by Sparkle's `SUStandardVersionComparator`, which is numeric per component: `0.10.0` is newer than `0.9.0`.

## Build

Sparkle is fetched, not vendored. The Makefile pins `SPARKLE_VERSION = 2.9.6` and `SPARKLE_SHA256 = 52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192`, and a rule for `build/sparkle/Sparkle.framework` downloads `https://github.com/sparkle-project/Sparkle/releases/download/$(SPARKLE_VERSION)/Sparkle-$(SPARKLE_VERSION).tar.xz`, refuses to continue when the digest does not match, and extracts the framework and `bin/` tools. The download happens once per `make clean`; there is no CI in this repo to keep offline.

Compile and link, on both slices and on `typecheck`: `-F build/sparkle -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks` (`typecheck` needs only the `-F`). The framework is universal, so the x86_64 slice links against the same copy.

Bundle assembly, after the executable is copied in:

1. `ditto build/sparkle/Sparkle.framework $(APP)/Contents/Frameworks/Sparkle.framework`.
2. `rm -rf .../Sparkle.framework/Versions/B/XPCServices`. The XPC services exist for sandboxed apps; Cataclysm is not sandboxed, and Sparkle's documentation says to remove them in that case. This takes the framework from 3.0 MB to 2.6 MB.
3. Re-sign, because the distributed framework is ad-hoc signed (measured: `Signature=adhoc` on the framework and on `Autoupdate`) and an ad-hoc nested binary fails a strict deep verification of the app. In this order, per Sparkle's sandboxing guide, which is explicit that `--deep` is not the way: `Versions/B/Autoupdate`, `Versions/B/Updater.app`, then the framework itself, each with `codesign -f -s "$(IDENTITY)"`.
4. Sign the app as today, and verify with `codesign --verify --strict --deep`, so a mis-signed nested component fails the build rather than the first launch.

**`--options runtime` is dropped from the app signature.** The hardened runtime enables library validation, and library validation refuses a framework whose signer has a different Team ID from the process. A self-signed identity has no Team ID at all, and dyld treats "none" and "none" as different: the probe's hardened build refused to load the re-signed framework with `mapping process and mapped file (non-platform) have different Team IDs` (measured). Two fixes were measured to work: signing without the hardened runtime, and keeping it with the `com.apple.security.cs.disable-library-validation` entitlement. The first is chosen. The Makefile comment says the flag is there for notarization, which the website plan has retired; a hardened runtime whose only effect is an entitlement that switches its main protection off is not worth a line. If a Developer ID ever returns, restore the flag and re-sign the framework with the same team, and no entitlement is needed.

`packaging/Info.plist.in` gains:

| Key | Value | Why |
| --- | --- | --- |
| `SUFeedURL` | the `releases/latest/download/appcast.xml` URL above | primary feed |
| `SUPublicEDKey` | the base64 public key from `generate_keys` | EdDSA anchor; public, so it is committed |
| `SUEnableAutomaticChecks` | `true` | background checks on, and Sparkle's second-launch permission dialog never appears |
| `SUAutomaticallyUpdate` | `true` | default for "Install updates automatically" |
| `SUScheduledCheckInterval` | `21600` | six hours; Sparkle's floor is one hour |

Measured: with those three keys, the updater starts with automatic checks on, automatic downloads on, the interval at 21600 s, and no permission request reaching the user driver.

A local build made before the public key exists in the plist starts the app fine, but the updater's `start()` fails; see "Panel" for what the row shows then. The key is generated once in u.1, before any of the app-side work lands.

## Pipeline

Sparkle owns the state machine. The app supplies two objects and one rule.

**The user driver** (`SPUUserDriver`, implemented on the main actor next to the runtime) turns Sparkle's sixteen callbacks into a published `AppState.update` value the panel renders. The probe implemented the whole protocol in forty lines and drove a check, a download, an extraction and a rejection through it with nothing on screen.

**The delegate** (`SPUUpdaterDelegate`) supplies the feed override for testing and the two hooks that keep a game from being interrupted.

**The idle rule** decides whether this is a safe moment to install and relaunch. It holds when all of these do:

- the picked game is not running (no `NSRunningApplication` with the target bundle id; when the target is `(none)`, always true);
- the panel is closed, unless the trigger was a manual click;
- the app is not showing onboarding, and the launch was not stopped by the install-location gate.

A relaunch drops the jail and the pointer settings for about a second, which mid-game is the one moment the app must not do it. A click is permission, never an instruction to interrupt a game, so no click bypasses the first condition.

The states, and what produces them:

| State | Meaning | Produced by |
| --- | --- | --- |
| `idle` | Nothing in flight | initial; the end of any cycle |
| `checking` | Feed fetch in progress | `showUserInitiatedUpdateCheck` on a manual pass; a background pass never shows this |
| `upToDate` | A manual check found nothing. Transient | `showUpdateNotFoundWithError` on a manual pass; cleared when the panel closes or after ten seconds |
| `available(version)` | Newer version, not downloaded, because automatic downloads are off | `showUpdateFound` with stage `notDownloaded` on a background pass |
| `downloading(version)` | Transfer and extraction | `showDownloadInitiated` through `showExtractionReceivedProgress` |
| `ready(version)` | Verified and staged; waiting for the idle rule or a click | `showReadyToInstallAndRelaunch` (manual pass) or `willInstallUpdateOnQuit` (background pass) |
| `installing` | Sparkle's helper has taken over; the app is about to exit | `showInstallingUpdate` |
| `failed(error, manual)` | The last pass failed; shown only when it was manual | `showUpdaterError` |

Triggers:

- **Launch and the six-hour timer.** Sparkle's scheduler, started from `start()` after `registerAgentsIfNeeded()` so a slow network never delays the features. Timers do not fire while the Mac sleeps; a machine that sleeps through a window checks on the next wake.
- **Manual.** The row calls `checkForUpdates()`, a user-initiated check that ignores the cadence. Sparkle's `canCheckForUpdates` is false while a session is in flight; the row is disabled then.
- **Game quit.** The existing `NSWorkspace.didTerminateApplicationNotification` handler (`CataclysmApp.swift:238`), which today only rebuilds the game picker, also calls the re-evaluation point when the terminated app is the picked game. A 60 s grace period, re-checking the conditions at its end, so a game that crashes and is relaunched is not interrupted.
- **Panel close, onboarding close, toggle change.** Each calls the re-evaluation point.

**One re-evaluation point.** Everything that can unblock a waiting install calls the same function, which re-reads the idle rule and, if it holds and an install is waiting, invokes whatever Sparkle handed us to continue with. There are two such handles, one per path:

- *Background path.* With automatic downloads on, Sparkle downloads silently and then calls `updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)`. The delegate returns `true` and stores the block; the state becomes `ready`. Per Sparkle's contract, returning `true` stalls the update cycle until the block is invoked, and Sparkle installs the update at quit regardless. So a staged update installs at the first idle moment, or at the next quit, whichever comes first, and if the app crashes in between Sparkle finds the staged update and resumes on the next launch. Nothing is persisted by the app.
- *Manual path.* The click is consent. `showUpdateFound` (stage `notDownloaded`, `userInitiated` true) is answered with `.install` at once; `showReadyToInstallAndRelaunch(reply:)` is answered with `.install` when the idle rule holds, and otherwise the reply block is stored and the state is `ready` with the label saying what it is waiting for.

The final gate is `updater(_:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)`: it fires immediately before Sparkle terminates the app to swap and relaunch, and the delegate returns `true` and holds the handler whenever the picked game is running at that instant, invoking it from the re-evaluation point. This covers a game launched between the click and the relaunch, which the previous spec needed a separate `installedPendingRelaunch` state for.

**Consent.** The Advanced page gains "Install updates automatically", bound to `updater.automaticallyDownloadsUpdates`. Sparkle persists that property in the app's own UserDefaults under `SUAutomaticallyUpdate`, and its header says not to keep a parallel key, so the toggle reads and writes the property and nothing else. `SUAutomaticallyUpdate` is added to `Settings.Key.all` so "Reset to defaults" removes it and Sparkle falls back to the plist default of on. With the toggle off, a background pass reaches `showUpdateFound` with `userInitiated` false and the driver answers `.dismiss` (not `.skip`, which would suppress that version for good), leaving `available`; a click on the row then runs a manual pass, which is consent. Sparkle samples the property when it decides whether to download, so flipping the toggle mid-cycle behaves the way the previous spec's consent table demanded without any code in the app: a download already in flight finishes and the staged bundle waits.

## Panel

The row replaces the current "Check for updates…" item (`CataclysmApp.swift:1197-1202`), which opens the GitHub releases page. The website plan's w.5a repoints that same row at `akshath.me/cataclysm` as an interim step; u.6 supersedes it, and whichever lands second wins.

`MenuRow` is always a button (`CataclysmApp.swift:1593`), so a non-clickable row is a `MenuRow` with `.disabled(true)`.

| State | Label | Row |
| --- | --- | --- |
| `idle` | Check for updates… | checks |
| `checking` | Checking for updates… | disabled |
| `upToDate` | Cataclysm is up to date | checks again |
| `available` | Update to 0.2.0… | starts a manual pass |
| `downloading` | Downloading 0.2.0… | disabled |
| `ready`, game not running | Restart to update to 0.2.0 | invokes the stored handle |
| `ready`, game running | Update ready; waiting for <game> to quit | disabled |
| `installing` | Updating… | disabled |
| updater failed to start | Cataclysm cannot verify updates in this copy | disabled |

The last error, when it came from a manual pass, appears under the row through the existing `errorRow` (`CataclysmApp.swift:1273`) as "Could not check for updates" or "Could not verify the update; download it from the website", and clears on the next successful check. Background failures are recorded but not shown, so a flaky network never leaves a stale message under an item the user did not touch. No menu bar icon badge.

**Panel-open tracking does not exist yet.** `PanelView` has an `.onAppear` at `CataclysmApp.swift:1127` and no `.onDisappear` on its root. u.5a adds `AppState.panelOpen` from a matching pair. If `.onDisappear` ever fails to fire, the cost is that a staged update waits for the next quit instead of installing while the panel is "open"; Sparkle's install-on-quit is the floor, so the previous spec's ten-minute staleness timer is dropped.

## Install and relaunch

Sparkle's `Autoupdate` helper, launched from inside the embedded framework, waits for the app to terminate, then (from `SUPlainInstaller.m`) copies the new bundle next to the old one on the same volume, matches the old bundle's owner and group, releases quarantine on every file in it, and swaps the two directories with `renamex_np(RENAME_SWAP)`, so the install path holds a complete bundle at every observable moment. Then it relaunches. Because the swap happens only after the old process has exited, the instance lock (`Startup.swift:31`, released by the kernel at exit) is free before the new copy starts, and the half-second race in the current relaunch helper does not apply. `AppRuntime.relaunch()` (`CataclysmApp.swift:952`) stays as it is for the onboarding button; the updater never calls it.

The install target is wherever the user put the app. If that is on `/Volumes` or under app translocation, the existing install gate (`isBlockedInstallLocation`, `Startup.swift:73`) has already stopped the app in `preflight`, and the updater never starts. If the parent directory is not writable, Sparkle fails the install with its own error, which the panel shows on a manual pass; there is no privilege escalation anywhere in this path.

First launch of the new version: the watcher's version gate sees the changed version and re-registers the login agent, with the same 10 s probe window every version bump already has (`pollLaunchctlPrint`, `Watcher.swift:136`). The Accessibility grant survives because the designated requirement is unchanged. The old watcher keeps running its deleted executable until launchd stops it, and its only side effect is an idempotent cursor release.

Sparkle's staged download lives under `~/Library/Caches/io.github.heyitaki.cataclysm/org.sparkle-project.Sparkle/` (measured); Sparkle manages and cleans it.

## Failure handling

- Feed unreachable, 404, or malformed: Sparkle reports an error to the driver; `failed`, shown only on a manual pass; next check at the normal cadence.
- Download, extraction or validation failure: Sparkle deletes its working files; `failed` as above. The probe drove the validation failure path end to end: with a mismatching key the driver received error 4005, "The update is improperly signed and could not be validated", and nothing was installed.
- Updater fails to start (no public key in the plist, or Sparkle's own configuration check fails): the row is disabled with "Cataclysm cannot verify updates in this copy"; the rest of the app is unaffected.
- Install fails after the app has quit: Sparkle's helper restores the old bundle; the next launch is the old version and the next cycle retries.
- The updater never launches a downloaded bundle before installing it and never elevates privileges.

## Testing

Two layers, as the repo has today (`Makefile:118-150`: every unit harness links one pure module plus its test file, and `CataclysmApp.swift` is compiled only by `make typecheck`). Sparkle's own transport, archive and verification paths are tested upstream and are not re-tested here.

**`UpdatePlan.swift` (Foundation only), `tests/UpdatePlanTests.swift`, `build/updateplan-tests`.** The pure decisions, following the `check`/`checkEq` pattern of `PanelMath.swift` / `tests/PanelMathTests.swift`:

- the idle rule from `(targetRunning, panelOpen, screen, pass)`, where `screen` is `normal`, `onboarding` or `blockedInstallLocation` and `pass` is `background` or `manual`;
- the driver's reply for `showUpdateFound` from `(stage, userInitiated, automaticDownloads)`: `.install` on a manual pass, `.dismiss` on a background pass with downloads off, and the state each produces;
- the row label and enabled flag for every state, including `ready` with and without the game running;
- error attribution: which pass produced an error, and therefore whether the row shows it;
- the 60 s grace decision from the terminated app's bundle id and the target.

**Hand test (u.7).** `Updater.swift` links Sparkle and lives in the app, so its remaining surface is exercised against the live app. The delegate's `feedURLStringForUpdater` returns `update.feedURLOverride` (a UserDefaults key outside `Key.all`) when it is set. Sparkle refuses `file:` feeds, so the test serves a directory with `python3 -m http.server --bind 127.0.0.1` and points the override at `http://127.0.0.1:<port>/appcast.xml`, which was measured to work. The override is not a security hole worth closing: anyone who can write the app's preferences can already replace the app, and both anchors still gate every install.

The test: build two versions locally with `make app` at different `VERSION`s, sign both with `Cataclysm`, run `make appcast` for the newer one with the download prefix pointed at the loopback server, install the older one in `/Applications`, and watch the swap. Then the rejection cases: an appcast signed with a different EdDSA key (`generate_keys --account throwaway` keeps it out of the real item) against a bundle signed by a second throwaway certificate, so both anchors fail; and an ad-hoc signed bundle. Then the game-running case, the Accessibility grant after the swap, and the unverified claims below. Never run this against the installed copy from an unattended loop.

## Measured facts

Measured on macOS 26.3 (25D2125), Swift 6.3.3, arm64, Sparkle 2.9.6, on 2026-09-02 with `.claude/pairs/auto-update-spec/evidence/sparkle-probe.sh`. Throwaway bundles in the scratch directory signed with the real `Cataclysm` identity, a loopback HTTP server, no other network; the probe's UserDefaults domain and cache directory were deleted afterwards. An executing session may rely on these:

**Distribution and embedding**

- `Sparkle-2.9.6.tar.xz` (15,554,568 bytes, sha256 `52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192`) unpacks to `Sparkle.framework`, `bin/{generate_keys,generate_appcast,sign_update,BinaryDelta}`, `CHANGELOG`, `SampleAppcast.xml` and a test app. `github.com/sparkle-project/Sparkle/releases/latest/download/Sparkle-2.9.6.tar.xz` 302s to the versioned asset.
- The framework is universal (x86_64, arm64), declares `LSMinimumSystemVersion` 10.13, and is 3.0 MB with its XPC services and 2.6 MB without.
- The framework and its `Autoupdate` helper ship ad-hoc signed (`Signature=adhoc`, no authority).
- A raw `swiftc` build with `-F <dir> -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks`, the framework copied to `Contents/Frameworks` with `ditto`, XPC services removed, `Autoupdate`, `Updater.app`, the framework and the app signed with `Cataclysm` in that order, passes `codesign --verify --strict --deep`.
- Signed with `-o runtime`, that app fails at launch: dyld refuses the framework with "code signature ... not valid for use in process: mapping process and mapped file (non-platform) have different Team IDs". Signed without `-o runtime` it launches; signed with `-o runtime` plus the `com.apple.security.cs.disable-library-validation` entitlement it also launches.

**Runtime behaviour**

- `SPUUpdater(hostBundle:applicationBundle:userDriver:delegate:)` with a custom `SPUUserDriver` and a nil delegate starts (`start()` does not throw) with a 32-byte base64 `SUPublicEDKey`.
- With `SUEnableAutomaticChecks=false` in the plist: `automaticallyChecksForUpdates` false, `automaticallyDownloadsUpdates` false, interval 86400. With `SUEnableAutomaticChecks=true`, `SUAutomaticallyUpdate=true`, `SUScheduledCheckInterval=21600`: true, true, 21600, and the driver's permission-request callback is never called.
- A `file:` `SUFeedURL` is rejected at check time: "The download request URL must use http or https".
- An `http://127.0.0.1:<port>/appcast.xml` feed is fetched without an ATS exception. A user-initiated check drove `showUserInitiatedUpdateCheck`, then `showUpdateFound` (stage `notDownloaded`, `userInitiated` true), then, on `.install`, `showDownloadInitiated`, `showDownloadDidStartExtractingUpdate`, and finally `showUpdaterError` with code 4005 wrapping 3002 (public key mismatch), then `dismissUpdateInstallation`. Nothing was displayed by Sparkle at any point.
- Sparkle writes `SULastCheckTime` to the host's UserDefaults domain and stages under `~/Library/Caches/<bundle id>/org.sparkle-project.Sparkle/`.

**From Sparkle's source (2.x branch, read 2026-09-02, not executed)**

- `SUUpdateValidator.m`: an update passes when the EdDSA signature validates against the old public key or the new bundle satisfies the old bundle's designated requirement; it fails when the old app is signed and the new is not, when the old app has an EdDSA key and the new has none, or when EdDSA passes but the new bundle's own signature is invalid.
- `SUCodeSigningVerifier.m`: the match check uses `SecCodeCopyDesignatedRequirement` of the old bundle and `kSecCSCheckAllArchitectures` (optionally `kSecCSCheckNestedCode`); the Apple-anchor requirement (`anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] ...`) lives only in the Developer-ID team-match fallback and is not on Cataclysm's path.
- `SUPlainInstaller.m` and `SUFileManager.m`: same-volume copy, owner and group matched to the old bundle, recursive quarantine release, `renamex_np(RENAME_SWAP)`, no privileged helper.

**Carried over from the previous spec's measurements** (its scripts are no longer in the tree; the facts stood on their own): a bundle signed while the `Cataclysm` certificate was valid still verifies after expiry, but nothing new can be signed with it; `ditto -c -k --keepParent` round-trips a signed bundle intact; `ditto -x -k` propagates `com.apple.quarantine` from a quarantined archive; `renamex_np(RENAME_SWAP)` is atomic and fails with EXDEV across volumes; a running process survives the replacement and deletion of its own bundle.

## Unverified claims

Each names the check that settles it. None blocks implementation.

- **The stalled cycle and a manual click.** Returning `true` from `willInstallUpdateOnQuit` "prevents future update cycles from running". The panel's `ready` row invokes the stored block directly and never needs a check, so this only matters if something else expects `checkForUpdates()` to work while an install is staged. Settled by u.7: click the row in `ready`, and separately call `checkForUpdates()` from a debug hook while staged.
- **Resume after a crash with an update staged.** Sparkle's header says a downloaded, deferred update "may be activated with the update resumed at a later point". Whether that arrives as a second `willInstallUpdateOnQuit` on the next launch is not measured. Settled by u.7: kill the app in `ready`, relaunch, and watch which callback fires.
- **Whether Sparkle shows its own progress window during a manual install.** `Updater.app` inside the framework exists to show install progress, and the flag that enables it is set inside Sparkle's driver, not by the user driver. Settled by u.7 by looking; if it appears, u.6 decides whether to keep it.
- **Whether an ad-hoc signed bundle is "unsigned" to Sparkle.** `bundleAtURLIsCodeSigned` reports unsigned on `errSecCSUnsigned`; whether ad-hoc code takes that branch was not measured. Either way the ad-hoc bundle fails both anchors. Settled by u.7's rejection case.
- **The x86_64 slice.** The probe built arm64 only. Settled by `make app` on u.2, which builds and lipos both.
- **Whether the Accessibility grant survives the swap.** The reasoning is that TCC stores the code requirement and the requirement is unchanged. Settled by u.7.
- **`SMAppService` re-registration after an in-place replacement.** The version gate has always run on a fresh launch of a newly installed bundle, which is what this is. Settled by u.7 and u.8.
- **The macOS 13 floor.** Everything was measured on macOS 26.3. Sparkle 2.9.6 declares 10.13. The floor pass in `specs/progress.md` r.11 should include one update.

## Hostile fixtures and what catches them

| Fixture | Outcome |
| --- | --- |
| Archive tampered after signing | EdDSA fails; code-signing anchor fails too because the bundle's seal is broken |
| Bundle signed by a different identity, EdDSA valid | Accepted (Sparkle allows certificate rotation); Accessibility re-grant follows. This is the u.0 trade |
| Bundle signed by the same identity, EdDSA missing or wrong | Accepted on the code-signing anchor. The appcast is always generated signed, so this only arises by mistake |
| Both anchors fail (probe's case) | Rejected, error 4005 |
| Ad-hoc signed bundle | Rejected: fails both anchors |
| Feed serves an older or equal version | Not newer, no update |
| Feed 404 (appcast asset forgotten) | Check error; shown only on a manual pass |
| Feed or enclosure over plaintext `http` to a real host | ATS refuses; the loopback exception is only reachable through the debug override |
| Archive bomb | Sparkle's extraction; not re-tested here |
| Disk full during install | Sparkle's helper fails the install and restores the old bundle |
| Install directory not writable | Sparkle's error, shown on a manual pass; no privilege escalation |
| App on `/Volumes` or translocated | The install gate already refused to run |
| Game launched during the 60 s grace | Re-checked at the end of the grace period |
| Game launched between the click and the relaunch | `shouldPostponeRelaunchForUpdate` holds the relaunch until the game quits |
| User clicks the row while the game is running | The row is disabled in `ready`; a click in `idle` only starts a check |
| Toggle turned off mid-download | Sparkle finishes the download and stages it; it installs at quit or on a click |
| Panel `.onDisappear` never fires | Staged update installs at the next quit |
| App quit from the panel with an update staged | Sparkle installs on quit, no relaunch |
| App crashes with an update staged | Sparkle resumes on the next launch (unverified, above) |
| Second instance launched by the user during install | The instance lock refuses it, as today |
| Watcher still running the old executable | Harmless; the new app re-registers the job |
| Certificate expired at release time | Cannot sign; u.0 removes the cliff. Installed copies keep verifying |
| Sparkle tarball replaced upstream | The pinned digest fails the build |

## Non-goals

Delta updates, rollback after a bad launch, beta channels (Sparkle supports them; nothing here needs them yet), release notes in the panel, counting update checks, and sandboxing.

## Known issues

- The bundle grows by 2.6 MB.
- The build needs network once after `make clean` to fetch Sparkle.
- `make appcast` needs the login keychain and can prompt; it is a release step, not a build step.
- Two private keys to back up instead of one.
- A machine that sleeps through its six-hour window checks late, on the next wake.
- Sparkle 2.9.6 is pinned; bumping it is a Makefile edit plus a re-run of the probe.

## Amendments to the website plan

Applied directly to `specs/cataclysm-website.md` on 2026-09-02: the `/latest.json` route and its digest lookup are gone from w.1, w.1a, the routes list and the download-counting paragraph; the release asset contract lists `appcast.xml` instead of `.zip.sha256` and names u.3 as the producer; w.5a's line reference is corrected; w.6 is gated on u.1 and u.3 (the public key, the zip and the appcast) rather than u.1 and u.2, with u.0 recommended before it rather than blocking it.

**Applied to the ralphex run plan** at `docs/plans/cataclysm-website.md` on 2026-09-02, by the run itself when it reached the dropped task; it had been authored from the pre-Sparkle version of this spec and launched before this amendment landed. What was stale in it: its "When done" line and design pointer still describe `/cataclysm/latest.json` and "the `/latest.json` resolution rules and the zip/sha256 producer" in this spec, which no longer exist; Task 2 (Worker `/latest.json`, u.2 and u.2a) is dropped entirely, including its live curl check; the Makefile task's `.zip.sha256` output and its `make dmg` expectations become the zip, the stable DMG and a separate `make appcast`, per u.3; the final release step confirms `releases/latest/download/appcast.xml` instead of `/latest.json`, and u.0 precedes it as a recommendation, not a gate.

## Queue

| # | Item | State | Notes |
| --- | --- | --- | --- |
| u.0 | Replace the `Cataclysm` signing identity with a long-lived one (twenty years) and back up the private key offline | not started | User present. Recommended before website plan w.6, no longer blocking it: with Sparkle the EdDSA anchor keeps installed copies updating across a certificate change, so the cost of deferring is one Accessibility re-grant per user, not a reinstall. Costs one re-grant on the development Mac now |
| u.1 | EdDSA key: `build/sparkle/bin/generate_keys` once, `generate_keys -x` to an offline backup, public key into `packaging/Info.plist.in` as `SUPublicEDKey` alongside `SUFeedURL`, `SUEnableAutomaticChecks`, `SUAutomaticallyUpdate`, `SUScheduledCheckInterval` | not started | User present (keychain prompt). Blocked on u.2 for the tools; blocks u.5 and w.6. The private key never enters the repo, a log, or the transcript |
| u.2 | Makefile: pinned Sparkle fetch with digest check, `-F`/`-framework`/rpath on both slices and `typecheck`, framework embedded with XPC services removed and the four-step re-sign, `--options runtime` dropped, `codesign --verify --strict --deep` | not started | Blocked on nothing. Update the Makefile's signing comment, which currently justifies the hardened runtime by notarization |
| u.3 | `make dmg` also emits `Cataclysm-<version>.zip` and a byte-identical `Cataclysm.dmg`; new `make appcast` target; README release section lists the four assets and the two commands | not started | Blocked on u.2. `make appcast` stays out of `make dmg` because it needs the keychain |
| u.4 | `UpdatePlan.swift` + `tests/UpdatePlanTests.swift` + `build/updateplan-tests` in `make test` | not started | Tests first. Pins the five decision groups under "Testing" |
| u.5 | `Updater.swift`: `SPUUpdater` started after agent registration, the user driver publishing `AppState.update`, the delegate (feed override, `willInstallUpdateOnQuit`, `shouldPostponeRelaunchForUpdate`), the idle rule and re-evaluation point, the game-quit trigger with grace period in the existing terminate handler, the Advanced toggle bound to `automaticallyDownloadsUpdates`, `SUAutomaticallyUpdate` in `Key.all` | not started | Blocked on u.1, u.2, u.4 and u.5a. Touches the same files as website plan w.5 telemetry; land after it or in the same change |
| u.5a | `AppState.panelOpen` from a matching `.onAppear`/`.onDisappear` pair on the panel root | not started | Blocked on nothing |
| u.6 | Panel: state-driven row replacing the releases-page link, `errorRow` under it for manual-pass errors only, the disabled "cannot verify updates" row when the updater failed to start | not started | Blocked on u.5. Supersedes website plan w.5a |
| u.7 | Hand test: two local builds over a loopback feed, swap observed, game-running case, Accessibility grant, wrong-key and ad-hoc rejections, and the eight unverified claims settled | not started | User present. Blocked on u.3, u.5, u.5a, u.6 |
| u.8 | First real OTA: release N+1 after w.6, confirm an installed N updates itself | not started | User present. Blocked on u.7 and website plan w.6 |
