# Architecture

Kestrel Frontier is a space flight game for macOS and iOS, and the engine under it is
meant to carry a family of flight games: each game is a data folder plus, optionally,
its own gameplay module. The engine is Objective-C on SceneKit and SpriteKit, laid
out after Quake 2: a server that runs the game module, a client that predicts and
draws, a renderer behind a narrow facade, and a console of cvars and commands.

This file is the map. Each module's header (`Sources/<Module>/<Module>.h`) is the
reference for what is inside it.

## Layers

```
            ┌──────────────── App (Host, GameView) ────────────────┐
            │  boots everything, runs the frame, owns the threads  │
            └──────┬──────────────┬───────────────┬────────────────┘
                   │              │               │
          UI (front end)     Client ──────► Refresh (facade) ◄── Render (SceneKit)
          Story, Progress       │               HUD, CockpitFrame
                   │            │ snapshots, commands
                   │            ▼
                   │     Net (channel, msgs, transports: loopback / UDP)
                   │            │
                   │            ▼
                   │         Server ──► GameAPI (plain C) ──► game module
                   │            │                              Games/<name>/Game
                   │       Collision                           + Mission runtime
                   │
     Common (cvars, commands, strings, geometry)    Input    Audio
     Shared (file system, protocol, definitions, levels, flight model)  ← everything
```

Arrows point from user to provider. Shared is linked by every image; nothing in
Shared depends on anything above it.

## Modules

`Sources/` holds one folder per module and one header per folder. Shared code
for the engine's Objective-C files is pulled in by `Sources/Prefix.h` (SDK
headers only).

| Folder | What it is |
|---|---|
| `Shared/` | Everything the engine and a game module agree on: the file system search path (`FSURL`, `FSJSON`), the wire protocol (`EntityState`, `PlayerState`, `UserCmd`, events, configstrings), the deterministic flight model (`ShipMove.c`), ship/capital/projectile definitions, levels (`LevelDef`), JSON readers and the `GameAPI` boundary. Plain C structs and functions only. |
| `Common/` | Engine services: `Cvar` and `Cmd` (the console), localisation (`L10n`), and the CGPoint/CGRect geometry helpers. |
| `App/` | `Host`, the application loop and state machine (menus, loading, mission); the platform views; `main`. |
| `Server/` | Hosts the game module through `GameImport`/`GameExport`, ticks it at `TICK_RATE` (30 Hz) and sends delta-compressed snapshots. `GameLoader` picks the game (`fs_game`) and finds its module. |
| `Client/` | `Client`: connection, snapshots, interpolation, prediction of the player's ship. `ClientView`: turns a frame into renderer calls and fills the HUD and cockpit. Never imports SceneKit. |
| `Net/` | `NetChannel` (sequencing, reliable fragments), `NetMsg` (bit-level codec), `NetProtocol` (deltas), transports (in-process loopback, UDP), LAN discovery. |
| `Refresh/` | The renderer as the client sees it, after Quake 2's `refexport_t`: register models while loading, then describe each frame (entities, player, camera, effects). Also the HUD and `CockpitFrame`. No renderer types cross it. |
| `Render/` | `SceneKitRefresh`, the only Refresh backend, and what it draws with: ship and capital views, hull styles, exhaust, effects, cockpit, flight instruments, lens flare, sky, the FX recorder. |
| `Collision/` | `ModelInfo`: capital models' parts and subsystems for server traces and renderer dressing; baked-scene loading. |
| `Mission/` | The mission runtime (objectives, scripted events, scheduled arrivals and departures, win/lose rules) that runs a `LevelDef` against a `MissionWorld` the game supplies. Linked into game modules, not the engine binary. |
| `Story/` | Campaign content and the local progress record. Progress merges unlocks and best results by level name. `App/CloudSaves.m` syncs that record through GameKit. |
| `UI/` | SpriteKit screens: `FrontEnd` (which screen shows), main menu, mission list/briefing/debrief (`Briefing`), loading card, pause menu, server browser, `ScreenHost` (transitions), `UILayout` (menus from JSON), `ScreenRegions` (header and centered body), theme and motion. Scenes compose `TitleBar` (back, title, icon commands) and `UISettingsForm` with content and callbacks; these controls own their layout and hit geometry. A screen's content is a model from `Common/ScreenModels.m` (`MenuModel`, `ListModel`, `ReportModel`), built by a function from plain facts and covered by the unit checks; a view draws it (`UIReportView` for debrief, campaign end and match results, `UIListView` for the server browser and lobby, `UIMissionRows` and `UIMonitorHeader` for mission select and the briefing monitor, a `UILayout` template with a datasource for the pause menu). `--preview-ui [debrief\|failed\|end\|match\|pause\|online\|menu\|browser\|lobby\|setup\|missions\|briefing]` opens a view on sample data. Flight controls on touch screens, pause included, are the system `GCVirtualController` (see `Input/`). |
| `Input/` | Keyboard, mouse, controllers and the iOS virtual controller into `InputAction` and a `ControlState`; pointer events for screens (`ScreenInput`). |
| `Audio/` | `GameAudio`: music, engine sound, effects, on a private queue. |

