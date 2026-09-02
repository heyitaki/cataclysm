# Cataclysm

Fixes the mouse for League of Legends on macOS.

Playing League in a window on a Mac, three things are wrong out of the box: the cursor slips off the game window, so an edge flick mid-fight opens a context menu on the desktop instead of moving the camera; the pointer accelerates, so the same hand motion moves the cursor a different distance depending on how fast you made it; and the scroll wheel zooms the wrong way. Cataclysm fixes all three. It lives in the menu bar, works with sensible defaults the moment you grant it one permission, and everything adjustable is in the dropdown.

The cursor fix is the capture technique virtual machines use: the hardware mouse is disconnected from the on-screen cursor and Cataclysm places the cursor itself, clamped to the game window, on every movement. The cursor cannot cross the window edge even for a frame. In windowed mode it follows the window's rounded corners so a click in the corner gap can't land on the app behind the game; in borderless and fullscreen modes the corners are sharp and the clamp is the plain rect, so the minimap corner stays reachable and the cursor stays on the game's display. Native macOS fullscreen is left to the game, which confines the cursor itself. It engages only while the game is frontmost and releases the instant it isn't.

## Install

Needs macOS 13 (Ventura) or later; works on both Apple silicon and Intel Macs.

1. Download `Cataclysm-x.y.z.dmg` from the [releases page](https://github.com/heyitaki/cataclysm/releases) and open it.
2. Drag `Cataclysm` onto the `Applications` shortcut next to it, then eject the image.
3. Open Cataclysm from Applications. macOS will refuse the first launch with a malware warning, because the app is not notarized by Apple. That is expected:
   - Close the warning.
   - Open System Settings, go to Privacy & Security, and scroll down: you'll see a line saying Cataclysm was blocked, with an **Open Anyway** button. Click it and confirm.
   - This is needed once. After that it opens like any other app.
4. Cataclysm asks for the Accessibility permission on first run and walks you through granting it. It needs Accessibility to see mouse events; nothing works until it's granted.

Look for the Cataclysm icon in the menu bar. The dropdown has the on/off switches, the application picker, and a scroll speed slider; the rest is under Advanced.

Press ⌥⌘L to toggle the cursor lock at any time, even while the game has focus. You can record a different shortcut under Advanced.

## If the cursor ever freezes

If Cataclysm is force-quit or crashes at exactly the wrong moment, the cursor can be left disconnected from the mouse. A small helper watches for this and reconnects it within about a second; if the helper itself has to be restarted by the system, the worst case is around ten seconds. If the cursor is somehow still stuck after that, log out and back in.

## A second display

The jail confines the cursor to the game window, so while League is frontmost your other display is unreachable. That is the point of the app, but it surprises people the first time. Click out of the game (cmd+tab) and the cursor is free again.

## What it does to your input

Cataclysm clamps and rewrites your own mouse input: it keeps the cursor inside the window, removes pointer acceleration, and can flip or scale scrolling. It never generates input of its own, no clicks, no movement, no automation. macOS League does not run Vanguard.

## Uninstall

Open the dropdown, turn off "Launch at login", and click "Quit Cataclysm". Quitting restores your mouse acceleration and reconnects the cursor. Then drag Cataclysm from Applications to the Trash, and remove any leftover Cataclysm entry under System Settings > General > Login Items. If a file named `io.github.heyitaki.cataclysm.watch.plist` exists in `~/Library/LaunchAgents` (some installs use it for crash recovery), run `launchctl bootout gui/$(id -u)/io.github.heyitaki.cataclysm.watch` and delete the file.

## Building from source

Needs the Xcode command line tools. `make` builds `build/Cataclysm.app`; `make test` runs the tests; `make dmg VERSION=x.y.z` produces the installer image. `make release VERSION=x.y.z IDENTITY="Developer ID Application: <name> (<team>)" NOTARY_PROFILE=<profile>` builds, notarizes, and staples the DMG; it needs an Apple Developer ID, and without one releases ship straight from `make dmg`. For tuning, running the bundled binary with `--dump-scroll` logs each raw scroll event and the filter's decision to stdout.

## License

MIT
