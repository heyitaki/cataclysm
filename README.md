# Cataclysm

Fixes the mouse for League of Legends on macOS.

Playing League in a window on a Mac, three things are wrong out of the box: the cursor slips off the game window, so an edge flick mid-fight opens a context menu on the desktop instead of moving the camera; the pointer accelerates, so the same hand motion moves the cursor a different distance depending on how fast you made it; and the scroll wheel zooms the wrong way. Cataclysm fixes all three. It lives in the menu bar, works with sensible defaults the moment you grant it one permission, and everything adjustable is in the dropdown.

The cursor fix is the capture technique virtual machines use: the hardware mouse is disconnected from the on-screen cursor and Cataclysm places the cursor itself, clamped to the game window, on every movement. The cursor cannot cross the window edge even for a frame. In windowed mode it follows the window's rounded corners so a click in the corner gap can't land on the app behind the game. In borderless mode, and in the game's own fullscreen mode, the corners are sharp and the clamp is the plain rect, so the minimap corner stays reachable and the cursor stays on the game's display. Only native macOS fullscreen is left alone, because there the game confines the cursor itself. It engages only while the game is frontmost and releases the instant it isn't.

## Install

Needs macOS 13 (Ventura) or later; works on both Apple silicon and Intel Macs.

1. Download Cataclysm from [akshath.me/cataclysm](https://akshath.me/cataclysm) and open the image.
2. Drag `Cataclysm` onto the `Applications` shortcut next to it, then eject the image.
3. Open Cataclysm from Applications. macOS refuses the first launch: Cataclysm is not enrolled in Apple's paid developer program, so macOS cannot check it against Apple's records. Nothing was detected in the app; the warning only says Apple has not looked at it. You go through these steps once per Mac, and after that Cataclysm opens like any other app:
   1. The dialog "Cataclysm" Not Opened appears, saying Apple could not verify it is free of malware. Click Done.
   2. Open System Settings, go to Privacy & Security, and scroll down to Security. A line says Cataclysm was blocked. Click **Open Anyway**.
   3. A dialog titled Open "Cataclysm"? appears with Move to Trash, Open Anyway and Done. Click Open Anyway.
   4. Enter an administrator name and password.
   - On macOS 13 and 14 the route is shorter: right-click (or Control-click) Cataclysm in Applications, choose Open, then click Open again in the dialog.
4. Cataclysm asks for the Accessibility permission on first run and walks you through granting it in System Settings > Privacy & Security > Accessibility. It needs Accessibility to see mouse events; nothing works until it is granted.

Look for the Cataclysm icon in the menu bar. The switch beside the title in the dropdown turns every feature off and back on at once, and the icon shows a dotted ring while it is off. Below it are the individual switches, the application picker, and a scroll speed slider. The rest is under Advanced.

Press ⌥⌘L to toggle the cursor lock at any time, even while the game has focus. You can record a different shortcut under Advanced.

## If the cursor ever freezes

If Cataclysm is force-quit or crashes at exactly the wrong moment, the cursor can be left disconnected from the mouse. A small helper watches for this and reconnects it within about a second; if the helper itself has to be restarted by the system, the worst case is around ten seconds. If the cursor is somehow still stuck after that, log out and back in.

## A second display

The jail confines the cursor to the game window, so while League is frontmost your other display is unreachable. That is the point of the app, but it surprises people the first time. Click out of the game (cmd+tab) and the cursor is free again.

## What it does to your input

Cataclysm clamps and rewrites your own mouse input: it keeps the cursor inside the window, removes pointer acceleration, and can flip or scale scrolling. It never generates input of its own, no clicks, no movement, no automation. macOS League does not run Vanguard.

## Uninstall

Open the dropdown, turn off "Launch at login", and click "Quit Cataclysm". Quitting restores your mouse acceleration and reconnects the cursor. Then drag Cataclysm from Applications to the Trash, and remove any leftover Cataclysm entry under System Settings > General > Login Items. If a file named `io.github.heyitaki.cataclysm.watch.plist` exists in `~/Library/LaunchAgents` (some installs use it for crash recovery), run `launchctl bootout gui/$(id -u)/io.github.heyitaki.cataclysm.watch` and delete the file.

## Privacy

Once a day, Cataclysm sends one small heartbeat to `akshath.me/cataclysm/ping` so I can see how many installs are alive and whether they keep working. It contains exactly these fields: a random install id (generated once, stored in the app's preferences), the install date, the app version, the macOS version, the CPU architecture (`arm64` or `x86_64`), whether the app is enabled, and whether the cursor lock is enabled. It deliberately does not send the name of the game or any other app, and the receiving server does not store your IP address. The heartbeat is on by default. To turn it off, run `defaults write io.github.heyitaki.cataclysm telemetry.enabled -bool false`. Note that "Reset to defaults" under Advanced turns it back on along with every other setting. The server side is the Cloudflare Worker in [`worker/`](worker/), so you can read exactly what is stored.

## Building from source

Needs the Xcode command line tools. `make` builds `build/Cataclysm.app`; `make test` runs the tests. `make dmg VERSION=x.y.z` produces three of the four release assets: `Cataclysm-x.y.z.dmg` (the installer image, unsigned, with the signed app inside), `Cataclysm.dmg` (a byte-identical copy under a version-stable name) and `Cataclysm-x.y.z.zip` (the updater's archive). The fourth, `appcast.xml`, is the updater's feed and is built separately. For tuning, running the bundled binary with `--dump-scroll` logs each raw scroll event and the filter's decision to stdout.

The download redirect and the heartbeat receiver are the Cloudflare Worker in [`worker/`](worker/), which needs Node and npm. `cd worker && npm install && npm test` runs its tests in plain Node (the report script's tests need `bash`, `curl` and `jq` too); `npm run check` is a dry-run deploy and `npm run deploy` publishes it through the `wrangler login` session on the machine. `worker/stats.sh` prints downloads per day, active installs, the cursor lock share and weekly cohort retention from Analytics Engine; it needs an API token with Account Analytics Read in `CLOUDFLARE_API_TOKEN`, and `worker/stats.sh --dry-run` prints the SQL it would run without one. To stop heartbeat collection without touching downloads, set `PING_ENABLED = "false"` in `worker/wrangler.toml` and redeploy.

## License

MIT
