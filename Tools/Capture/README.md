# Staged gameplay renders

These scenes render the normal game assets, sky, exhaust, projectile ribbon
and HUD through `SceneKitRefresh`. They are authored compositions, rather than
captures of a live mission. No Simulator or input timing is required.

Build the macOS app, then render the store compositions at iPhone and iPad sizes:

```sh
./build.sh
./Tools/render-store-scenes.sh
```

The script writes six JPEGs into `fastlane/screenshots/en-US/`. Pass an output
directory as its first argument to keep experiments elsewhere. It does not upload.

To render one scene, including a quick preview:

```sh
build/KestrelFrontier.app/Contents/MacOS/KestrelFrontier \
  --render-scene Tools/Capture/torpedo-run.json /tmp/torpedo-preview.png 1280 590
```

`missile-evasion.json` is kept but no longer rendered for the store. Each JSON file preserves a composition:

| Field | Meaning |
|---|---|
| `skySeed` | The game's seeded space backdrop |
| `time` | Capture time in seconds; simulation steps at 60 Hz |
| `eye`, `lookAt`, `fov`, `roll` | Camera position, aim, field of view and bank in radians |
| `cockpit` | View from the first object's cockpit eye, with the cockpit interior and its live displays; `eye` and `lookAt` are ignored |
| `followPlayer` | Move the chase camera with the first object's velocity; enabled by default |
| `objective` | A normal localization token for the HUD |
| `objects` | Registered game models with capture positions, linear and local angular velocities, facing vectors, bank in radians, throttle, optional target labels and optional last-visible time `until` |
| `missiles` | A timed cubic path: launch, bend, approach and target points, with start time and duration; `fromPlayer` derives the launch history from the moving ship |
| `bolts` | Laser bolts in world space: `from`, `velocity`, `start`, `life` and `friendly` |
| `explosions` | The game's explosion effect: position, velocity, trigger time, scale and debris model |

Coordinates use game space: metres, +Y up, forward along -Z. The first object is
the player's ship. Models use the normal `ship:`, `cap:` and `proj:` names.
For `fromPlayer` missiles, `launch` is a ship-space muzzle offset. The launch
point is transformed by the ship's position and orientation at the firing time,
and the initial path tangent includes the ship's velocity plus its secondary
weapon's launch speed. The old wake remains in world space as the camera and
ship fly ahead; it can pass behind the camera. Other missile paths use world
coordinates, for flybys from other ships.

Missile paths are staged for composition; their flare and ribbon use the same
renderer as live gameplay. Older ribbon samples broaden and fade for two seconds
after emission. The warm wake is deliberately faint and additive, so scenery
remains visible through it.

The sun's lens flare appears whenever the sun is in view, as in the game. Ships facing the camera are lit only when the sun is behind it; `cockpit-formation.json` is turned so that it is.

Camera, geometry, timing and HUD layout are repeatable. SceneKit's exhaust
particles can vary slightly between runs. Keep visual review manual; this tool
is not a screenshot test suite or a CI gate.
