# macOS GUI checks

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
