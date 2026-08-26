# mousejail

Confines the mouse cursor to a game's window on macOS. Built for League of Legends in windowed mode; works for any app.

Games that don't capture the cursor in windowed mode let it slip onto the desktop: an edge flick during a fight opens a desktop context menu instead of registering in game. Utilities that warp the cursor back after it escapes leave a race where clicks still land outside, and the post-warp suppression makes the window edge feel sticky. mousejail instead uses the capture technique VMs use: it disconnects the hardware mouse from the on-screen cursor (`CGAssociateMouseAndMouseCursorPosition`) and places the cursor itself on every event from its own clamped tracking of the raw deltas, so the cursor cannot cross the window edge even transiently, and movement feels native everywhere else.

## Details

- An active `CGEventTap` at the HID level rewrites every mouse event's location and deltas to stay inside the game window's content area. The title bar is excluded (measured from the window's close-button geometry) so click-flicks can't drag the window.
- The window frame is re-read twice a second: moving the window or changing the game's windowed resolution just works.
- The jail engages only while the game is frontmost and releases the instant it is not.
- Warp displacement folds into the next event's delta on macOS; mousejail compensates, so cursor speed is exactly your normal speed (approach borrowed from [mouselock](https://github.com/mxrlkn/mouselock)).

## Install

Requires the Xcode command line tools and [Hammerspoon](https://www.hammerspoon.org) (recommended as the supervisor; the binary also runs standalone).

```
make install
```

Add `require("mousejail")` to `~/.hammerspoon/init.lua` and reload Hammerspoon. Hammerspoon needs the Accessibility permission.

`cmd+alt+L` toggles the jail. The state persists across Hammerspoon restarts.

## Another game

The helper takes a bundle id (default is League's game client, `com.riotgames.LeagueofLegends.GameClient`):

```
./mousejail com.example.game
```

With Hammerspoon, set `BUNDLE` at the top of `mousejail.lua` instead. To find a running game's bundle id: `osascript -e 'id of app "GameName"'`.

## Recovery

If an instance dies abnormally mid-capture, the cursor would stay disconnected from the mouse. The Hammerspoon supervisor detects this and restores it automatically; standalone users can run `./mousejail --release`.

## License

MIT
