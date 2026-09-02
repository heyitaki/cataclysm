# Cataclysm website, download counting, and usage stats

Decided 2026-09-01; moved from `docs/plans/` to `specs/` on 2026-09-02, when the four amendments `specs/auto-update.md` addressed to it were applied and the ralphex run plan took over `docs/plans/cataclysm-website.md`. No Apple Developer ID: the app stays self-signed and un-notarized (closes progress.md r.10). Distribution moves from the GitHub releases page to `akshath.me/cataclysm`; GitHub Releases stays as the file store behind a redirect the user never sees. Stats come from one Cloudflare Worker on the akshath.me zone.

## Why each piece

**Gatekeeper without notarization.** A self-signed app downloaded by a browser carries the quarantine attribute, and Sequoia removed the right-click Open bypass, so the only remaining route is System Settings > Privacy & Security > Open Anyway followed by an authentication prompt. The DMG from the browser is the only install path: it is the pattern users recognise, and a Terminal one-liner (which would sidestep the warning because curl does not quarantine) was rejected as more friction and more suspicious than the dialog itself. So the mitigation is entirely presentational, on the landing page and inside the DMG:

- The page says up front, in one sentence next to the button, that macOS will show a warning because the app is not enrolled in Apple's paid developer program, not because anything was detected, and that it takes one trip to System Settings to clear.
- A screenshot walkthrough of the exact dialogs, tiered by the macOS the screenshots were actually captured on: macOS 26 first, then macOS 15, then macOS 13/14 (right-click, Open) in a collapsed section.
- The DMG window carries the same instructions as a plain-text read-me file staged next to the app icon, so a user who skipped the page still sees them at the moment the warning appears.
- The Accessibility grant is presented on the page as step two, so the two permission moments read as one expected sequence instead of two surprises.

Updates re-trigger the warning on every new DMG a browser downloads. The in-app updater (Sparkle, embedded in the app; specified in `specs/auto-update.md`) removes that: it downloads over URLSession, and Sparkle's installer releases quarantine on the new bundle before swapping it in, so the conclusion holds whether or not a normally launched app quarantines its downloads.

**Download counting.** A Worker route on `akshath.me/cataclysm/download` resolves the newest GitHub release (10-minute cache), writes one row to Workers Analytics Engine (timestamp, version, user agent, country), and 302s to the DMG. The updater does not go through the Worker: Sparkle reads its appcast straight from `github.com/heyitaki/cataclysm/releases/latest/download/appcast.xml`, per `specs/auto-update.md`. Everything else on the zone passes through to GitHub Pages untouched. Each route is registered as a wildcard pattern, because Cloudflare matches a route against the whole URL including the query string, so a bare `akshath.me/cataclysm/download` would miss `.../download?src=page` and drop it through to GitHub Pages as a 404. The wildcard is wider than the two endpoints, since `*` matches any characters and so catches sibling paths like `/download-notes` too. The Worker therefore dispatches on the exact pathname and forwards everything else to the origin with `fetch(request)` rather than rejecting it, which is what keeps the passthrough promise true.

**Usage and retention.** The app sends a daily heartbeat to `akshath.me/cataclysm/ping`: random install id (UserDefaults, generated once), the install's created date, app version, macOS version, arch, `enabled`, `jailEnabled`. Sent on launch when the last ping attempt is older than 20 hours and re-checked hourly; failures are dropped, never retried. No target bundle id, no display name, no IP stored (the Worker does not forward it). Default on with a visible "Send anonymous usage stats" switch on the panel's main page, and the field list documented in the README and on the landing page. A `worker/stats.sh` script queries the Analytics Engine SQL API and prints downloads per day, daily and weekly active installs, share with the jail on, and weekly cohort retention.

## Facts and hypotheses

Verified during the plan review on 2026-09-01. An executing session may rely on these:

