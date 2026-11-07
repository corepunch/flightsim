# Games

Each folder here is one flight game built on the engine in `Sources/`. The
engine has no game content of its own. `fs_game <name>` picks the game; the
default is the app's `FSDefaultGame` (build with `GAME=<name> ./build.sh`).

```
Games/<name>/
  Game/          the game module: GMain (GetGameAPI), entities, AI, weapons, the level
                 runner over the engine's mission runtime. Built as PlugIns/<name>.dylib on
                 macOS; compiled into the app on iOS.
  Data/Ships/    ship definitions: mesh, guns, nozzles, flight params, AI params
  Data/Capitals/ capital ships and props: hp, class name, style, flags
  Data/Styles/   hull material sets
  Data/Projectiles/
  Data/Pickups/  what pilots collect by flying through: mesh, style, glow, torpedoes,
                 repair, respawn time
  Levels/        <name>.json: what the game module builds (entities, waves, navs,
                 objectives, events, loadout, pickups). "name" matches the file name.
  Campaign/      campaign.json: name, story, storyDefaults, and the missions in order,
                 each { "level": "<name>", "briefing": …, "debrief": … }
  Story/         characters.json (cast, player character), rooms.json (briefing rooms)
  Briefing/      portraits, Expressions/, Schematics/, room art
  Menu/          background.jpg (main menu), loading.png (loading card)
  Models/        .obj sources, baked to .scn when the app is bundled
  Textures/
  Strings/       <locale>.json: overrides and additions to the engine's catalog
  Art/           source art and generators (.blend, build_*.py) that write into
                 Models/, Textures/ and Briefing/. Not bundled.
```

Lookups go through `Sources/Shared/Shared.h`: the game's folder first,
then the engine's own `Resources/`. A game can therefore also replace the
engine's `UI/theme.json`, `UI/menus/*.json` or `Audio/*.mp3` by shipping a
file with the same path.

The theme's `"motion"` picks how the front end moves: `"full"` (the default:
text decodes, the wordmark glitches, scans sweep, panels are drawn by a beam),
`"fade"` (the same entrances as plain fades) or `"none"`. The system Reduce
Motion setting always turns it down to none.

`Tools/validate_story.py` checks every game's levels and campaign;
`Tools/validate_strings.py` checks every game's string catalogs.


User-visible content may use `{#catalog.key}` tokens. Objectives, weapon labels,
ship classes and cargo keep these tokens in the server data and wire strings;
clients expand them using their own language. Keep identifiers, assets, model
names and script references literal. Each shipped locale in `Strings/` must
translate the game's complete English catalog, including engine-key overrides,
so a generic engine translation cannot replace game-specific wording. The
current translation scope covers the interface, flight feedback and objectives;
briefing and debrief campaign conversations remain English; in-flight radio is translated.

## Dawn Patrol

`DawnPatrol` is an atmospheric-flight game using the Kestrel Frontier module and
its own campaign, aircraft, landscape, theme, art, sound and string catalogs.
Build with `GAME=DawnPatrol ./build.sh` to produce `build/DawnPatrol.app`. The console can also select it at startup:
`+set fs_game DawnPatrol +map 01-morning-patrol`.

The first sortie starts airborne in an S.E.5a with Bennett. Fly Saint-Martin,
Scarpe and Mercatel in order, intercept two Fokker D.VIIs at the river, then return
to the Bertincourt marker. Bennett's survival is optional. The return pass ends
the sortie; takeoff and landing are not implemented in this first mission.

Aircraft definitions opt into assisted atmospheric flight with `params.gravity`
and `params.stallSpeed`: lift falls with airspeed, banking loses vertical lift,
and boost is unavailable. Ground impact at y=0 is fatal for player and AI aircraft.
Landscape buildings and trees are visual scenery in this first slice.
`environment` on a level names the authored landscape, sky panorama and fog.

`Art/build_models.py` runs in Blender with `--background --factory-startup
--disable-autoexec --python` and reproduces the OBJ/MTL files from the preserved
CC0 source archive. `python3 Games/DawnPatrol/Art/build_audio.py` reproduces the
original synthesized sounds. Asset provenance and art prompts are in `Art/`.

Rooms select the typed `StoryBoardStyle` enum with `board.style` in
`Story/rooms.json`: `holographic` (the default) keeps the signal shader, grid and
animated readouts; `blackboard` draws static content directly inside the painted
board's `bezel` polygon, without those effects. Dawn Patrol uses `blackboard`.

A game may ship `default.cfg` for its initial cvars. Explicit `+set` launch
arguments override these defaults. Dawn Patrol starts the throttle at 80 percent
so its airborne start has flying speed.
