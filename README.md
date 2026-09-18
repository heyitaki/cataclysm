# Cataclysm

Cataclysm is a menu bar app that fixes the mouse for League of Legends and other games on macOS: it locks the cursor to the game window, disables pointer acceleration, and inverts scroll direction. Download at [akshath.me/cataclysm](https://akshath.me/cataclysm). Needs macOS 13 or later; runs natively on Apple silicon and Intel.

<img src="assets/dropdown.png" width="320" alt="Cataclysm's menu bar dropdown">

## First launch

macOS blocks the first open because Cataclysm is not in Apple's paid developer program (I want to keep it free). Once per Mac:

1. Drag Cataclysm to Applications and open it. Click **Done** on the "Not Opened" dialog.
2. System Settings > Privacy & Security > Security > **Open Anyway**, then **Open Anyway** again and your password.
3. Grant Accessibility when asked. Cataclysm needs it to see mouse events; nothing works until it is granted.

On macOS 13 and 14, steps 1 and 2 are just: right-click Cataclysm in Applications, Open, Open.

Everything lives in the menu bar dropdown. The cursor lock holds only while the game is frontmost, so `⌘⇥` always frees the cursor; `⌥⌘L` toggles the lock even in-game. The menu bar icon's ring turns solid while the lock is holding.

## What it fixes

- **Cursor lock.** In windowed or borderless mode, an edge flick mid-fight slides the cursor off the game and the click lands on whatever is behind. Cataclysm places the cursor itself on every movement, clamped to the game window, so it cannot cross the edge even for a frame. In windowed mode the clamp follows the rounded corners; in borderless and the game's own fullscreen the corners are sharp so the minimap corner stays reachable. Native macOS fullscreen is left alone since the game confines the cursor there. While the lock holds, a second display is unreachable by design.
- **Pointer acceleration.** macOS scales cursor distance by how fast you moved. Cataclysm turns that off so the same hand motion always travels the same distance. On macOS 14 and later a pointer speed slider scales the movement linearly.
- **Scroll direction.** The wheel zooms the wrong way out of the box. Cataclysm inverts it (horizontal too, under Advanced) and can scale the speed. Trackpads are left untouched.

Cataclysm only clamps and rewrites your own input. It never generates clicks, movement or any automation.

## Crash recovery

If Cataclysm is force-quit or crashes at the wrong moment, the cursor can be left disconnected from the mouse. A watcher registered as a login item reconnects it within about a second, or ten if launchd has to restart the watcher too. The dropdown warns when the watcher is not registered. If the cursor is still stuck, log out and back in.

## Uninstall

Uncheck "Launch at login", quit from the dropdown (which restores acceleration and reconnects the cursor), and move Cataclysm to Trash. Remove any leftover entry under System Settings > General > Login Items. If `~/Library/LaunchAgents/io.github.heyitaki.cataclysm.watch.plist` exists, run `launchctl bootout gui/$(id -u)/io.github.heyitaki.cataclysm.watch` and delete it.

## Building from source

Needs the Xcode command line tools and a code-signing identity named `Cataclysm` in the keychain (self-signed is fine; override with `IDENTITY=`). `make` builds `build/Cataclysm.app`, `make test` runs the tests, and `make dmg VERSION=x.y.z` writes `build/Cataclysm-x.y.z.dmg` plus a byte-identical `Cataclysm.dmg` for the website's download link. Only the app inside an image sends the daily heartbeat. `--dump-scroll` logs each raw scroll event and the filter's decision.

The download redirect and heartbeat receiver live in [`worker/`](worker/): `npm install && npm test` there runs its tests, `npm run check` dry-runs a deploy, and `npm run deploy` publishes through the machine's `wrangler login` session.

## License

MIT