`Games/<name>/Game/` is a game module (see [Games/README.md](Games/README.md) for the
whole game folder). `Tools/` holds build helpers, validators and the check suites.

`UIHorizontalStack` composes horizontal rows using measured child bounds, centred
vertically by default. It owns multiline label wrapping and accepts stable layout
bounds for changing content such as progress bars. Callers supply content and row
placement rather than correcting individual text baselines or icon offsets.

`UIVerticalStack` lays out rows from the top left. `UIDataList` combines it with
an array of items and a row template that configures reusable nodes. Objective
lists use both stacks. On macOS, run the bundled executable with `--preview-ui`
to inspect the production checklist and score controls in a resizable window.

## The game module boundary

The engine and a game meet at `GetGameAPI` (`Sources/Shared/Shared.h`, "GameAPI"):
the engine passes a table of services (`GameImport`: configstrings, model and string
indices, collision traces, events, commands, cvars, printing) and gets back the
game's entry points (`GameExport`: spawn a level, run one tick, client connect/
begin/think/disconnect, and the entity and player states to send). Only plain C crosses it, versioned by
`GAME_API_VERSION`.

- On macOS each module is `Contents/PlugIns/<game>.dylib`, loaded by `GameLoader`.
  On iOS the default game's module is linked into the app.
- The engine binary and every module each link their own copy of `Sources/Shared`.
  Objective-C classes there would exist twice in one process, so Shared is C
  structs and functions only.
- The mission runtime (`Sources/Mission`) is compiled into the module, not the
  engine, for the same reason; the module supplies the world through the
  `MissionWorld`/`MissionUnit` protocols.
- A game with no `Game/` folder runs its base game's module (`game.json` "base").

## Data and contracts

Game content is JSON in the game folder, found through the search path: the
game's folder, then its base's, then the engine's `Resources/`. A game ships only
what it adds or overrides. `Tools/bundle-resources.sh` copies and bakes it into the
app (models are baked from `.obj` to `.scn`).

Data is read once, in one place, into typed contracts; code never passes JSON
dictionaries around:

| Data | Contract | Where |
|---|---|---|
| `Data/Ships/*.json` | `ShipDef` | Shared |
| `Data/Capitals/*.json` | `CapitalDef` | Shared |
| `Data/Projectiles/*.json` | `ProjectileDef` | Shared |
| `Data/Pickups/*.json` | `PickupDef` (collected with `PickupApply`) | Shared |
| `Levels/*.json` | `LevelDef` (+ nav, entity, wave, field, objective, pickup, rules structs) | Shared |
| `Data/Styles/*.json` | `MaterialSpec` | Render/CapitalView.m |
| `Data/rules.json` | `GameRules` | the game module |
| `Campaign/campaign.json` | `CampaignMission`, `MissionBriefing`, `MissionDebrief`, `StoryDefaults` | Story |
| `Audio/Radio/catalog.json` | `RadioLine` (caption key, reference text, recording without a spoken callsign) | Audio |
| `Story/characters.json`, `Story/rooms.json` | `StoryCharacter`, `StoryRoom` | Story |

Shared contracts are C structs (with ARC-managed object fields), cached for the
process. Engine-only contracts may be immutable classes. Parsers use the
`JSONString`/`JSONFloat`/`JSONStrings`/`JSONVec3` readers in `Shared.h`, so a value
of the wrong type reads as missing and each default is stated once; shape problems
are collected (`LevelDef.problems`) and reported.

Two things stay as JSON on purpose:

- **Scripted events** and **objective-specific fields** are an open vocabulary:
  triggers, actions and objective types are registered by name (the engine
  registers the built-ins; a game may add its own). `MissionRunner`'s
  `problemsWithLevel:` validates them against the registry.
- **UI layouts** (`Resources/UI/menus/*.json`) are a small layout language that
  `UILayout` evaluates against size flags each time a screen lays out, so editing
  a file changes the next rebuild. A layout is a template: texts and button lists
  named "$name" come from the screen's datasource, and a "stack" sizes itself
  to what it is given.

## A frame

The host runs one loop for menus and missions:

1. Platform views push input; the host drains the pointer queue and reads
   `Input` into a `ControlState`.
