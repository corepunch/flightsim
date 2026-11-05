# Console

The engine is configured the way Quake 2 is: through **cvars** (named values
every module registers at init and reads at use) and **commands**, from the
command line, from `.cfg` files or from code. There are no environment
variables. `Sources/Common/Common.h` (Cvar, Cmd) is the implementation;
the game module reaches cvars through `GameImport`.

## Command line

Everything from the first `+` on is a command; each `+` starts a new one.
`+set` commands run before anything registers a cvar; the rest run once the
game has booted (or, for a dedicated server, once it is listening).

```sh
build/KestrelFrontier.app/Contents/MacOS/KestrelFrontier +set sv_cheats 1 +set g_god 1 +map 3
build/KestrelFrontier.app/Contents/MacOS/KestrelFrontier +connect 192.168.1.20
build/KestrelFrontier.app/Contents/MacOS/KestrelFrontier --dedicated 4 +set net_port 27911
xcrun simctl launch booted com.igor.spacefight +set in_touchOnly 1 +map 1
```

`--dedicated [mission]` and `--record-fx <effect> <out.mp4> [seconds]` are
process modes and stay as flags.

## Commands

| Command | What it does |
|---|---|
| `set <cvar> <value>` | Sets a cvar, creating it if nothing has registered it yet |
| `reset <cvar>` | Back to its default |
| `exec <file.cfg>` | Runs the commands in a file (absolute path, working directory, or app resources) |
| `echo <text>` | Prints |
| `cvarlist`, `cmdlist` | Lists every cvar / command with its help |
| `wait` | Defers the rest of the buffer to the next frame |
| `sleep <seconds>` | Defers the rest of the buffer |
| `map <n or level>` | Flies campaign mission n (1-based) or the mission flying that level (`02-cargo-run`); on a dedicated server, runs it |
| `briefing <n> [page]` | Opens that mission's briefing, optionally on a page |
| `connect <host[:port]>` | Joins that server |
| `disconnect` | Leaves the server or mission |
| `screenshot <file.png>` | Saves the next frame |
| `quit` | Exits |

A line that names a cvar prints it, or sets it when followed by a value.

## Cvars

Flags: **archive** persists in the user's defaults, **cheat** needs
`sv_cheats 1`, **noset** can only be set from the command line.

| Cvar | Default | Flags | Meaning |
|---|---|---|---|
| `sv_cheats` | 0 | | Allows cheat cvars to change |
| `fs_game` | the app's default game | noset | Game to run: a folder in `Games/` (its module is `PlugIns/<name>.dylib`) |
| `net_port` | 27910 | noset | UDP port the local server listens on; 0 turns hosting off |
| `net_stats` | 0 | | Logs bandwidth and prediction error every 5 s |
| `net_loss` | 0 | | Loopback: fraction of packets dropped |
| `net_latency` | 0 | | Loopback: simulated round trip, ms |
| `cl_predict` | 1 | | Predicts the player's ship between snapshots |
| `cl_cockpit` | 0 | archive | Cockpit camera (C toggles it) |
| `cl_autoStart` | 0 | | Skips the loading card's start prompt, for scripted runs |
| `cl_testInput` | 0 | cheat | A pilot who weaves and fires, for testing prediction |
| `cl_testFire` | 0 | cheat | Holds the trigger |
| `in_throttle` | 0 | | Throttle at launch |
| `in_touchOnly` | 0 | | iOS: ignores game controllers |
| `ui_timescale` | 1 | | Front-end motion runs this many times slower |
| `ui_reduceMotion` | | | Reduce front-end motion: 0 off, 1 on, empty follows the system setting |
| `ui_motion` | | | Front-end motion style: full, fade or none; empty follows the game's UI theme |
| `ui_unlockAll` | 0 | cheat | Every mission is open |
| `g_aimAssist` | 1 | archive | Scales the aim-assist cone of players' guns (ship `gun.assist`, degrees); 0 turns it off |
| `g_god` | 0 | cheat | Players take no damage |
| `g_autopilot` | 0 | cheat | The AI flies the first player's ship |
| `g_warp` | | cheat | Entity id to spawn the first player next to |
| `g_warpDistance` | 2.2 | cheat | `g_warp` distance, in radii |

## Scripts

A `.cfg` is one command per line (`;` also separates, `//` comments). With
`wait` and `sleep` it can drive a test:

```
set cl_testInput 1
map 1
sleep 8
screenshot ~/Desktop/mission1.png
sleep 2
quit
```

Run it with `+set sv_cheats 1 +exec drive.cfg`.
