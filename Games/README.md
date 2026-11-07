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
