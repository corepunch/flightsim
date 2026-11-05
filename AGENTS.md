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

Run what covers your change before saying it works; run all of them for anything
that touches shared code, data contracts or the UI.

```sh
./Tools/run-unit-checks.sh          # headless: flight model, wire format, console, data, mission runtime, story, strings
./Tools/run-network-checks.sh       # headless: client/server over loopback and UDP, loss, versions
python3 -I Tools/validate_story.py  # every game's levels, campaign, cast and art
./Tools/run-gui-checks.sh           # portraits and campaign safe areas (desktop session)
./Tools/run-dialogue-checks.sh      # briefing captions and typing (desktop session)
./Tools/run-flight-ui-checks.sh     # HUD, cockpit, mission grid (desktop session)
./Tools/run-mouse-checks.sh         # mouse flight (desktop session)
./Tools/run-audio-checks.sh         # audio (desktop session)
./Tools/run-flare-checks.sh         # lens flare rendering (desktop session)
```

GUI suites open a separate app bundle with `open -W` and need a logged-in macOS
desktop session; previews and logs land in `build/<suite>-checks.*/`. Look at the
previews when you change how something looks.

The strings validator (part of the unit checks) fails on catalog keys no code
uses: delete a string from `Resources/Strings/en.json` when you delete its last use.

Checks read UI state through read-only properties declared for them (for example
`Briefing`'s `speech`, `captionRect`, `scrollRect`), not by KVC into private ivars.
When a check needs new state, add a property.

## Where things go

- One folder per module under `Sources/`, one header per folder
  (`Sources/<Module>/<Module>.h`), sections marked `// MARK: - <Name>`.
- `Sources/Shared` is linked separately into the engine and every game module:
  C structs and functions only, no Objective-C classes.
- `Sources/Mission` is compiled into game modules, not the engine.
- `Sources/Client` must build without SceneKit; it draws only through `Refresh`.
  The unit checks enforce this.
- Gameplay belongs in `Games/<name>/Game`; the engine has no game content.
  Content is data in `Games/<name>/` (see [Games/README.md](Games/README.md)).
- Configuration is cvars and commands ([CONSOLE.md](CONSOLE.md)), never
  environment variables or compile-time switches.
- User-facing text goes through `L10n` and `Resources/Strings/<locale>.json`
  (games add theirs in `Games/<name>/Strings/`).

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
| [Tools/IOS.md](Tools/IOS.md) | Xcode project, iOS builds and devices |
| [Tools/NETWORK.md](Tools/NETWORK.md) | The network regression checks |
| [Tools/GUI/README.md](Tools/GUI/README.md) | The GUI check suites |
