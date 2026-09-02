# Remaining work

Implementation merged to `main` as `cf186f8`, from the ralphex run recorded in `docs/plans/completed/cataclysm-distribution.md`. The two design specs (`pointer-and-scroll.md`, `distribution-and-ui.md`) were deleted on merge and live in git history. `specs/evidence/build/verify.sh` re-checks the platform claims (Gatekeeper, iconutil, legacy launchd) for the macOS floor pass.

Everything below needs the user present. None of it can run unattended.

| # | Item | Notes |
| --- | --- | --- |
| r.1 | Push `main` | Merge and its review fixes (`f201238`) are local only |
| r.2 | Quit UnnaturalScrollWheels from its own menu, then uninstall | Its quit restores `HIDMouseAcceleration`; must happen before first Cataclysm launch with acceleration control on |
| r.3 | First live run: onboarding, Accessibility grant, confirm jail/acceleration/scroll in game, in windowed, borderless and native fullscreen | Native fullscreen has never been observed, and the jail now releases on the AX fullscreen flag alone. Also observe which watcher path went live: SMAppService may report the self-signed agent enabled without spawning it, and a 10s spawn check then installs the legacy launchctl fallback |
| r.4 | Confirm bundle id `io.github.heyitaki.cataclysm` before first release | Cheap to change until real Accessibility grants exist, expensive after (TCC keys the grant to it) |
| r.5 | Hardware scroll measurement with `--dump-scroll` (wheel vs trackpad discriminator), then the manual per-app scroll matrix | The alternate trackpad detection setting ships off pending this |
| r.6 | GUI checks: which hotkey recorder mechanism works in the panel; whether `AXIsProcessTrusted()` updates without relaunch (decides removing onboarding's Relaunch button) | |
| r.7 | Remove two denied TCC rows for `com.example.assocprobe.never-granted` in System Settings (Accessibility, Input Monitoring); remove any stray Cataclysm row in Login Items left by an interrupted gate run | `tccutil` cannot delete rows |
| r.8 | Remove the stale `mousejail` repo card from the Orca UI | Left over from the repo rename, which is done. Orca has no CLI for the removal |
| r.9 | Icon artwork to replace the generated placeholder | |
| r.10 | Developer ID membership decision: buy and notarize (`make release`, then the offline second-Mac install test), or ship `make dmg` with the README's Open Anyway walkthrough | This is all the $99 buys |
| r.11 | Floor and hardware passes: macOS 13 (panel rendering, deep links, agent registration, login item), Intel or Rosetta launch, grant-in-Applications-then-run-from-Downloads | |

## Known low-severity issues, from the merge review

Left unfixed deliberately; none blocks use. Worth revisiting if the symptom shows up.

- The 0.5s jail refresh and both tap callbacks share the main run loop, so Accessibility reads against a hung game (a few hundred ms) can stall scroll delivery and let the scroll tap disable by timeout until the next tick re-enables it.
- If `mach_timebase_info` ever failed, the ticks-to-seconds factor would be NaN and per-axis scroll residue would never reset at the 250ms burst gap.
- `--dump-scroll` prints inside the tap callback (allocation plus blocking I/O on the timed path); debug flag only.
- `TapHost.swift` has no direct test coverage: the timebase conversion, the capture-before-write ordering, and the flatten pairing are exercised only by hand.
- `legacyWatcherCurrent()` cannot distinguish the two mechanisms (they share one launchd label), so it can report the legacy job current when the hollow SMAppService job is what launchd holds.
- After the spawn probe installs the fallback, the BTM record can return to enabled while the legacy plist stays on disk, so both registrations exist at once on ordinary launches. Nothing depends on only one being present, and no command clears the extra one now that "Reset everything and quit" is gone.
- `bootOutLegacyWatcher()` returns success without booting out when the plist is missing, so a job loaded under the shared label with no file could block `register()`.
- `recovery.originalMouseAcceleration` is a string literal in `PointerAccel.swift` that `Settings.swift` only knows by its `recovery.` prefix (the rule that spares it from reset); no test links the two.
- `Settings.Key.all` is hand-maintained: a future key omitted from it would be silently skipped by "Reset to defaults".
