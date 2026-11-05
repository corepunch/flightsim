# Native iOS campaign audit

Audited main at `1ca1567ae1b8c6f0f4af3313576425648013a3fe`.
The Xcode project is now named KestrelFrontier; the make-based build still
uses SpaceFight for its executable.

## Rendering and input paths

`mainIOS.m` creates the full-window SceneKit GameView and a sibling UIKit
TouchFlightControls view. The controller supports landscape. `Host.m` runs
iOS frame updates on CADisplayLink's main thread. FrontEnd owns one Briefing
scene for mission selection, briefing pages, results and epilogues.
ScreenHost coordinates outgoing/incoming scenes and Host suppresses pointer
events while a screen transition is pending. Completing a mission records
progress before opening results; the epilogue leads into the next briefing.

GameViewIOS passes UIKit safeAreaInsets to Briefing whenever the overlay or
safe area changes. It converts taps into normalized, bottom-origin scene
coordinates. A drag of at least eight points becomes scroll input and does
not also click a mission or advance a page. The drag delta is correct for
Briefing's positive-up content translation. TouchFlightControls is hidden
outside the flight HUD and cancels held input when changing overlays or
losing activity. It supports simultaneous stick, throttle and fire touches;
target/secondary/pause activate on release inside their original control.

## Fixed source-supported problems

Mission selection already respected safe areas. Story footer buttons did
not: their bottom was a constant 16, placing them under a landscape home
indicator. Regular results/large-screen footer buttons were only 40 points
high and also ignored bottom and side insets. Footers now respect safe
edges and use at least 44-point heights. Briefing captions reserve the same
bottom inset, preserving separation from the footer.

Debrief text, results viewport and conversation captions used full-screen
coordinates. They now reserve side, top and bottom safe edges as applicable.
Native iOS also enables touch navigation at every viewport size: the old
large-screen footer had no missions or previous-page touch action, leaving
iPad users dependent on keyboard input. Results now offer a missions button
as well. Desktop footer behavior is retained.

Portrait allocation excludes unsafe side and top regions, preserving the
existing large illustrations and shared height budget rather than replacing
them with thumbnails. Background art remains full bleed.

## Automated coverage and remaining validation

CampaignSafeAreaChecks.h is included by the existing PortraitChecks suite,
run by Tools/run-gui-checks.sh and the CI gui job. It adds SE, notched phone
and iPad point-size fixtures with nonzero safe insets, all mission briefings
and epilogues, caption containment, 44-point action heights, final launch by
pointer, failure retry, next mission and final-campaign return checks.
These are shared SpriteKit scene checks on macOS, not UIKit execution.

The audit environment is Linux with no xcrun, Apple SDK, SpriteKit, or iOS
simulator. No Apple compilation, GUI-suite pass or native screenshot is
claimed locally. CI already builds the iOS simulator app and runs the macOS
GUI suites. Its results must be inspected separately.

On macOS, run `./build.sh ios-simulator`, `./Tools/run-gui-checks.sh` and
`./Tools/run-dialogue-checks.sh`. Then use the existing `./build.sh iphone`
and `./build.sh ipad` deployment paths to check actual native rendering.
Capture both landscape directions on a notched phone, a 667x375 compact
phone, and iPad. Verify face visibility and text readability during typing,
tap-to-finish/advance, previous/skip/launch, drag-to-select late missions,
long result scrolling, retry, epilogue-to-next mission, background/resume,
and simultaneous flight controls followed by pause/resume. Check safe-area
changes after rotation and iPad window resizing, and confirm no held input
survives a transition. Those UIKit/device scenarios remain unverified.
