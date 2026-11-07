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
| `App/` | `Host`, the application loop and state machine (menus, loading, mission); the platform views; touch flight controls; `main`. |
| `Server/` | Hosts the game module through `GameImport`/`GameExport`, ticks it at `TICK_RATE` (30 Hz) and sends delta-compressed snapshots. `GameLoader` picks the game (`fs_game`) and finds its module. |
| `Client/` | `Client`: connection, snapshots, interpolation, prediction of the player's ship. `ClientView`: turns a frame into renderer calls and fills the HUD and cockpit. Never imports SceneKit. |
| `Net/` | `NetChannel` (sequencing, reliable fragments), `NetMsg` (bit-level codec), `NetProtocol` (deltas), transports (in-process loopback, UDP), LAN discovery. |
| `Refresh/` | The renderer as the client sees it, after Quake 2's `refexport_t`: register models while loading, then describe each frame (entities, player, camera, effects). Also the HUD and `CockpitFrame`. No renderer types cross it. |
| `Render/` | `SceneKitRefresh`, the only Refresh backend, and what it draws with: ship and capital views, hull styles, exhaust, effects, cockpit, flight instruments, lens flare, sky, the FX recorder. |
| `Collision/` | `ModelInfo`: capital models' parts and subsystems for server traces and renderer dressing; baked-scene loading. |
| `Mission/` | The mission runtime (objectives, scripted events, scheduled arrivals and departures, win/lose rules) that runs a `LevelDef` against a `MissionWorld` the game supplies. Linked into game modules, not the engine binary. |
| `Story/` | The campaign and its story data: missions with briefings and debriefs, cast, rooms, briefing pages (immutable classes). |
| `UI/` | SpriteKit screens: `FrontEnd` (which screen shows), main menu, mission list/briefing/debrief (`Briefing`), loading card, pause menu, server browser, `ScreenHost` (transitions), `UILayout` (menus from JSON), `ScreenRegions` (header and centered body), theme and motion. Scenes compose `TitleBar` (back, title, icon commands) and `UISettingsForm` with content and callbacks; these controls own their layout and hit geometry. `UITouchControls` shares flight artwork, states and hit geometry between the native input adapter and standalone reference renderer. |
| `Input/` | Keyboard, mouse, controllers and touch into `InputAction` and a `ControlState`; pointer events for screens (`ScreenInput`). |
| `Audio/` | `GameAudio`: music, engine sound, effects, on a private queue. |

`Games/<name>/Game/` is a game module (see [Games/README.md](Games/README.md) for the
whole game folder). `Tools/` holds build helpers, validators and the check suites.

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
| `Levels/*.json` | `LevelDef` (+ nav, entity, wave, field, objective, rules structs) | Shared |
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
  a file changes the next rebuild.

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

Threads: the render thread runs the frame. Loading a mission (building the world,
registering and uploading models) runs on a background load queue while nothing
is drawn; the hand-off points are marked in `Client.h` and `Refresh.h`. Audio runs
on its own queue.

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