- The akshath.me zone is on Cloudflare and proxied in front of GitHub Pages. `dig akshath.me` returns Cloudflare anycast addresses with `adam`/`connie.ns.cloudflare.com` nameservers, and `curl -D -` on the site returns `server: cloudflare` alongside GitHub Pages origin headers. Worker routes are therefore available on this zone, which is what they require.
- Cloudflare matches a route pattern against the entire request URL, query string included, and the wildcard is the only operator. An exact-path route does not match the same path with a query string appended.
- Workers Analytics Engine is included on the Workers free plan: 100,000 data points written and 10,000 read queries per day.
- Analytics Engine datasets are created automatically on the first write after the binding is defined in the Wrangler configuration. There is nothing to create by hand.
- Analytics Engine keeps data for three months, accepts 20 blobs, 20 doubles and exactly one index per write, and caps the index at 96 bytes.
- Analytics Engine SQL supports `count(DISTINCT column)`, but not `JOIN` or `UNION`: "queries can only operate on a single table".
- Sampling starts when data points are written too quickly into one index, and the docs warn that "You may not be able to get accurate unique counts of fields that are not in your index". Counts must be written as `sum(_sample_interval)`.
- The SQL API needs an account id in the URL and a bearer token carrying the "Account | Account Analytics | Read" permission. That is a different credential from the one `wrangler login` creates.
- GitHub's REST API rejects any request with no `User-Agent` header, and limits unauthenticated requests to 60 per hour tied to the originating IP address.
- `github.com/<owner>/<repo>/releases/latest/download/<asset-name>` 302s to the newest release's asset of that name, with no API call, but it needs the exact name.
- A GitHub release asset carries a `digest` field of the form `sha256:<hex>`.
- The repository `heyitaki/cataclysm` is public and has no releases yet, so `/releases/latest` currently returns 404.
- A read-me file stages into the existing plain `hdiutil` DMG target with one `cp`. A Finder background image does not: the UDZO image the target produces mounts read-only, so its `.DS_Store`, where Finder keeps the window background, cannot be written afterwards.
- The development Mac runs macOS 26.3, not macOS 15.
- The landing page ships through the site repo's own GitHub Actions Jekyll build, and every existing page there carries front matter with a `layout`. Measured 2026-09-02: a page with `permalink: /cataclysm` builds to `_site/cataclysm.html`, which Pages serves at `/cataclysm` with no trailing slash, the same way the site already serves `/unsettled`; `bundle exec jekyll build --source <other checkout> --destination <dir>` run from the main checkout (where bundler's `vendor/bundle` path is configured) builds a worktree without touching it.
- `@cloudflare/vitest-pool-workers` 0.22 (the vitest 4 line) no longer exports `fetchMock` from `cloudflare:test`, so outbound requests cannot be mocked through the Workers pool. The Worker takes its `fetch` as an injected dependency and is tested under plain vitest in Node; measured 2026-09-02 with vitest 4.1.11 and wrangler 4.128.0 (`wrangler deploy --dry-run` accepts the Analytics Engine binding).
- A `wrangler login` session that goes unused for long enough expires and cannot be refreshed non-interactively (seen 2026-09-02); renew it with `npx wrangler login` before an unattended run. Its OAuth scopes do not cover the Analytics SQL API, which needs an API token.
- `main` is ahead of `origin/main` and unpushed, so progress.md r.1 is still live. This plan closes r.10 only.

Hypotheses. Each one is still unproven; do not treat any of them as fact, and record the outcome in this file when you check it:

- **That a self-signed app reaches the Open Anyway path at all.** Verified 2026-09-02 on macOS 26.3 with a quarantined (`0083;...;Safari;`) unsigned DMG: (1) double-clicking the dragged-out app shows "“Cataclysm” Not Opened. Apple could not verify “Cataclysm” is free of malware that may harm your Mac or compromise your privacy." with buttons Move to Trash and Done; (2) System Settings > Privacy & Security > Security shows Cataclysm was blocked with an Open Anyway button; (3) clicking it shows "Open “Cataclysm”? Apple is not able to verify that it is free from malware that could harm your Mac or compromise your privacy. Don’t open this unless you are certain it is from a trustworthy source." with Move to Trash, Open Anyway, Done; (4) Open Anyway prompts for an administrator username and password; then the app launches. Four steps, once per Mac. Also found: a DMG code-signed with the self-signed identity is blocked at mount time ("“Cataclysm-0.1.0.dmg” Not Opened", Move to Trash / Done) with no Open Anyway entry in Privacy & Security, so `make dmg` must not sign the image; an unsigned quarantined DMG mounts without any dialog.
- That the dialog wording and the number of steps on macOS 26 match macOS 15. Verify by capturing both, or by capturing macOS 26 and labelling it honestly.
- That Analytics Engine never samples at this volume. Verify by asserting `_sample_interval = 1` in `stats.sh` and failing loudly when it is not.
- That the GitHub API's unauthenticated per-IP budget is reachable from a Cloudflare Worker. Verify at w.1 by hitting the deployed route repeatedly and watching for 403s.