2. In a mission, the local `Server` advances whole ticks: it reads client
   commands (the local client over loopback, others over UDP), runs the game
   module's tick (`runFrame`, which also advances the mission runtime), and
   queues a snapshot per client.
3. The `Client` reads packets, keeps a short history of frames, interpolates
   the others and predicts its own ship by replaying unacknowledged commands
   through the same `ShipMove.c` the server runs.
4. `ClientView` describes the frame to `Refresh`: entities, the player's ship,
   bolts and effects, the chase or cockpit camera, then the HUD and cockpit
   (`CockpitFrame`).
5. In menus, `FrontEnd` and `ScreenHost` drive SpriteKit scenes over the 3D view.

Threads: on macOS the render thread runs the frame. Loading a mission (building
the world, registering and uploading models) runs on a background load queue
while nothing is drawn; the hand-off points are marked in `Client.h` and
`Refresh.h`. Audio runs on its own queue.

The space sky uses a small vertex-coloured mesh for the nebula and galaxy.
Their procedural colours are calculated once during loading; shader point
sprites draw the stars, and a fragment shader draws the planet. The sun is a
projected optical source: its screen-space shader draws the bright core, halo,
diffraction rays and horizontal lens streak.
There are no sky textures or cubemap convolution passes. All cameras use LDR
on every platform; HDR and camera bloom are disabled. The sky applies its own
tone curve and edge falloff to retain the darker space palette.

Terrain levels draw through a post-process technique (`PostProcess`,
`Resources/Shaders/Post.metal`): the scene pass renders into a texture, its light
above a knee is blurred at a quarter and a sixteenth of the drawable, and the final
quad pass adds the two back and grades the frame (lifted blacks, eased saturation,
warm highlights, a vignette, a trace of colour fringing), after Ace Combat's look
([POST-REFERENCES.md](POST-REFERENCES.md)). The terrain and tree shaders still tone
map their own output, so the grade works on a display-ready frame. With a
technique set SceneKit stops calling `willRenderScene:`, so the host bakes the
terrain maps and cockpit displays from `updateAtTime:`. Standing trees have three
levels of detail: one triangle each on the far rings, a pyramid on the near ring,
and within about 75 crown radii a ray cast inside that pyramid (a spire of cone
tiers or a crown on a trunk) that writes its own depth.

On iOS, a transparent `SKView` above the SceneKit view owns the overlay. Its
main-thread frame callback runs the host before SpriteKit updates and draws;
UIKit touch and focus handling use that same thread. SceneKit draws the 3D scene
on its own queue, with `SCNTransaction` locking around host updates. Do not attach
the iOS overlay to SceneKit: its SpriteKit draw pass does not serialize node
mutations with those main-thread updates.

Effects in the iOS overlay must emit premultiplied colour with matching coverage
for the system compositor. Zero-alpha additive emission works in SceneKit's
desktop overlay but can disappear from the separate transparent iOS view.

## Networking

Client and server always talk through `NetChannel`, even for single player
(in-process loopback), so the online and local paths use the same protocol. The protocol is
versioned (`PROTOCOL_VERSION`); clients check the game data identity (`CS_GAME`,
a hash of the ship definitions) before entering. [Tools/NETWORK.md](Tools/NETWORK.md)
describes LAN configuration and manual device testing.

Campaign flights are private. The LAN front end explicitly opens a listen
server, advertises `_kestrel._udp` through Bonjour, shows connected pilots and
lets the host start a dogfight. The game module's typed `LevelRules` select
deathmatch scoring, opposing player teams, respawns and match limits; `CS_MODE`
keeps these results separate from campaign progress. UDP gameplay is unicast.

## Console

Configuration is cvars and commands, Quake 2 style: from the command line
(`+set name value`, `+map 3`), `.cfg` files or code. There are no environment
variables. [CONSOLE.md](CONSOLE.md) lists the commands and cvars.

## Building

`build.sh` drives `make` (Makefile, `Tools/iOS.mk`):

- `./build.sh`: macOS app at `build/KestrelFrontier.app`, every game module in
  `PlugIns/`.
- `./build.sh ios-simulator` / `ios-device` / `iphone` / `ipad`: iOS builds and
  deployment.
- `GAME=<name> ./build.sh`: the default game.

`KestrelFrontier.xcodeproj` is generated by `Tools/Xcode/generate.py` from the
source tree; regenerate it after adding, moving or removing source files rather
than editing it. See [Tools/IOS.md](Tools/IOS.md).

## Checks

`./Tools/run-unit-checks.sh` compiles and runs the headless unit tests, string
contracts and story-continuity unit tests within a hard 10-second total budget.
CI runs only that command. Builds, rendering, device connection checks and visual
inspection are manual development work, not additional automated test jobs.
