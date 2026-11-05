# macOS checks

Every check here runs in CI (`.github/workflows/ci.yml`) on GitHub's macOS
runners: one job builds the macOS and iOS simulator apps, validates the
campaign data and runs the unit checks; a job per GUI suite builds the app
and launches that suite in the runner's desktop session. Previews and logs
of a GUI suite are kept as workflow artifacts.

Run `./Tools/run-unit-checks.sh` for the headless checks of the shared core
(`Tools/UnitChecks.m`): the flight model is deterministic and settles where it
should, entity deltas, player states, events and user commands survive the
wire bit for bit, the console tokenizes, gates cheats and paces its buffer,
and the campaign file names only capital assets that exist. It links the
Shared, Common and Net sources alone, so it needs no window, GPU or game
module.

## GUI checks

Run `./Tools/run-audio-checks.sh` to decode all generated audio and check music
crossfades and looping, flight engine/boost response, effect playback, the saved
sound modes and pausing when the app loses focus. It also exercises the main
menu sound setting and saves desktop, compact and portrait menu previews.

Run `./Tools/run-mouse-checks.sh` to check mouse flight event routing, held roll,
roll/yaw transitions, simultaneous fire, wheel-click centring, wheel direction
with either macOS scrolling setting, throttle limits and input release. It uses
the native game objects and ignores attached controllers for repeatable checks.

From the logged-in macOS desktop session, run `./Tools/run-gui-checks.sh`.
It builds and opens a separate app bundle to check portrait transitions
throughout the campaign at desktop, narrow and iPhone sizes. It checks for a pass message
after the app exits and keeps the bundle and logs on failure.

Use Launch Services for ad hoc GUI checks and previews as well. Give each
test bundle its own bundle identifier, then launch it with:

```sh
/usr/bin/open -n -W "/absolute/path/to/Check.app" --args arg1 arg2
```

Omit `--args` if the check takes no arguments. Use `--stdout` and `--stderr`
with absolute file paths before the bundle path to capture logs. Check for a
fresh pass message or output file: `open -W` waits for the app to exit but
doesn't report its exit status. Running `Contents/MacOS/…` directly from a
sandboxed runner can abort in macOS registration, even for tests that create
SpriteKit scenes without showing a window.

Run `./Tools/run-flare-checks.sh` for GPU-rendered lens-flare checks at desktop,
iPhone and iPad sizes. It verifies colour and falloff, border clipping,
occlusion/offscreen handling, and frame-rate-independent exposure. It also
composites the transparent overlay through SceneKit onto a checkerboard and
rejects any darkening of the scenery, including when shaders are unavailable. PNG previews
and logs remain in the printed `build/flare-checks.*` directory.

The visual references are [Cooke's photographed anamorphic flares](https://cookeoptics.com/news-and-events/an-introduction-to-anamorphic-lenses/)
and [ShareGrid's Kowa lens tests](https://www.sharegrid.com/learn/lens-sets/kowa-cine-prominar-anamorphic).

Run `./Tools/run-dialogue-checks.sh` for native rendered dialogue and briefing
checks. It verifies the bundled proportional Oxanium faces, fixed wrapping during
typing, intact Unicode characters, carriage returns, and click-to-finish controls.
Desktop and phone PNG previews remain in the printed `build/dialogue-checks.*`
directory. It forces motion on (`ui_reduceMotion 0`), so it runs the same
whatever the machine's Reduce Motion setting is.
