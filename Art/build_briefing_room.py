# Builds the CNS Bastion briefing room and exports
#   Resources/Models/BriefingRoom.obj     the hall, kitbashed (baked to .scn by build.sh)
#   Resources/Briefing/BriefingRoom.json  camera shots, the screen rectangle and
#                                         where people sit and stand, in game space
#
#   Blender -b --factory-startup --python Art/build_briefing_room.py
#   ROOM_PREVIEW=<png> also renders the wide shot with EEVEE.
#
# Needs the Shipyard kit (Art/kit/fetch.sh). See Art/README.md.
#
# Space: Blender metres, +Z up, +Y toward the screen; the floor in front of
# the stage steps is the origin. The OBJ export maps Blender +Y to -Z, so in
# the game the screen is down -Z from the audience.
#
# Naming contract with Sources/Engine/Render/BriefingRoom.m:
#   objects    Room       the hall, one multi-material mesh
#              Outside    the cruiser seen through the window
#              Crowd      sprite planes, Sprite_<Kind>_<n> (see below)
#   materials  Screen_Briefing  flat quad, UV 0..1: the live presentation
#              Glow_<Colour>    self-lit (Amber, Warm, Cyan, Red)
#              Wall, Panel, Metal, Dark, Floor, Stage, Seat, Rail, Banner,
#              Gold, Bezel, Hull, HullDark   lit PBR, box-projected UVs at
#              TILE metres per unit (Hull: 24 m) for the game's tiling sets
#
# People are not modelled. Each is a plane (object Crowd) with material
# Sprite_Seated_<n> (from behind, 0.72 x 1.0 m, bottom edge at the waist,
# SEAT_LIFT above the cushion) or Sprite_Standing_<n> (balconies, feet on
# the floor, 1.37 x 1.9 m); the game
# textures it with Resources/Briefing/Crowd/<Kind>_<n>.png.

import bpy
import json
import math
import os
import random
import sys
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from kitbash import Mesh, Kit, box, chamfer_box, quad, cyl, polyline   # noqa: E402

ROOT = os.path.dirname(HERE)
OUT = os.path.join(ROOT, "Resources", "Models", "BriefingRoom.obj")
ANCHORS = os.path.join(ROOT, "Resources", "Briefing", "BriefingRoom.json")
TILE = 4.0
rng = random.Random(7)

for o in list(bpy.data.objects):
    bpy.data.objects.remove(o, do_unlink=True)
for c in (bpy.data.meshes, bpy.data.curves, bpy.data.materials, bpy.data.cameras, bpy.data.lights):
    for d in list(c):
        c.remove(d)
scene = bpy.context.scene
scene.unit_settings.system = 'METRIC'

# ---------------------------------------------------------------- materials
# Colours here only matter for the Blender preview; the game restyles every
# material by name (BriefingRoom.m).

