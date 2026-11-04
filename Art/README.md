# Art pipeline

Every 3D asset and generated texture in the game is made by a Python script
in this folder that runs inside Blender. Nothing is edited by hand in a
`.blend` and then exported: change the script, rerun it, rebuild. That keeps
assets reviewable as code and reproducible from a clean checkout.

| Script | Makes | Ships as |
|---|---|---|
| `build_capitals.py` | capital ships, stations, props, rocks | `Resources/Models/Capital/*.obj` |
| `build_cockpit.py` | the player cockpit | `Resources/Models/Cockpit.obj` |
| `build_briefing_room.py` | the CNS Bastion briefing room | `Resources/Models/BriefingRoom.obj`, `Resources/Briefing/BriefingRoom.json` |
| `build_hull_textures.py` | tiling PBR texture sets (hulls; `tech*`: the Doom 3 style interior) | `Resources/Textures/<set>_*` |
| `kitbash.py` | shared helpers (mesh builder, primitives, kit loader) | — |

`build.sh` bakes every OBJ into SceneKit `.scn` (`Tools/BakeModels.m`); the
game only loads the baked files.

## Running

```bash
Art/kit/fetch.sh
```

Downloads the CC0 Shipyard kitbash set once (it isn't in git).

```bash
/Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup --python Art/build_briefing_room.py
```

Every builder runs headless the same way. Most take a preview variable that
renders a still with EEVEE, e.g. `ROOM_PREVIEW=/tmp/room.png`,
`CAPITAL_PREVIEW=/tmp/caps/`, `COCKPIT_PREVIEW=/tmp/cockpit.png`.

```bash
./build.sh run
```

Bakes and launches. `SF_BRIEFING=3 SF_UNLOCK_ALL=1` opens mission 3's
dialogue in the briefing room, and `SF_BRIEFING=1` opens a tactical briefing.
`SF_SNAPSHOT=/tmp/shot` saves three frames and quits (`SF_SNAPGAP` sets the
seconds between them; `SF_SNAPNOUI=1` leaves the menus out). The briefing
room's lamps cast stencil shadows (`StencilShadows.m`): `SF_STENCIL=0` puts
SceneKit's plain lamps back, `SF_STENCIL=lit` keeps ours unshadowed, and
`SF_STENCIL_DEBUG=1` paints the first three lamps' masks as red, green and
blue. `SF_FPS=1` logs the frame rate.

With the Blender MCP add-on running, the same scripts can be run in a live
Blender session (`exec(open(path).read())` through `execute_blender_code`),
which leaves the result open for inspection. The `.blend` a builder saves
(e.g. `Art/BriefingRoom.blend`) is output, not a source.

## Conventions

- **Space.** Blender metres, +Z up, +Y forward (the bow, or toward the
  briefing screen). The OBJ export uses `forward_axis='NEGATIVE_Z', up_axis='Y'`,
  so Blender (x, y, z) is game (x, z, -y). Anything a script writes to JSON
  is converted the same way.
- **Names are the contract.** The game finds parts by object name
  (`Turret_<n>`, `Engine_<n>`, `Stick`, `Room`, `Crowd`) and dresses
  surfaces by material name. Each builder's header lists its names, and the
  matching `.m` file (`CapitalView.m`, `Cockpit.m`, `BriefingRoom.m`) styles
  them. Blender's own material colours are only for previews.
- **Special material prefixes.**
  - `Screen_<Name>`: a flat quad with UVs 0..1 that gets a live SpriteKit
    scene rendered into it every frame (cockpit MFDs, the briefing screen).
  - `Glow_<Colour>` / `Lamp_<Name>`: self-lit, drawn with intensity > 1 so
    the camera's bloom picks them up.
  - `Sprite_<Kind>_<n>`: a plane textured with
    `Resources/Briefing/Crowd/<Kind>_<n>.png`.
- **UVs are box-projected** at a fixed number of metres per UV unit
  (`Mesh(tile=…)`: 4 m in the room, 24 m on hulls), so tiling texture sets
  line up across parts without unwrapping. Quads that need exact 0..1 UVs
  (screens, sprites, the banner) pass them explicitly.
- **One mesh per role.** Parts accumulate into a few `Mesh` objects (one
  bmesh each) rather than thousands of Blender objects. Faces carry
  materials, and the OBJ has one `o` per object and one `usemtl` per
  material, which `Tools/ObjLoader.m` turns into one node with one geometry
  element per material.

## Kitbashing

`kitbash.Kit` loads every mesh in a `.blend` (modifiers applied), centres
each part on its bounds, and `place()` drops copies into a `Mesh`:

```python
from kitbash import Mesh, Kit, box, chamfer_box, cyl

KIT = Kit("Art/kit/Shipyard.blend", mats={"Glass": "Glow_Amber", "Flat.001": "Dark"})
room = Mesh("Room", tile=4.0)
# Fit "Vent Block" into a 1.2 x 17 x 1.4 m slot, turned to run along X.
KIT.place(room, "Vent Block", (0, 11.4, 13.6), size=(1.2, 17.0, 1.4), rot=(0, 0, 90), mat="Metal")
```

- `size` fits the part's bounds before rotation. Give `None` on an axis to
  keep proportion. `scale` is a plain factor instead. `rot` is XYZ degrees.
- The kit's own materials are remapped through `mats` (`Glass` becomes lit
  windows, and so on). Everything else takes `mat`.
