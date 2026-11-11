# Agent guide

How to work in this repository. Read [ARCHITECTURE.md](ARCHITECTURE.md) for the map of
modules and how a frame runs; this file covers building, checking and the house style.

## Build

macOS with Xcode's command-line tools. Everything builds from the shell:

```sh
./build.sh                      # macOS app: build/KestrelFrontier.app (engine + every game module)
./build.sh ios-simulator        # iOS simulator app under build/iOS/
GAME=EmberReach ./build.sh      # another default game
make -j8                        # just compile and link the native targets (faster while iterating)
```

`make` stops on the first error. When you filter its output, also check its exit
status: "No rule to make target …" contains no "error". After files move, stale
dependency files in `build/Native` can name the old paths; delete the `.d` files
that mention them (or all of `build/Native`).

`KestrelFrontier.xcodeproj` is generated. After adding, moving or removing source
files run `python3 Tools/Xcode/generate.py`; never edit `project.pbxproj` by hand.
The Makefile picks up `Sources/*/*.m` and `Games/*/Game/*.m` by wildcard.

## Check

Run only the headless unit suite. Its total compile-and-test budget is **10 seconds**;
the runner terminates the process group if that limit is exceeded.

```sh
./Tools/run-unit-checks.sh
```

GitHub Actions compiles and links the native targets in Build and runs this
command in Test. Do not add GUI, network, stress, audio, simulator-build,
screenshot-catalogue or localization-render jobs. Check appearance and real-device
LAN behavior manually when needed; they are not automated merge gates.

The suite covers flight math, wire serialization, typed data, console behavior,
mission/story logic, continuity and string catalogue contracts. Every shipped
locale must contain the English key set, preserve format specifiers and array
lengths, and keep native language declarations and permission prompts in sync.
Remove catalogue keys when their last production use is removed. Send localization
tokens over the wire and expand them on each client.

## Where things go

- One folder per module under `Sources/`, one header per folder
  (`Sources/<Module>/<Module>.h`), sections marked `// MARK: - <Name>`.
- `Sources/Shared` is linked separately into the engine and every game module:
  C structs and functions only, no Objective-C classes.
- `Sources/Mission` is compiled into game modules, not the engine.
- `Sources/Client` must build without SceneKit; it draws only through `Refresh`.
- Gameplay belongs in `Games/<name>/Game`; the engine has no game content.
  Content is data in `Games/<name>/` (see [Games/README.md](Games/README.md)).
- Configuration is cvars and commands ([CONSOLE.md](CONSOLE.md)), never
  environment variables or compile-time switches.
- User-facing text goes through `L10n` and `Resources/Strings/<locale>.json`
  (games add theirs in `Games/<name>/Strings/`).

## Placing things on a ship

A ship's attachment points (`guns`, `nozzles`, `cockpitEye`, `propellerHub`) are
data in `Games/<name>/Data/Ships/<ship>.json`, in **ship space**: metres, origin
at the model's origin, nose along **-Z**, +Y up, +X to the pilot's right. The
OBJ is modelled with its nose along +Z; the renderer turns it half a turn about
Y, so an OBJ vertex (x, y, z) sits at (-x, y, -z) in ship space. A point must
sit on the mesh: a gun muzzle at the front of a barrel or prong, a nozzle at
the back of an engine. `Tools/validate_ships.py` (part of the unit checks)
rejects a gun more than 0.5 m, or a nozzle more than 0.8 m, from a mesh
vertex. To find a spot, read the mesh's extents, in ship space, with a short
script over the OBJ's `v` lines (the validator shows the transform), then look
at it:

```sh
build/KestrelFrontier.app/Contents/MacOS/KestrelFrontier --preview-ship executioner
build/DawnPatrol.app/Contents/MacOS/KestrelFrontier --preview-ship se5a DawnPatrol
```

The preview opens one ship in the studio scene, flying its exhaust through
idle, full throttle and boost and firing from each gun in turn, with the
camera circling. **M** shows the attachment points (green guns, orange
nozzles, white cockpit eye), **Space** holds the camera, **Q** quits. Ships from
a game that builds on another (`game.json` "base") are previewed from the base
game's app with the game named as the second argument.

## House style

**Values, not components.** Treat `CGPoint` as a 2D vector and use the helpers in
`Sources/Common/Common.h` (`PointAdd`, `PointSub`, `PointScale`, `PointDistance`,
`PointLerp`, `PointNormalize`, `PointClampLength`, `RectCenter`, `RectFromEdges`,
`RectInsetEdges`, `BoxRect`/`UnboxRect`, …) instead of writing `.x` and `.y` (or
`origin.x`, `size.width`) arithmetic. Use `simd` vector operations for 3D. Add a
helper when one is missing rather than spelling the components out.

