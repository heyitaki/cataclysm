# Implementation progress

Durable queue for building `pointer-and-scroll.md` and `distribution-and-ui.md`, per the adoption decision in `.claude/pairs/distribution-ui-spec/report.md` (an untracked run directory: the specs and `specs/evidence/` are the durable artifacts; the report adds only round history and the adoption rationale). One row per item; update state here as work lands, and reconcile the session task list against this file at session start and after compaction.

States: `not-started`, `in-progress`, `blocked(<reason>)`, `done`, `needs-user`.

| # | Item | Spec | State |
| --- | --- | --- | --- |
| 0.1 | Split `main.swift` into modules (`Jail.swift`, `TapHost.swift`), no behavior change, still CLI under Hammerspoon, binary still `mousejail` | pointer-and-scroll phase 0 | blocked(session mousejail-73 is actively iterating on main.swift's jail clamp with the user and installing builds; it will message when stable. Its guidance: rounded-rect Clamp type, --corner-radius flag, and the unconditional warp in the callback are load-bearing; do not touch main.swift or add files to the Makefile's $(BINARY) target until cleared) |
| 0.2 | Scroll rewrite pipeline as a pure function (`ScrollFilter.swift`) plus the table-driven test harness, all 12 spec cases green | pointer-and-scroll phase 0 + Testing | done(`make test`: 66 passed 0 failed after the /selfreview hardening pass — coherence guard, config re-clamp at use, sub-resolution fixed-point fall-through, mutation-tested harness; compiles clean at the macOS 13 floor on both slices; Codex implemented, mousejail-f4 reviewed and hardened; phase-2 wiring notes below) |
| 1.1 | Pointer acceleration (`PointerAccel.swift`) behind a CLI flag, bridging header, -1 guard, 196608 bootstrap, adopt rule, 5s reassert, wake reassert | pointer-and-scroll phase 1 | done-pending-wiring(module by mousejail-ce, verified by mousejail-f4: compiles at the 13 floor, all spec guards present; deliberate deviation: bootstrap honors a non-positive com.apple.mouse.scaling by restoring nothing instead of forcing 196608. CLI flag wiring lands with 0.1; owner's exit paths must call restore() — deinit does not run for globals at exit) |
| 2.1 | Scroll tap wired (`.tailAppendEventTap`), CLI flags, swallowing rules, `--dump-scroll` instrumentation | pointer-and-scroll phase 2 | not-started |
| 2.2 | Measure wheel vs trackpad fields (`isContinuous`, phases, `scrollCount`) with `--dump-scroll` on real hardware; decide the alternate-detection discriminator | pointer-and-scroll phase 2 | not-started |
| 2.3 | Manual matrix: per-app scroll checks, trackpad regression, acceleration distance test | pointer-and-scroll Testing | not-started |
| 3a.1 | Self-signed code-signing certificate created in login keychain; Makefile signs with it | distribution phase 3a | not-started |
| 3a.2 | App bundle (`Cataclysm.app`, `LSUIElement`, `LSMinimumSystemVersion` 13.0, placeholder icon, bundled watcher plist) | distribution phase 3a | not-started |
| 3a.3 | Startup order: instance lock (`flock`), re-associate, install-location gate, clamped settings load, trust check, then taps/property/agent | distribution phase 3a | not-started |
| 3a.4 | `MenuBarExtra(.window)` panel: default view + Advanced disclosure, status/failure rows, all settings writing through `UserDefaults` | distribution phase 3a | not-started |
| 3a.5 | Game picker: running apps, synthesized stored row, dedupe rules, "Choose from Applications…" row | distribution phase 3a | not-started |
| 3a.6 | Onboarding window: trust prompt, deep link, 0.5s poll, Relaunch fallback | distribution phase 3a | not-started |
| 3a.7 | `--watch` watcher: startup release + transition release, `SMAppService` registration, legacy LaunchAgent fallback, re-register on version change | distribution phase 3a | not-started |
| 3a.8 | Acceptance gate: watcher registered by either mechanism, `launchctl print` resolves the executable; includes the OBJ-10 settling check (re-run 9b with the real 3a identity) | distribution phase 3a | not-started |
| 3a.9 | Hotkey: try local monitor, then first-responder view; fall back to fixed `cmd+alt+L`; recorder teardown rules | distribution phase 3a | not-started |
| 3a.10 | Rename to Cataclysm (repo `cataclysm`, app `Cataclysm.app`, binary `cataclysm`); retire `hammerspoon/mousejail.lua` only after 3a.8 passes | distribution phase 3a | not-started |
| 3b.1 | Universal binary (arm64 + x86_64, bridging header, `lipo`) | distribution phase 3b | not-started |
| 3b.2 | `make dmg` / `make release` split; `release` refuses without notary profile | distribution phase 3b | not-started |
| 3b.3 | Icon artwork, README rewritten for friends | distribution phase 3b | not-started |
| u.1 | Decide Developer ID membership (blocks only 3b's notarization path) | distribution Open | needs-user |
| u.2 | Remove two denied TCC rows for `com.example.assocprobe.never-granted` in System Settings (Accessibility, Input Monitoring); `tccutil` cannot | pairing report | needs-user |
| u.3 | Migration: quit UnnaturalScrollWheels from its own menu (so it restores `HIDMouseAcceleration`), then uninstall, before running phase 1+ builds | pointer-and-scroll Migration | needs-user |

## Findings for later items (from the 1.1 review, session mousejail-ce)

- **3a.3 / 3a.10**: `UserDefaults.standard` changes domain when the CLI becomes a bundle (process-name plist now, bundle-id plist after 3a), which orphans `recovery.originalMouseAcceleration`. 3a needs a migration read of the old domain (or the wiring should hold off persisting until the bundle exists).
- **3a.3 "Reset everything and quit"**: the `recovery.` key prefix alone cannot survive a whole-domain clear; the protection is the ordering the spec already mandates (restore acceleration before clearing), so implement the clear strictly after restore returns.
- **3a startup health check**: `IOHIDEventSystemClientCreateSimpleClient` is `_Nonnull` only via the header's assume-nonnull block; in a sandboxed or degraded context a null client silently no-ops every write. Startup should verify a read round-trips before reporting the feature as on.

## Phase-2 wiring notes (from the /selfreview integration pass)

Traps for whoever wires `ScrollFilter.swift` into the tap callback:

- `decideScrollEvent`'s `time` is SECONDS. `CGEvent.timestamp` is mach ticks (~41.7ns each on this machine); passed raw, the 250ms burst gap elapses on every event, residue resets each time, and sub-1.0 multipliers silently emit nothing. The allocation-free, time-correct source is `CGEvent.timestamp` scaled by a `mach_timebase_info` read once at startup; `NSEvent(cgEvent:)?.timestamp` is correct but allocates a bridged NSEvent per wheel event inside the tap callback, and `systemUptime` measures callback time, not event time.
- The tap mask in `main.swift` has no `scrollWheel` bit today; the scroll tap is a separate `.tailAppendEventTap` per the spec, not a bit added to the jail's head-insert tap.
- Scroll dispatch must run before the jail's `guard engaged` and before the mouse-path code that reads `mouseEventDeltaX/Y`, rewrites `event.location`, and warps the cursor; a scroll event reaching that code warps once per wheel notch.
- `.swallow` means returning `nil` from the callback; every existing return passes the event, nothing models a drop yet.
- `ScrollFilterState` must be one long-lived file-scope value (like `virtualPos`), never fresh per event; `.rewrite`'s nil axis means leave that axis's fields untouched; `applyAxisDeltas`'s `flatten` must come from the same per-axis config that produced the deltas.
- Field reads: line/point via `getIntegerValueField`, fixedPt via `getDoubleValueField`, `isContinuous` as `getIntegerValueField(.scrollWheelEventIsContinuous) != 0`.
- Makefile: when the `$(BINARY)` rule gains the new sources and `-import-objc-header Bridging.h`, update its prerequisite list in the same edit, or editing a module leaves a stale binary that `install`/`restart` reports as freshly deployed.

## Decisions taken this run

- **Bundle id**: `io.github.heyitaki.cataclysm`, derived from the GitHub remote (`github.com/heyitaki/mousejail`, which will redirect after the rename). Chosen because it stays true as long as the GitHub account exists. The spec makes this permanent once real Accessibility grants exist, so it is cheap to override any time before 3a's first signed build is granted, and expensive after. Flag to the user before first release.
- **"Choose from Applications…" row**: kept, per the spec's own argument (only way to target an installed-but-not-running game).