- Parts that are hidden by other geometry don't have to be oriented
  correctly, and a non-uniform `size` turns any detailed block into wall
  machinery. `greeble_strip()` in `build_briefing_room.py` scatters random
  parts along a wall like that, partly sunk into it. A kit part reads as
  detail mostly through its silhouette and edges, so pick parts by shape and
  ignore what they were modelled to be.
- Useful interior greebles in the Shipyard set: `plumbBlock`,
  `checkBlock`, `ventPortBlock`, `tooCompBlock`, `splitBlock`, `Res Block`,
  `hardpoint.dev.*`, `Vent Block` and `hull.Grill` (ceiling and ducts).
  Whole ships for set dressing: `BattleShip`, `ship`.
- To list a kit's parts and sizes:

  ```bash
  Blender -b Art/kit/Shipyard.blend --python-expr "import bpy; [print(o.name, tuple(round(d, 2) for d in o.dimensions)) for o in bpy.data.objects if o.type == 'MESH']"
  ```

- Another CC0 kit: put its download in `Art/kit/fetch.sh`, add
  `Art/kit/<Name>.blend` to `.gitignore` (already covered by the pattern),
  load it with a second `Kit(...)`, and credit it in `CREDITS.md`.

Build the big shapes from primitives (`box`, `chamfer_box`, `cyl`,
`polyline`, `quad`) so proportions are exact and dimensioned in the script.
Then layer kit parts on top for detail, and finally emissive strips, which
do most of the work of making a dark interior read.

## Textures

`build_hull_textures.py` paints tiling PBR sets with numpy, on a torus (FFT
noise, wrapped kd panel splits), so they repeat seamlessly:
`<set>_color`, `_normal` (OpenGL convention), `_rough`, `_metal`, and `_emit`
(lit windows and running lights).

```bash
Blender -b --factory-startup --python Art/build_hull_textures.py -- bulkhead
```

```bash
cd Resources/Textures
```

```bash
for m in color rough; do sips -s format jpeg -s formatOptions 90 bulkhead_$m.png --out bulkhead_$m.jpg && rm bulkhead_$m.png; done
```

- A new set is one line in `SETS` at the bottom: `generate(name, seed,
  detail, paint, windows, big, tones)`. `detail` sets how many greebles,
  `paint` how many painted rather than bare-metal panels, `windows` the
  fraction of lit windows, `big` keeps large undivided plates, and `tones`
  is the albedo range.
- The game loads `<set>_<map>.jpg` or `.png`. Large colour and roughness
  maps go to JPEG to keep the repo small. Drop `_emit` for sets that never
  glow (the room doesn't load it).
- In game, a material uses a set through `Dress(m, @"bulkhead", tint, …,
  scale)` in `BriefingRoom.m` (`TexturedMaterial` in `CapitalView.m`). The
  colour map is tinted (multiply), and `scale` stretches the tile: the room's
  UVs run one unit per 4 m, so `0.25` gives one texture repeat per 16 m.
- Third-party sets (ambientCG, CC0) are resized to 2048 and renamed to the
  same `<set>_<map>` pattern. Credit them in `CREDITS.md`.

## The briefing room

- `Room`: the hall. Its front wall carries `Screen_Briefing`, which the
  briefing UI draws the tactical map into (`Briefing.presentation`, 1120 × 490
  points rendered at 2×).
- `Outside`: the kit cruiser beyond the left window. The procedural sky is
  the scene background, so the window needs no glass.
- `Crowd`: one upright plane per person.
  - `Sprite_Seated_<n>`: 0.72 × 1.0 m, facing the back of the hall (we see
    their backs). The bottom edge is at the waist, 0.25 m above the seat
    cushion (`SEAT_LIFT`), so heads and shoulders clear the 0.7 m seat backs.
  - `Sprite_Standing_<n>`: 1.37 × 1.9 m, soles on the balcony floor, facing
    the room and turned partly toward the camera.
  - Images go in `Resources/Briefing/Crowd/<Kind>_<n>.png` (n = 1..6), at
    288 × 400 px (0.72:1, the planes' aspect) on a transparent background,
    figure centred. Seated images run from the waist up, with the head in
    the upper part of the frame. Standing images run head to boots, with the
    soles on the bottom edge. Alpha is cut at 50%, and the images are drawn
    unlit, so bake the room's warm, low light into them. A plane whose
    image is missing is not drawn.
- `BriefingRoom.json`: camera shots (`enter`, `wide`) as eye, look-at and
  vertical FOV, plus the screen rectangle. The tactical shot is computed in
  `BriefingRoom.m` from the screen rectangle and the window's aspect, so the
  screen always fills the right of the frame.