**State that moves together is a struct.** When several fields are copied, compared
or reset together, group them into a struct and handle it as one value:

```objc
_oldCaption = CaptionTake(&_caption);          // not nine lines of _oldX = _x; _x = nil;
_shown = (Shown){ .mode = _shown.mode };        // reset all but the mode
CockpitCues cues = CockpitCuesOf(ps);           // compare with the last _cues, then store
```

ARC allows object pointers in C structs in `.m` files. Give an object a method
(`-[GClient leaveLevel]`) instead of resetting its fields from outside.

**Subsystems are classes.** A self-contained piece of a screen or system gets its
own small class (`TacticalMap : SKCropNode`, `TextViewport : SKNode` in
`Sources/UI/Briefing.m`) rather than a cluster of ivars and methods in its host.

**Compose shared UI controls; never position their parts in scenes.** Scenes
declare a bar's information, title and actions with callbacks. `TitleBar`,
`UISettingsForm` and `ScreenRegions` own sizing, typography, padding,
alignment, responsive placement, interaction states and hit geometry. For
example, declare a title bar with its information and command callbacks;
do not place its title, icons and buttons independently. All screen commands live
in the top title bar, with no bottom information rail. Phones use unframed icons;
iPad and desktop use icons with text. Center content within the safe body region
when it fits; keep overflow scrollable below the fixed title bar. Reuse
the same control across scenes. Extend or refactor the shared control when a
composition is missing instead of adding screen-specific offsets. Touch flight
controls, pause included, are the system `GCVirtualController`, owned by
`Input`; the HUD keeps its readouts clear of it.

**Views draw models; scenes do not choose content.** What a screen shows is a
plain value built by a function in `Sources/Common/ScreenModels.m` from facts
(`PauseMenuModel`, `MainMenuModel`, `ServerListModel`, `LobbyModel`, `MissionListModelMake`, `BriefingMonitorModel`, `DebriefReport`, `MatchReport`), and a view renders it
(`UIReportView`, `UIListView`, `UIMissionGrid`, `UIMonitorHeader`, a `UILayout` template bound to a datasource). A scene gathers
the facts, hands the model to the view and maps the chosen identifier to a
command. Add a block kind or a model when a screen needs something new, test
the model in `Tools/UnitChecks.m`, and look at the view on sample data with
`--preview-ui [debrief|failed|end|match|pause|online|menu|browser|lobby|setup|missions|briefing]`.

Keep automated coverage in fast unit tests of logic and data. Do not restore
rendered UI fixture catalogues or long-running integration suites.

**Data is read once into typed contracts.** JSON stays the format, but it is parsed
in one place into structs or immutable classes (see the table in
ARCHITECTURE.md); nothing else reads keys or passes `NSDictionary` around. Use the
`JSONString`/`JSONFloat`/`JSONInt`/`JSONBool`/`JSONStrings`/`JSONVec3` readers from
`Shared.h`, state each default once, and collect shape problems instead of
crashing. Open vocabularies that games extend by registration (scripted events,
objective-specific fields, UI layouts) are the exception.

**Comments** say why, or what a reader needs that the code does not show, in plain
sentences. Each header section opens with what the thing is for. No commented-out
code, no change logs in comments.

**Platforms.** Code runs on macOS and iOS (`TARGET_OS_IOS`); `Sources/Prefix.h`
pulls in UIKit or Cocoa. Build the iOS simulator app when you touch `App/`, `Input/`
or anything platform-conditional.

## Commits

One logical change per commit, subject in the imperative, sentence case, no prefix
convention ("Typed data contracts: levels, campaign, story and game rules",
"Respect campaign safe areas and expose iPad touch navigation"). The body says what
changed and why. Commit only when asked.

## Other docs

| File | What |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | Modules, boundaries, data contracts, the frame, threads |
| [CONSOLE.md](CONSOLE.md) | Commands and cvars |
| [Games/README.md](Games/README.md) | A game folder's layout and the search path |
| [STORY.md](STORY.md) | The Kestrel Frontier campaign's story |
| [TODO.md](TODO.md) | Known gaps |
| [CREDITS.md](CREDITS.md) | Third-party assets and their licences |
| [TERRAIN-REFERENCES.md](TERRAIN-REFERENCES.md) | Terrain papers and what shipped flight games published |
| [POST-REFERENCES.md](POST-REFERENCES.md) | The post-process and tree look, and what Ace Combat published about theirs |
| [Tools/IOS.md](Tools/IOS.md) | Xcode project, iOS builds and devices |
| [Tools/NETWORK.md](Tools/NETWORK.md) | LAN configuration and manual device testing |