## Where things live

- Site repo `heyitaki.github.io`, path `cataclysm/index.md` plus assets under `assets/cataclysm/`: the landing page. It needs Jekyll front matter with `layout: default` and `permalink: /cataclysm`, or Jekyll copies it through verbatim and `/cataclysm` 404s. It is a separate repository with its own push-to-deploy GitHub Actions workflow, so shipping the page is a deploy, not a file write. Unattended work on it happens in a git worktree of that repo (`~/code/heyitaki.github.io-cataclysm`, branch `cataclysm`) so the main checkout's uncommitted edits stay untouched; the user previews it locally and merges to deploy.
- `cataclysm/worker/`: Worker source, `wrangler.toml` (wildcard routes covering `akshath.me/cataclysm/download` and `/cataclysm/ping`; two Analytics Engine bindings), `stats.sh`, and the Worker's tests.
- `cataclysm/Telemetry.swift` + Settings key + panel switch + README privacy section.

## Analytics Engine schema

Two datasets, because the index is the sampling key and the two row types need different ones.

- `cataclysm_downloads`: index1 = release version. Blobs: version, user agent, country. One row per served download.
- `cataclysm_pings`: index1 = install id. Blobs: install id, install-created date, app version, macOS version, arch. Doubles: `enabled`, `jailEnabled` as 0/1.

The install-created date is what makes cohort retention survive the three-month expiry: without it, an install whose first heartbeat has aged out is indistinguishable from a new one, and every cohort silently refills with veterans. Install id as `index1` is what keeps `count(DISTINCT install)` honest if sampling ever starts.

`stats.sh` therefore computes retention as two queries joined client-side, not one SQL statement: one for each install's cohort week (from the install-created date), one for its active weeks, joined in the script. Cohort retention cannot look back further than 90 days, and download history older than 90 days is gone.

## Release asset contract

Every release carries four assets, and both this plan and `specs/auto-update.md` depend on the set being complete:

- `Cataclysm-<version>.dmg`, the browser install path.
- `Cataclysm.dmg`, a byte-identical copy under a version-stable name, produced by `make dmg` (auto-update u.3 owns the producer). This exists solely so `/download` has a fallback it can construct without an API call, and it is what `releases/latest/download/Cataclysm.dmg` resolves to.
- `Cataclysm-<version>.zip` and `appcast.xml`, the updater's path, owned by `specs/auto-update.md` u.3. `releases/latest/download/appcast.xml` is the app's feed URL, so a release without the appcast asset is one nobody updates to.

`/download` resolves the newest non-prerelease release through the GitHub API and picks `Cataclysm-<version>.dmg`. Its behavior in every other case is fixed:

- More than one asset matching `Cataclysm-*.dmg`: take the one whose version equals the release tag with exactly one leading `v` stripped, since the tag convention is `v0.2.0` while the asset is `Cataclysm-0.2.0.dmg`. If none matches, treat it as no DMG.
- No DMG asset on the newest release: 302 to `akshath.me/cataclysm?error=no-build` and write no analytics row.
- No release at all: the same 302 and no row.
- The API call fails, is rate limited, or times out: 302 to `github.com/heyitaki/cataclysm/releases/latest/download/Cataclysm.dmg` and write no row, since the version is unknown. Downloads served this way are invisible to the stats; that is the accepted cost of staying up.

## Queue

Cross-plan order with `specs/auto-update.md`: the Worker and the updater are independent. u.1 (the EdDSA public key in the plist) and u.3 (the zip and `appcast.xml` from `make dmg` and `make appcast`) must land before w.6, because w.6 is the release that has to carry all four assets. u.0 (a long-lived signing certificate) is recommended before w.6 but no longer blocks it. u.5 touches the same files as w.5 and should land after it or in the same change.