def material(name, color, rough=0.5, metal=0.0, emit=None, strength=6.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    bsdf = m.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = (*color, 1)
    bsdf.inputs["Roughness"].default_value = rough
    bsdf.inputs["Metallic"].default_value = metal
    if emit:
        bsdf.inputs["Emission Color"].default_value = (*emit, 1)
        bsdf.inputs["Emission Strength"].default_value = strength
    m.diffuse_color = (*color, 1)
    return m

MATS = {
    "Wall": material("Wall", (0.10, 0.105, 0.11), 0.6, 0.4),
    "Panel": material("Panel", (0.16, 0.16, 0.165), 0.45, 0.6),
    "Metal": material("Metal", (0.30, 0.29, 0.27), 0.35, 0.85),
    "Dark": material("Dark", (0.03, 0.032, 0.036), 0.5, 0.3),
    "Floor": material("Floor", (0.07, 0.075, 0.085), 0.3, 0.5),
    "Stage": material("Stage", (0.12, 0.13, 0.145), 0.18, 0.6),
    "Seat": material("Seat", (0.05, 0.05, 0.055), 0.7, 0.1),
    "Rail": material("Rail", (0.55, 0.40, 0.22), 0.3, 1.0),
    "Banner": material("Banner", (0.30, 0.04, 0.05), 0.8, 0.0),
    "Gold": material("Gold", (0.80, 0.58, 0.25), 0.3, 1.0),
    "Bezel": material("Bezel", (0.02, 0.022, 0.026), 0.35, 0.3),
    "Hull": material("Hull", (0.35, 0.37, 0.4), 0.5, 0.6),
    "HullDark": material("HullDark", (0.12, 0.13, 0.15), 0.5, 0.6),
    "Screen_Briefing": material("Screen_Briefing", (0, 0, 0), 0.2, 0.0, emit=(0.02, 0.08, 0.14), strength=1),
    "Glow_Amber": material("Glow_Amber", (0.05, 0.04, 0.02), 0.4, 0.0, emit=(1.0, 0.55, 0.2)),
    "Glow_Warm": material("Glow_Warm", (0.05, 0.04, 0.03), 0.4, 0.0, emit=(1.0, 0.8, 0.55)),
    "Glow_Cyan": material("Glow_Cyan", (0.02, 0.05, 0.06), 0.4, 0.0, emit=(0.2, 0.85, 1.0)),
    "Glow_Red": material("Glow_Red", (0.05, 0.01, 0.01), 0.4, 0.0, emit=(1.0, 0.15, 0.1)),
}

KIT = Kit(os.path.join(HERE, "kit", "Shipyard.blend"),
          mats={"Glass": "Glow_Amber", "Flat.001": "Dark", "Wire": "Metal", "Wire fade": "Metal"})
room = Mesh("Room", tile=TILE, tiles={"Floor": 2.0, "Stage": 3.0})
outside = Mesh("Outside", tile=24.0)
kit = KIT.place

# ---------------------------------------------------------------- layout
#
#   x  -15 .. 15     side walls (balconies on both, 3.6 m deep)
#   y  -16 .. 12     back of the hall .. screen wall
#   z    0 .. 15     floor .. ceiling
W, BACK, FRONT, H = 15.0, -16.0, 12.0, 15.0
STAGE_Y, STAGE_H = 1.5, 0.9           # stage front edge and height
SCREEN = (-8.0, 8.0, 4.4, 11.4)       # x0, x1, z0, z1 on the front wall
BAL_D = 3.6                           # balcony depth
TIERS = (4.6, 8.8)                    # balcony floor heights
WINDOW = (-11.0, 3.0, TIERS[1] + 1.5, H - 1.0)   # y0, y1, z0, z1, left wall
anchors = []
crowd = Mesh("Crowd")
SPRITES = 6                           # variants per kind: Sprite_<Kind>_1..6
SPRITE_SIZE = {"Seated": (0.72, 1.0), "Standing": (1.37, 1.9)}   # both 0.72:1, like the art
SEAT_LIFT = 0.25                      # seated sprites start at the waist
VIEW = Vector((0.0, -14.6, 4.0))      # the wide shot's eye

def anchor(kind, p, facing):
    """A person: one upright quad, bottom edge on `p`, facing `facing`, with
    UVs 0..1 and material Sprite_<kind>_<n> for the game to texture."""
    p, f = Vector(p), Vector(facing).normalized()
    w, h = SPRITE_SIZE[kind]
    right = (-f).cross(Vector((0, 0, 1))).normalized() * (w / 2)
    up = Vector((0, 0, h))
    name = "Sprite_%s_%d" % (kind, rng.randint(1, SPRITES))
    if name not in MATS:
        MATS[name] = material(name, (0.02, 0.02, 0.025), 0.8)
    quad(crowd, [p - right, p + right, p + right + up, p - right + up], name)
    anchors.append(name)

GREEBLES = ["plumbBlock", "checkBlock", "ventPortBlock", "tooCompBlock", "splitBlock", "falseBlock",
            "hardpoint.dev.flush", "hardpoint.dev.lowPro", "hardPoint.dev.Clunk", "hardpoint.base.clip",
            "Res Block", "wrenchPlug", "Cube.002", "block.bird"]

def greeble_strip(axis, fixed, a0, a1, lo, hi, depth, rng, density=0.9, mat="Metal"):
    """Kit greebles along a wall strip. axis 'x': the wall is the plane
    x = fixed (depth > 0 sticks out toward +x); along y from a0 to a1, at
    heights lo..hi. axis 'y' likewise on the plane y = fixed, along x."""
    t = a0
    while t < a1:
        w = rng.uniform(0.6, 1.8)
        if rng.random() < density:
            h = rng.uniform(0.3, 1.0) * (hi - lo)
            z = rng.uniform(lo + h / 2, hi - h / 2)
            d = abs(depth) * rng.uniform(0.4, 1.0)
            s = math.copysign(1, depth)
            part = rng.choice(GREEBLES)
            if axis == 'x':
                kit(room, part, (fixed + s * d / 2, t + w / 2, z), size=(d, w, h), mat=mat)
            else:
                kit(room, part, (t + w / 2, fixed + s * d / 2, z), size=(d, w, h), rot=(0, 0, 90), mat=mat)
        t += w + rng.uniform(0.05, 0.4)

# ---- shell
box(room, (-W, BACK, -0.2), (W, FRONT, 0), "Floor")
box(room, (-W, BACK, H), (W, FRONT, H + 0.3), "Dark")
box(room, (-W, BACK - 0.4, 0), (W, BACK, H), "Wall")
greeble_strip('y', BACK, -W + BAL_D, W - BAL_D, 3.5, H - 1.5, 0.5, rng, mat="Panel")
box(room, (-3, BACK, 0), (3, BACK + 0.15, 3.5), "Panel")                       # main doors
box(room, (-0.04, BACK + 0.15, 0), (0.04, BACK + 0.2, 3.2), "Dark")
box(room, (-1.2, BACK + 0.15, 3.7), (1.2, BACK + 0.22, 4.0), "Glow_Amber")

# Ceiling: deep beams front to back, cross ribs with downlights, ducts and
# machinery between the beams.
BEAMS = (-11.5, -6.5, -2.2, 2.2, 6.5, 11.5)
for x in BEAMS:
    chamfer_box(room, (x - 0.4, BACK, H - 1.4), (x + 0.4, FRONT, H), "Panel", c=0.15)
    box(room, (x - 0.42, BACK, H - 1.45), (x + 0.42, FRONT, H - 1.38), "Metal")
for y in range(int(BACK) + 2, int(FRONT), 4):
    chamfer_box(room, (-W, y - 0.3, H - 0.8), (W, y + 0.3, H), "Metal", c=0.1)
    for a, b in zip(BEAMS, BEAMS[1:]):
        x = (a + b) / 2
        box(room, (x - 0.6, y - 0.12, H - 0.84), (x + 0.6, y + 0.12, H - 0.8), "Glow_Warm")
for a, b in zip(BEAMS, BEAMS[1:]):
    x = (a + b) / 2
    w = b - a - 1.0
    for y in range(int(BACK) + 4, int(FRONT), 4):
        if rng.random() < 0.7:
            kit(room, rng.choice(["Vent Block", "hull.Grill", "Build-up Block", "checkBlock"]),
                (x, y - 2.0, H - 0.35), size=(w * rng.uniform(0.5, 0.9), 3.0, 0.6), rot=(180, 0, 0), mat="Dark")
    polyline(room, [(x - w / 2 + 0.2, BACK, H - 1.0), (x - w / 2 + 0.2, FRONT, H - 1.0)], 0.12, "Metal")

# ---- front wall: the screen in a stepped bezel, pilasters with sconces
x0, x1, z0, z1 = SCREEN
box(room, (-W, FRONT, 0), (x0 - 1.2, FRONT + 0.5, H), "Wall")
box(room, (x1 + 1.2, FRONT, 0), (W, FRONT + 0.5, H), "Wall")
box(room, (x0 - 1.2, FRONT, z1 + 1.0), (x1 + 1.2, FRONT + 0.5, H), "Wall")
box(room, (x0 - 1.2, FRONT, 0), (x1 + 1.2, FRONT + 0.5, z0 - 1.0), "Wall")
for (lo, hi) in (((x0 - 1.2, FRONT - 0.4, z0 - 1.0), (x1 + 1.2, FRONT, z0 - 0.15)),
                 ((x0 - 1.2, FRONT - 0.4, z1 + 0.15), (x1 + 1.2, FRONT, z1 + 1.0)),
                 ((x0 - 1.2, FRONT - 0.4, z0 - 1.0), (x0 - 0.15, FRONT, z1 + 1.0)),
                 ((x1 + 0.15, FRONT - 0.4, z0 - 1.0), (x1 + 1.2, FRONT, z1 + 1.0))):
    chamfer_box(room, lo, hi, "Panel", c=0.12)
box(room, (x0 - 0.15, FRONT - 0.08, z0 - 0.15), (x1 + 0.15, FRONT, z1 + 0.15), "Bezel")
# Cyan edge light, chamfered at the corners, just inside the bezel.
cc = 0.45
edge = [(x0 + cc, z0), (x1 - cc, z0), (x1, z0 + cc), (x1, z1 - cc), (x1 - cc, z1), (x0 + cc, z1), (x0, z1 - cc), (x0, z0 + cc)]
for a, b in zip(edge, edge[1:] + edge[:1]):
    cyl(room, (a[0], FRONT - 0.12, a[1]), (b[0], FRONT - 0.12, b[1]), 0.04, mat="Glow_Cyan", segs=6)
sy = FRONT - 0.1
quad(room, [(x0, sy, z0), (x1, sy, z0), (x1, sy, z1), (x0, sy, z1)], "Screen_Briefing")
for x in (-6.0, 0.0, 6.0):
    box(room, (x - 0.9, FRONT - 0.44, z1 + 0.5), (x + 0.9, FRONT - 0.4, z1 + 0.75), "Glow_Amber")
# A duct run over the screen, kit machinery either side of it.
kit(room, "Vent Block", (0, FRONT - 0.6, z1 + 2.2), size=(1.2, 17.0, 1.4), rot=(0, 0, 90), mat="Metal")
greeble_strip('y', FRONT, x0 - 1.0, x1 + 1.0, z1 + 3.0, H - 0.9, -0.6, rng)

for side in (-1, 1):
    px = side * (x1 + 2.1)
    chamfer_box(room, (px - 0.85, FRONT - 1.0, 0), (px + 0.85, FRONT, H), "Panel", c=0.25)
    chamfer_box(room, (px - 1.05, FRONT - 1.2, H - 2.6), (px + 1.05, FRONT, H - 1.4), "Metal", c=0.2)
    chamfer_box(room, (px - 1.05, FRONT - 1.2, 0), (px + 1.05, FRONT, 1.2), "Metal", c=0.2)
    for z in (5.0, 9.8):
        box(room, (px - 0.32, FRONT - 1.1, z - 0.85), (px + 0.32, FRONT - 1.0, z + 0.85), "Metal")
        box(room, (px - 0.2, FRONT - 1.16, z - 0.7), (px + 0.2, FRONT - 1.1, z + 0.7), "Glow_Amber")
    for z in range(2, 14, 2):
        box(room, (px - 0.86, FRONT - 1.01, z), (px + 0.86, FRONT - 0.95, z + 0.05), "Dark")
    # Between pilaster and side wall: a wall of machinery.
    a0, a1 = sorted((side * (x1 + 3.0), side * (W - BAL_D)))
    greeble_strip('y', FRONT, a0, a1, 1.0, H - 1.0, -0.8, rng, mat="Panel")

# Under the screen: recessed panels with lamps.
for i in range(6):
    cx = x0 + 0.6 + i * (x1 - x0 - 1.2) / 5
    chamfer_box(room, (cx - 1.2, FRONT - 0.3, STAGE_H + 0.5), (cx + 1.2, FRONT, z0 - 1.3), "Panel", c=0.08)
    box(room, (cx - 0.55, FRONT - 0.36, z0 - 2.0), (cx + 0.55, FRONT - 0.3, z0 - 1.75), "Glow_Amber")
    kit(room, rng.choice(GREEBLES), (cx, FRONT - 0.45, STAGE_H + 1.1), size=(0.3, 1.6, 0.7), rot=(0, 0, 90), mat="Metal")

# ---- stage, three broad steps, lit risers
box(room, (-W + BAL_D, STAGE_Y, 0), (W - BAL_D, FRONT, STAGE_H), "Stage")
for i in range(3):
    h = STAGE_H * (i + 1) / 4
    y = STAGE_Y - 0.45 * (3 - i)
    box(room, (-9.5 + i * 0.3, y, 0), (9.5 - i * 0.3, STAGE_Y, h), "Stage")
    for side in (-1, 1):
        sx = side * (8.0 + i * 0.1)
        box(room, (sx - 1.0, y - 0.01, h - 0.08), (sx + 1.0, y, h - 0.03), "Glow_Amber")
for x in range(-10, 11, 2):
    box(room, (x - 0.25, STAGE_Y - 0.02, STAGE_H - 0.12), (x + 0.25, STAGE_Y, STAGE_H - 0.06), "Glow_Warm")
# A lectern, stage left.
chamfer_box(room, (-6.4, 4.0, STAGE_H), (-5.4, 4.7, STAGE_H + 1.15), "Metal", c=0.1)
box(room, (-6.45, 3.95, STAGE_H + 1.15), (-5.35, 4.75, STAGE_H + 1.22), "Panel")
box(room, (-6.3, 3.94, STAGE_H + 0.7), (-5.5, 3.96, STAGE_H + 0.78), "Glow_Cyan")

# ---- side walls: two balcony tiers, doors below, window and banner up top
for side in (-1, 1):
    wx = side * W
    wlo, whi = sorted((wx, wx + side * 0.4))
    if side < 0:
        wy0, wy1, wz0, wz1 = WINDOW
        box(room, (wlo, BACK, 0), (whi, FRONT, wz0), "Wall")
        box(room, (wlo, BACK, wz1), (whi, FRONT, H), "Wall")
        box(room, (wlo, BACK, wz0), (whi, wy0, wz1), "Wall")
        box(room, (wlo, wy1, wz0), (whi, FRONT, wz1), "Wall")
        chamfer_box(room, (wx, wy0 - 0.5, wz0 - 0.6), (wx + 0.7, wy1 + 0.5, wz0), "Metal", c=0.15)
        chamfer_box(room, (wx, wy0 - 0.5, wz1), (wx + 0.7, wy1 + 0.5, wz1 + 0.6), "Metal", c=0.15)
        chamfer_box(room, (wx, wy0 - 0.5, wz0), (wx + 0.7, wy0, wz1), "Metal", c=0.15)
        chamfer_box(room, (wx, wy1, wz0), (wx + 0.7, wy1 + 0.5, wz1), "Metal", c=0.15)
        for k in range(1, 5):
            y = wy0 + (wy1 - wy0) * k / 5
            box(room, (wx - 0.1, y - 0.1, wz0), (wx + 0.25, y + 0.1, wz1), "Panel")
        box(room, (wx - 0.1, wy0, wz0 + 1.2), (wx + 0.25, wy1, wz0 + 1.35), "Panel")
        for k in range(5):
            y = wy0 + (wy1 - wy0) * (k + 0.5) / 5
            box(room, (wx + 0.55, y - 0.5, wz1 - 0.06), (wx + 0.72, y + 0.5, wz1), "Glow_Amber")
    else:
        box(room, (wlo, BACK, 0), (whi, FRONT, H), "Wall")
        bx = wx - 0.3
        top, bot = H - 1.4, TIERS[1] + 1.7
        quad(room, [(bx, 0.0, bot), (bx, -2.6, bot), (bx, -2.6, top), (bx, 0.0, top)], "Banner")
        quad(room, [(bx, -2.6, bot), (bx, -1.3, bot - 0.6), (bx, -1.3, bot), (bx, -2.6, bot)], "Banner")
        quad(room, [(bx, -1.3, bot - 0.6), (bx, 0.0, bot), (bx, -1.3, bot), (bx, -1.3, bot - 0.6)], "Banner")
        cyl(room, (bx, 0.3, top + 0.1), (bx, -2.9, top + 0.1), 0.07, mat="Gold")
        e = bx - 0.03
        polyline(room, [(e, -1.3, top - 1.0), (e, -0.7, top - 2.1), (e, -1.3, top - 1.8), (e, -1.9, top - 2.1), (e, -1.3, top - 1.0)], 0.06, "Gold")
        polyline(room, [(e, -1.3, top - 1.3), (e, -1.3, top - 3.0)], 0.05, "Gold")
        for k in range(7):
            a = math.radians(200 + k * 20)
            polyline(room, [(e, -1.3 + 1.0 * math.cos(a), top - 2.0 + 1.0 * math.sin(a)),
                            (e, -1.3 + 1.15 * math.cos(a + 0.2), top - 2.0 + 1.15 * math.sin(a + 0.2))], 0.05, "Gold")
            polyline(room, [(e, -1.3 - 1.0 * math.cos(a), top - 2.0 + 1.0 * math.sin(a)),
                            (e, -1.3 - 1.15 * math.cos(a + 0.2), top - 2.0 + 1.15 * math.sin(a + 0.2))], 0.05, "Gold")
    # Pilasters along the wall, wall machinery between them.
    for y in range(int(BACK) + 2, int(FRONT) - 1, 4):
        if side < 0 and WINDOW[0] - 1 < y < WINDOW[1] + 1:
            zt = WINDOW[2] - 0.6
        else:
            zt = H
        lo_x, hi_x = sorted((wx, wx - side * 0.35))
        chamfer_box(room, (lo_x, y - 0.35, 0), (hi_x, y + 0.35, zt), "Panel", c=0.1)
        greeble_strip('x', wx, y + 0.45, y + 3.55, TIERS[0] + 1.3, TIERS[1] - 0.6, -side * 0.4, rng, density=0.6)
        greeble_strip('x', wx, y + 0.45, y + 3.55, 3.2, TIERS[0] - 1.0, -side * 0.3, rng, density=0.4)

    edge_x = wx - side * BAL_D
    lo_x, hi_x = sorted((wx, edge_x))
    for z in TIERS:
        y0, y1 = BACK + 1.0, FRONT - 1.4
        box(room, (lo_x, y0, z - 0.45), (hi_x, y1, z), "Panel")
        f0, f1 = sorted((edge_x - side * 0.15, edge_x + side * 0.05))
        chamfer_box(room, (f0, y0, z - 0.9), (f1, y1, z + 0.1), "Metal", c=0.06)
        for y in range(int(y0) + 1, int(y1), 2):
            box(room, (edge_x - 0.25, y - 0.15, z - 0.95), (edge_x + 0.25, y + 0.15, z - 0.9), "Glow_Warm")
        # End caps of the balcony.
        for y in (y0, y1):
            chamfer_box(room, (lo_x, y - 0.2, z - 0.9), (hi_x, y + 0.2, z + 1.1), "Metal", c=0.08)
        rx = edge_x + side * 0.1
        posts = int((y1 - y0) / 1.5)
        for i in range(posts + 1):
            y = y0 + (y1 - y0) * i / posts
            cyl(room, (rx, y, z), (rx, y, z + 1.05), 0.035, mat="Rail", segs=6)
        cyl(room, (rx, y0, z + 1.05), (rx, y1, z + 1.05), 0.05, mat="Rail", segs=8)
        cyl(room, (rx, y0, z + 0.55), (rx, y1, z + 0.55), 0.025, mat="Rail", segs=6)
        y = y0 + 0.6
        while y < y1 - 0.4:
            if rng.random() < 0.75:
                q = Vector((rx + side * rng.uniform(0.45, 0.9), y, z))
                # Facing the room, turned partly toward the back of the hall.
                anchor("Standing", q, Vector((-side, 0, 0)) + 0.6 * (VIEW - q).normalized())
            y += rng.uniform(0.55, 0.9)
    # Floor-level doors under the lower balcony, with sconces between.
    for y in (-11.0, -4.0, 4.0):
        d0, d1 = sorted((wx - side * 0.02, wx - side * 0.3))
        chamfer_box(room, (d0, y - 0.9, 0), (d1, y + 0.9, 2.7), "Panel", c=0.08)
        box(room, (d0 - 0.01, y - 0.03, 0), (d1 + 0.01, y + 0.03, 2.6), "Dark")
        box(room, (d0 - 0.01, y - 1.1, 2.7), (d1 + 0.01, y + 1.1, 2.9), "Metal")
        box(room, (d0 - 0.02, y - 0.45, 3.1), (d1 + 0.02, y + 0.45, 3.3), "Glow_Amber")
    for y in (-7.5, 0.0, 8.0):
        s0, s1 = sorted((wx - side * 0.02, wx - side * 0.18))
        box(room, (s0, y - 0.15, 2.3), (s1, y + 0.15, 3.5), "Glow_Amber")

# ---- audience: rows of seats on a slight rake, centre aisle
ROWS, ROW0, PITCH, RAKE = 8, -1.6, 1.45, 0.16
SEAT_W = 0.78
for r in range(ROWS):
    y = ROW0 - r * PITCH
    z = r * RAKE
    if r:
        box(room, (-W + BAL_D + 0.4, y - PITCH / 2, 0), (W - BAL_D - 0.4, y + PITCH / 2, z), "Floor")
    x = 0.95
    xs = []
    while x < 10.6:
        xs += [x, -x]
        x += SEAT_W
    for x in xs:
        box(room, (x - 0.31, y - 0.12, z + 0.42), (x + 0.31, y + 0.4, z + 0.54), "Seat")
        chamfer_box(room, (x - 0.33, y - 0.3, z + 0.4), (x + 0.33, y - 0.12, z + 1.12), "Seat", c=0.06)
        box(room, (x - 0.33, y - 0.31, z + 1.06), (x + 0.33, y - 0.13, z + 1.1), "Rail")
        box(room, (x + 0.33, y - 0.2, z), (x + 0.41, y + 0.35, z + 0.7), "Metal")
        if rng.random() < 0.88:
            anchor("Seated", (x + rng.uniform(-0.04, 0.04), y, z + 0.42 + SEAT_LIFT), (0, -1, 0))   # back to the camera
    for sx in (-0.5, 0.5):
        box(room, (sx - 0.04, y - 0.55, z + 0.03), (sx + 0.04, y + 0.15, z + 0.07), "Glow_Amber")

# ---- the cruiser alongside, seen through the window (kit BattleShip)
lo, hi = kit(outside, "BattleShip", (-95, 20, 26), size=(None, 140, None), rot=(4, 0, -14), mat="Hull",
             mats={"Flat.001": "HullDark", "Glass": "Glow_Warm"})
kit(outside, "ship", (-70, -40, 48), size=(None, 26, None), rot=(0, 0, 160), mat="Hull",
    mats={"Glass": "Glow_Warm"})
kit(outside, "ship", (-120, 70, 8), size=(None, 18, None), rot=(0, 0, -30), mat="Hull",
    mats={"Glass": "Glow_Warm"})

# ---------------------------------------------------------------- export

room.link(MATS)
outside.link(MATS)
crowd.link(MATS, recalc=False)
bpy.ops.wm.obj_export(filepath=OUT, export_selected_objects=False, forward_axis='NEGATIVE_Z', up_axis='Y',
                      apply_modifiers=True, export_uv=True, export_normals=True, export_materials=True,
                      export_triangulated_mesh=True, path_mode='STRIP')

def g(p):
    return [round(p[0], 3), round(p[2], 3), round(-p[1], 3)]

shots = {
    # Seated at the back, over the heads: the dialogue shot.
    "wide": {"eye": g((0.0, -14.6, 4.0)), "at": g((0.0, FRONT, 6.6)), "fov": 50},
    # Coming in from the doors: where the dialogue starts.
    "enter": {"eye": g((0.0, -15.6, 5.6)), "at": g((0.0, FRONT, 5.4)), "fov": 58},
    # The screen fills the frame: the tactical briefing.
    "screen": {"eye": g((0.0, -2.0, (z0 + z1) / 2)), "at": g((0.0, FRONT, (z0 + z1) / 2)), "fov": 40},
}
data = {"shots": shots,
        "screen": {"min": g((x0, sy, z0)), "max": g((x1, sy, z1))}}
with open(ANCHORS, "w") as f:
    json.dump(data, f, indent=1)
    f.write("\n")

# ---------------------------------------------------------------- preview

cam = bpy.data.objects.new("Wide", bpy.data.cameras.new("Wide"))
scene.collection.objects.link(cam)
cam.data.sensor_fit = 'VERTICAL'
cam.data.angle_y = math.radians(shots["wide"]["fov"])
cam.location = (0.0, -14.6, 4.0)
cam.rotation_euler = (Vector((0.0, FRONT, 6.6)) - cam.location).to_track_quat('-Z', 'Y').to_euler()
cam.data.clip_end = 1000
scene.camera = cam
scene.render.resolution_x, scene.render.resolution_y = 1600, 900
world = scene.world or bpy.data.worlds.new("World")
scene.world = world
world.use_nodes = True
world.node_tree.nodes["Background"].inputs["Color"].default_value = (0.004, 0.005, 0.012, 1)
for loc, energy, col in (((0, -4, 13), 9000, (1.0, 0.8, 0.6)), ((0, 8, 6), 3000, (0.4, 0.8, 1.0)),
                         ((-11, -4, 6.5), 1500, (1.0, 0.7, 0.4)), ((11, -4, 6.5), 1500, (1.0, 0.7, 0.4)),
                         ((0, -12, 8), 2500, (1.0, 0.85, 0.7))):
    light = bpy.data.objects.new("Light", bpy.data.lights.new("Light", 'POINT'))
    light.data.energy = energy
    light.data.color = col
    light.data.shadow_soft_size = 1.5
    light.location = loc
    scene.collection.objects.link(light)
sun = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", 'SUN'))
sun.data.energy = 3
sun.rotation_euler = (math.radians(50), 0, math.radians(-60))
scene.collection.objects.link(sun)
scene.render.engine = 'BLENDER_EEVEE'
scene.view_settings.view_transform = 'AgX'
preview = os.environ.get("ROOM_PREVIEW", "")
if preview:
    scene.render.filepath = preview
    bpy.ops.render.render(write_still=True)
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(HERE, "BriefingRoom.blend"))
tris = sum(len(p.vertices) - 2 for o in scene.objects if o.type == 'MESH' for p in o.data.polygons)
result = {"exported": OUT, "people": len(anchors), "triangles": tris}
print(result)
