# mousejail

Confines the mouse cursor to a game's window on macOS. Built for League of Legends in windowed mode, works for any app.

Games that don't capture the cursor in windowed mode let it slip onto the desktop, so an edge flick mid-fight opens a context menu instead of registering in game. Tools that warp the cursor back after it escapes leave a race where clicks still land outside, and the post-warp suppression makes edges feel sticky. mousejail uses the capture technique VMs use: it disconnects the hardware mouse from the cursor (`CGAssociateMouseAndMouseCursorPosition`) and places the cursor itself on every event from clamped tracking of the raw deltas. The cursor can't cross the window edge even transiently, and movement feels native everywhere else.

## Details

- An active HID-level `CGEventTap` rewrites each mouse event's location and deltas to stay inside the window's content area. The title bar is excluded so click-flicks can't drag the window.
- The clamp follows the window's rounded corners, so the cursor can't sit in the corner gap outside the window, where a click lands on the app behind and drops the game out of focus.
- The window frame is re-read twice a second, so moving the window or changing the game's resolution just works.
- Engages only while the game is frontmost, releases the instant it isn't.
- Warp displacement folds into the next event's delta on macOS. mousejail compensates, so cursor speed is unchanged (approach borrowed from [mouselock](https://github.com/mxrlkn/mouselock)).

## Install

Needs the Xcode command line tools and [Hammerspoon](https://www.hammerspoon.org).

```
make install
```

Add `require("mousejail")` to `~/.hammerspoon/init.lua` and reload. Hammerspoon needs the Accessibility permission. `cmd+alt+L` toggles.

## Another game

```
./mousejail com.example.game
```

Default is League's game client. With Hammerspoon, set `BUNDLE` in `mousejail.lua`. Find a bundle id with `osascript -e 'id of app "GameName"'`. Anything unrecognized on the command line is an error rather than a bundle id, so a typo can't leave the jail waiting on an app that doesn't exist.

## Corner radius

```
./mousejail --corner-radius 32
```

The default of 18 points suits Riot's window. A standard macOS 26 window is nearer 32, earlier releases are smaller, and a game in true fullscreen has nothing behind it to escape onto. Too large only costs reachable area in the corners, too small leaves the gap open, so round up. `0` turns corner clamping off. With Hammerspoon, set `RADIUS` in `mousejail.lua`.

## Recovery

If an instance dies mid-capture the cursor stays disconnected. The Hammerspoon supervisor restores it automatically. Standalone, run `./mousejail --release`.

## License

MIT