| # | Item | State | Notes |
| --- | --- | --- | --- |
| w.0 | Cloudflare account setup: `npx wrangler login` for deploys (renewed 2026-09-02), account id `9bdc7b059bbd6f7e6204d2d23e03e025`; an API token with Account Analytics Read in keychain `claude-local-cloudflare` for `stats.sh` | login done, analytics token pending | User present. The login session cannot query the Analytics SQL API, so `stats.sh` waits on the token. No dataset creation step: datasets appear on first write |
| w.1 | Worker: `/download` redirect with count, `/ping` into Analytics Engine, `wrangler.toml`, `stats.sh` | done 2026-09-02 | Written and green locally; the deploy and the live route checks are w.0. Routes are wildcard patterns, or query-bearing requests miss the route entirely; the Worker dispatches on the exact pathname and forwards every other wildcard-matched request to the origin with `fetch(request)`, never a rejection. Must send an explicit `User-Agent` on every GitHub API call or the API returns 403. Follow the release asset contract above for every `/download` case. A server-side flag disables `/ping` collection without touching `/download` |
| w.1a | Worker tests: mocked GitHub responses for success, 404, no DMG asset, two DMG assets, upstream 5xx, a `v`-prefixed tag against a bare-versioned asset name, each asserting the exact status, location and whether a row was written; ping payload validation; query-bearing requests to both routes; and that a sibling path caught by the wildcard, such as `/cataclysm/download-notes`, is forwarded to the origin rather than answered by the Worker | done 2026-09-02 | 67 cases under `worker/test/`. Plain vitest in Node against the handler with an injected `fetch` and a recording Analytics Engine stub; the Workers pool's `fetchMock` no longer exists |
| w.2 | DMG presentation: a plain-text read-me staged next to the app icon with the Open Anyway steps (`make dmg` copies it into `build/dmg-stage`) | not started | Keep the plain `hdiutil` layout; no create-dmg dependency. The background-image option is dropped: the image the target produces mounts read-only, so Finder cannot store a window background in it |
| w.3 | Landing page at `akshath.me/cataclysm`: what it does, download button with the one-line warning note, Gatekeeper walkthrough with screenshots, Accessibility step, privacy list | not started | First sub-step is the hypothesis check: build, apply the quarantine xattr the way `verify.sh` already does, open, and record which dialog actually appears. If there is no Open Anyway button, stop and re-decide before writing copy. Page needs front matter, a layout, and `bundle exec jekyll build` inspected at `_site/cataclysm.html`. Do not link the page publicly until `/download` resolves a real DMG |
| w.4 | README: install section points at the website, keeps the from-source build; progress.md r.10 marked decided; `make release` removed | not started | Decided 2026-09-02: `make release` (notarization) goes, since r.10 retires it. Leave r.1 open: `main` is ahead of `origin/main` |
| w.4a | README privacy section: the heartbeat field list, that it is on by default, where the switch is, and that "Reset to defaults" restores the default | not started | The plan promises this disclosure and no other row carried it |
| w.5 | App telemetry: `Telemetry.swift`, Settings key `telemetry.enabled` added to `Settings.Key.all`, switch on the panel's main page, tests for ping cadence and payload | not started | Persist the last-*attempt* timestamp before dispatch, not the last success, or the hourly recheck retries a failure the plan says is dropped. Putting the key in `Key.all` means "Reset to defaults" turns telemetry back on for a user who opted out: that is the chosen behavior, and w.4a documents it. Auto-update u.5 edits the same files, so land this first or fold them together |
| w.5a | Panel's "Check for updates…" row: interim behavior only | not started | `CataclysmApp.swift:1197-1202` opens the GitHub releases page, which contradicts this plan's premise. Point it at `akshath.me/cataclysm` until `specs/auto-update.md` u.6 replaces the row with the updater's state-driven version |
| w.6 | First real release through the new flow: `make dmg` and `make appcast`, GitHub release carrying all four assets, confirm `/download` and `releases/latest/download/appcast.xml` resolve it, install on a second Mac from the website | not started | User present; combines with progress.md r.3/r.11. Gated on progress.md r.1 (nothing can be released until `main` is pushed) and r.4 (TCC keys the Accessibility grant to the bundle id, and this is the first release). Auto-update u.0 is recommended first: with Sparkle a later certificate change no longer strands installed copies, but it still costs every user one Accessibility re-grant. Gated on auto-update u.1 and u.3, which own the public key in the plist, the zip and the appcast |

## Known issues

- No rollback drill for the Worker beyond Cloudflare's built-in deployment rollback. Acceptable while the Worker is two routes.
- Downloads served through the API-failure fallback are not counted, so a GitHub API outage shows up as a gap in the download series rather than an error.
- DAU undercounts a Mac that stays asleep across its whole eligible ping window: an hourly timer does not fire during sleep, so the heartbeat lands on the next wake.
- A user who clears the app's preferences gets a new install id and counts as a new install.
