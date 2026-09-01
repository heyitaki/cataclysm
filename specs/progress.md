# Remaining work

The two design specs (`pointer-and-scroll.md`, `distribution-and-ui.md`) are implemented and deleted; recover them from git history if needed. Implementation landed on branch `cataclysm-distribution` (26 commits, unmerged as of 2026-09-01) via the ralphex run recorded in `docs/plans/completed/cataclysm-distribution.md`, whose Post-Completion section is the fuller version of the list below. `specs/evidence/verify.sh` is kept for the macOS floor pass: it re-checks the platform claims (Gatekeeper, iconutil, legacy launchd) the design relied on.

Everything below needs the user present; none of it is unattended-automatable.

| # | Item | Notes |
| --- | --- | --- |
| r.1 | Review and merge `cataclysm-distribution`, then push | Final review-fix commit 04321fb was verified by tests but not re-reviewed (iteration cap); glance at it during review |
| r.2 | Quit UnnaturalScrollWheels from its own menu, then uninstall | Its quit restores `HIDMouseAcceleration`; must happen before first Cataclysm launch with acceleration control on |
| r.3 | First live run: onboarding, Accessibility grant, confirm jail/acceleration/scroll in game | Also observe which watcher path went live: SMAppService may report the self-signed agent enabled without spawning it; a 10s spawn check then installs the legacy launchctl fallback |
| r.4 | Confirm bundle id `io.github.heyitaki.cataclysm` before first release | Cheap to change until real Accessibility grants exist, expensive after (TCC keys the grant to it) |
| r.5 | Hardware scroll measurement with `--dump-scroll` (wheel vs trackpad discriminator), then the manual per-app scroll matrix | The alternate trackpad detection setting ships off pending this |
| r.6 | GUI checks: which hotkey recorder mechanism works in the panel; whether `AXIsProcessTrusted()` updates without relaunch (decides removing onboarding's Relaunch button) | |
| r.7 | Remove two denied TCC rows for `com.example.assocprobe.never-granted` in System Settings (Accessibility, Input Monitoring); remove any stray Cataclysm row in Login Items left by an interrupted gate run | `tccutil` cannot delete rows |
| r.8 | Rename the GitHub repo `mousejail` to `cataclysm` | Old URL redirects |
| r.9 | Icon artwork to replace the generated placeholder | |
| r.10 | Developer ID membership decision: buy and notarize (`make release`, then the offline second-Mac install test), or ship `make dmg` with the README's Open Anyway walkthrough | This is all the $99 buys |
| r.11 | Floor and hardware passes: macOS 13 (panel rendering, deep links, agent registration, login item), Intel or Rosetta launch, grant-in-Applications-then-run-from-Downloads | |
