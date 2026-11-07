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

Run `./Tools/run-mouse-checks.sh` to check mouse flight event routing, Casual/Expert steering,
separate sensitivity, saved preferences, mouse weapons and targeting, wheel direction
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
checks. It verifies caption clearance from portrait heads, the bundled proportional Oxanium faces, fixed wrapping during
typing, intact Unicode characters, carriage returns, and click-to-finish controls.
Desktop and phone PNG previews remain in the printed `build/dialogue-checks.*`
directory. It forces motion on (`ui_reduceMotion 0`), so it runs the same
whatever the machine's Reduce Motion setting is.

Flight UI checks also render LAN creation, eight-pilot lobbies and server
selection at compact phone, notched phone, iPad and desktop sizes. They cover
settings row padding and centring, slider dragging and cancellation, keyboard creation, waiting for a second pilot, rematch navigation, PvP scores
and the wrapping H/F1 help panel. See [the release review](../../RELEASE_REVIEW.md)
for selected previews and the distinction between scene fixtures and device tests.

## Standalone UI reference

Run `./Tools/run-ui-reference-checks.sh`, then open
[`build/ui-reference/index.html`](../../build/ui-reference/index.html). No game,
mission, server, model baking or simulator is started. The runner links the
production engine, shares resources by symlink, renders actual SpriteKit nodes,
and checks button/hint centring, callback routing, disabled actions, settings
padding, two-line pause labels, rendered per-line text centring, pause touch sizes and touch-control hit geometry. It refreshes the same
output directory; an optional first argument chooses a separate output folder.

For focused iteration, `./Tools/run-ui-reference-checks.sh build/ui-reference --network-only`
refreshes the menu and Multiplayer fixtures while retaining the rest of the catalogue.

The offline catalogue filters by family, configuration, category and name. Use
Actual size or open a PNG to judge typography at one scene point per pixel;
fit-to-card thumbnails and the three JPG overview sheets are for navigation.
Print the filtered catalogue for a reference sheet. `manifest.json` records every
fixture, point size and safe inset. CI keeps the catalogue with the previews.

The matrix covers 568×320 and 667×375 phones without a notch; 852×393 and
932×430 phones with side/home insets; 1194×834 iPad and a 600×834 iPad window;
1280×720, 1600×900, 2288×818 and narrow 640×660 desktop windows. An 834×1194
portrait iPad is an extra layout stress case: the native iOS app currently ships
landscape orientations. These are shared scene fixtures rendered on macOS, not
native simulator/device screenshots. Retina scaling and native event delivery
still need device testing.

Coverage includes action normal/selected/hover/disabled states, back/title bars
with zero/one/two actions, long translations, all fourteen title-bar icons in authored normal/selected/hover/pressed/disabled states, settings choices and actions, slider minimum/midpoint/maximum, every
pause selection across local/online and chase/cockpit configurations, menu
start/continue/replay and selections, mission current/locked/completed tiles and all three star ratings, conversation,
tactical map, success/failure/overflow reports, loading empty/half/ready, LAN
setup/waiting/ready/full/results, guest waiting, framed list rows in normal/selected/hover states and long names, browser empty/selected/error, HUD conditions,
targets/objectives/messages/help/respawn, unshielded and critical states, empty
missile racks, the four fixed-resolution cockpit glass displays in normal,
warning and destroyed states, and the shared touch controls at rest,
pressed/stretched and with a controller attached. Production controls without a
pressed state are not given a made-up one. This is a finite breakpoint/state
matrix, not a claim to enumerate every pixel size or every string in the campaign.
New controls and layout states must extend `UIReference.m` and this inventory.


## Localized reference

Run `./Tools/run-ui-localization-checks.sh` to render all 21 languages in the same
11 configurations. Optional language arguments, such as `de ar ja`, restrict a
development run. The offline sheet is `build/ui-localization/index.html`, with
language, device and name filters and actual-size inspection. It covers the main
menu, online pause, flight settings, HUD with objectives and
radio captions, and help, plus LAN settings, searching, waiting and full rosters. The runner checks button containment and centring,
locale selection, and native CoreText glyph fallback for every catalog entry,
including game content. `--glyphs-only` checks both games in every language;
`--verify-only` checks all layout configurations without writing previews. Use
these for quick iteration before regenerating the sheets. No game session or
font download is needed.
`--network-only` refreshes the Multiplayer settings and lobby previews while retaining other screenshots.
`--flight-only` refreshes the HUD/help previews while retaining existing menu
previews; a missing language sheet is rendered in full.

The core and both game catalogs are complete in every supported language. The
unit validator rejects missing keys, mismatched arrays or format specifiers, and
native language declarations or permission prompts that fall out of sync. Briefing and debrief story
dialogue remains English; mission objectives, all in-flight radio captions, ship
classes, cargo and weapon labels are translated. Proper names, callsigns and navigation markers retain their
map spelling. These previews use the Mac's system font fallback; native iOS
rendering should also be reviewed before release.

All menu commands live in the top title bar. Phones show unframed command icons; iPad and desktop show icons with labels. Settings and empty states center within the remaining safe content region. Overflowing content scrolls below the fixed title bar; bindings have their own title-bar command.
