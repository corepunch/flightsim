# Builds the player cockpit and exports Resources/Models/Cockpit.obj.
#
# Run inside Blender (background is fine):
#   Blender -b Art/Cockpit.blend --python Art/build_cockpit.py
#
# Space: the pilot's eye is the origin, +Y is forward, +Z is up, metres.
# The OBJ export maps Blender +Y to -Z, matching the game's ship space.
#
# Naming contract with Sources/Cockpit.m (keyed by material name):
#   Screen_<Name>   flat quad, UV 0..1, gets a live SpriteKit texture
#   Lamp_<Name>     annunciator / LED, emission driven from game state
#   Stick, Throttle objects are animated (pivot = bottom of their bounds)
#   everything else is static trim (Panel, Frame, Trim, Rubber, Glass ...)

import bpy
import bmesh
import math
import os
from mathutils import Matrix, Vector

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Resources", "Models", "Cockpit.obj")

# Fresh scene.
for o in list(bpy.data.objects):
    bpy.data.objects.remove(o, do_unlink=True)
for coll in (bpy.data.meshes, bpy.data.curves, bpy.data.materials, bpy.data.cameras, bpy.data.lights):
    for d in list(coll):
        coll.remove(d)
scene = bpy.context.scene
scene.unit_settings.system = 'METRIC'

# ---------------------------------------------------------------- materials

def material(name, color, rough=0.5, metal=0.0, emit=None, alpha=1.0):
    m = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    m.use_nodes = True
    bsdf = m.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = (*color, 1)
    bsdf.inputs["Roughness"].default_value = rough
    bsdf.inputs["Metallic"].default_value = metal
    if emit:
        bsdf.inputs["Emission Color"].default_value = (*emit, 1)
        bsdf.inputs["Emission Strength"].default_value = 2.0
    if alpha < 1:
        bsdf.inputs["Alpha"].default_value = alpha
    m.diffuse_color = (*color, alpha)
    return m

M = {
    "Panel":  material("Panel",  (0.045, 0.05, 0.055), 0.65, 0.2),
    "Frame":  material("Frame",  (0.16, 0.17, 0.18), 0.35, 0.85),
    "Trim":   material("Trim",   (0.32, 0.33, 0.34), 0.45, 0.6),
    "Bezel":  material("Bezel",  (0.02, 0.022, 0.025), 0.4, 0.1),
    "Rubber": material("Rubber", (0.015, 0.015, 0.015), 0.9, 0.0),
    "Hazard": material("Hazard", (0.6, 0.42, 0.05), 0.5, 0.1),
    "Glass":  material("Glass",  (0.6, 0.9, 0.8), 0.05, 0.0, alpha=0.15),
    "Seat":   material("Seat",   (0.07, 0.065, 0.06), 0.85, 0.0),
}

def lamp_mat(name, color):
    return material("Lamp_" + name, (0.03, 0.03, 0.03), 0.3, 0.0, emit=color)

def screen_mat(name):
    return material("Screen_" + name, (0.0, 0.0, 0.0), 0.15, 0.0, emit=(0.1, 0.5, 0.45))

# ---------------------------------------------------------------- helpers

coll = scene.collection

def link(name, mesh, mat, smooth=False):
    o = bpy.data.objects.new(name, mesh)
    coll.objects.link(o)
    mesh.materials.append(mat)
    for p in mesh.polygons:
        p.use_smooth = smooth
    return o

def box(name, size, mat, at=Matrix.Identity(4), offset=(0, 0, 0), bevel=0.004, segments=2):
    """Box of `size` centred on `offset` in the frame `at`."""
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    bmesh.ops.scale(bm, vec=Vector(size), verts=bm.verts)
    bmesh.ops.translate(bm, vec=Vector(offset), verts=bm.verts)
    bmesh.ops.transform(bm, matrix=at, verts=bm.verts)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    o = link(name, me, mat)
    if bevel > 0:
        b = o.modifiers.new("Bevel", 'BEVEL')
        b.width = bevel
        b.segments = segments
        b.limit_method = 'ANGLE'
    return o

def quad(name, w, h, mat, at, offset=(0, 0, 0)):
    """UV-mapped quad facing +Z of the frame `at` (u right, v up)."""
    bm = bmesh.new()
    uv = bm.loops.layers.uv.new("UVMap")
    ox, oy, oz = offset
    vs = [bm.verts.new(at @ Vector((ox + x * w / 2, oy + y * h / 2, oz))) for x, y in ((-1, -1), (1, -1), (1, 1), (-1, 1))]
    f = bm.faces.new(vs)
    for loop, (u, v) in zip(f.loops, ((0, 0), (1, 0), (1, 1), (0, 1))):
        loop[uv].uv = (u, v)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    return link(name, me, mat)

def cylinder(name, r, depth, mat, at, offset=(0, 0, 0), segs=16):
    """Cylinder along +Z of the frame `at`, base at `offset`."""
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, segments=segs, radius1=r, radius2=r, depth=depth)
    bmesh.ops.translate(bm, vec=Vector(offset) + Vector((0, 0, depth / 2)), verts=bm.verts)
    bmesh.ops.transform(bm, matrix=at, verts=bm.verts)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    return link(name, me, mat, smooth=True)

def tube(name, points, radius, mat, smooth_curve=True):
    """Bevelled curve through `points`, converted to a mesh."""
    cu = bpy.data.curves.new(name + "_c", 'CURVE')
    cu.dimensions = '3D'
    cu.bevel_depth = radius
    cu.bevel_resolution = 2
    cu.resolution_u = 10
    cu.use_fill_caps = True
    if smooth_curve:
        sp = cu.splines.new('BEZIER')
        sp.bezier_points.add(len(points) - 1)
        for bp, p in zip(sp.bezier_points, points):
            bp.co = p
            bp.handle_left_type = bp.handle_right_type = 'AUTO'
    else:
        sp = cu.splines.new('POLY')
        sp.points.add(len(points) - 1)
        for pt, p in zip(sp.points, points):
            pt.co = (*p, 1)
    tmp = bpy.data.objects.new(name + "_tmp", cu)
    coll.objects.link(tmp)
    dg = bpy.context.evaluated_depsgraph_get()
    me = bpy.data.meshes.new_from_object(tmp.evaluated_get(dg))
    bpy.data.objects.remove(tmp)
    bpy.data.curves.remove(cu)
    me.name = name
    o = bpy.data.objects.new(name, me)
    coll.objects.link(o)
    me.materials.clear()
    me.materials.append(mat)
    for p in me.polygons:
        p.use_smooth = True
    return o

def frame(origin, x, y):
    """4x4 frame with axes x, y and z = x cross y (all normalised)."""
    x = Vector(x).normalized()
    y = Vector(y).normalized()
    z = x.cross(y).normalized()
    y = z.cross(x)
    m = Matrix.Identity(4)
    for i in range(3):
        m[i][0], m[i][1], m[i][2], m[i][3] = x[i], y[i], z[i], origin[i]
    return m

def rot_y(deg):
    return Matrix.Rotation(math.radians(deg), 4, 'Y')

def trans(x, y, z):
    return Matrix.Translation((x, y, z))

# ---------------------------------------------------------------- main panel
# The instrument face is a slab sloping toward the pilot: bottom edge at
# 38 deg below the eye line, top edge at 10 deg. Panel-local frame:
# u = +X (right), v = up the slope, n = toward the pilot.

B = Vector((0, 0.60, -0.40))
T = Vector((0, 0.78, -0.14))
DY = T.y - 0.57   # front-end parts below were laid out for a 0.57 m panel top
L = (T - B).length
V = (T - B).normalized()
PANEL = frame(B, (1, 0, 0), V)   # z = X x V points toward the pilot

CW = 0.17   # half width of the centre panel
WW = 0.25   # width of each wing
DEPTH = 0.16

box("PanelCenter", (2 * CW, L, DEPTH), M["Panel"], PANEL, (0, L / 2, -DEPTH / 2))

# Wings hinge on the centre panel edges and turn toward the pilot.
WING_L = PANEL @ trans(-CW, 0, 0) @ rot_y(28)
WING_R = PANEL @ trans(CW, 0, 0) @ rot_y(-28)
box("PanelWingL", (WW, L, DEPTH), M["Panel"], WING_L, (-WW / 2, L / 2, -DEPTH / 2))
box("PanelWingR", (WW, L, DEPTH), M["Panel"], WING_R, (WW / 2, L / 2, -DEPTH / 2))
# Hinge fillers so the joints read as one moulding.
for s, side in ((-1, "L"), (1, "R")):
    box("PanelSeam" + side, (0.02, L + 0.004, 0.012), M["Trim"], PANEL, (s * CW, L / 2, 0.0), bevel=0.003)

def screen(name, w, h, at, cx, cy):
    """Bezel + inset display quad, centred at (cx, cy) on a panel face."""
    box(name + "Bezel", (w + 0.022, h + 0.022, 0.012), M["Bezel"], at, (cx, cy, 0.004), bevel=0.003)
    # Rim lip and mounting screws give the bezel some depth.
    for sx in (-1, 1):
        for sy in (-1, 1):
            cylinder(name + "Screw", 0.0025, 0.003, M["Trim"], at, (cx + sx * (w / 2 + 0.006), cy + sy * (h / 2 + 0.006), 0.0095), segs=8)
    # Side button columns, the classic MFD bezel keys.
    if w > 0.12:
        for i in range(4):
            for sx in (-1, 1):
                box(name + "Key", (0.008, 0.012, 0.006), M["Trim"], at,
                    (cx + sx * (w / 2 + 0.0165), cy - h * 0.3 + i * h * 0.2, 0.012), bevel=0.0015, segments=1)
    quad(name, w, h, screen_mat(name), at, (cx, cy, 0.0105))

screen("Radar", 0.15, 0.15, PANEL, 0, 0.112)
screen("Left", 0.19, 0.15, WING_L, -0.125, 0.104)
screen("Right", 0.19, 0.15, WING_R, 0.125, 0.104)

def annunciator(name, color, at, cx, cy, w=0.048, h=0.022):
    box("Ann" + name + "Frame", (w + 0.006, h + 0.006, 0.008), M["Bezel"], at, (cx, cy, 0.002), bevel=0.0015, segments=1)
    quad("Ann" + name, w, h, lamp_mat(name, color), at, (cx, cy, 0.0065))

AMBER, RED, GREEN, BLUE = (1, 0.6, 0.1), (1, 0.12, 0.08), (0.2, 1, 0.4), (0.3, 0.6, 1)
for i, (name, col) in enumerate((("Shield", BLUE), ("Hull", RED), ("Hit", RED), ("Six", RED))):
    annunciator(name, col, WING_L, -0.205 + i * 0.054, 0.226)
for i, (name, col) in enumerate((("Lock", GREEN), ("Guns", GREEN), ("Boost", AMBER), ("Prox", AMBER))):
    annunciator(name, col, WING_R, 0.043 + i * 0.054, 0.226)
# Master caution: the big push-light in the middle of the top row.
box("MasterCautionFrame", (0.084, 0.032, 0.012), M["Hazard"], PANEL, (0, 0.226, 0.004), bevel=0.003)
quad("MasterCaution", 0.072, 0.022, lamp_mat("Caution", AMBER), PANEL, (0, 0.226, 0.0105))

# Small rocker switches under the MFDs, partly in view when looking down.
for at, cx0 in ((WING_L, -0.2), (WING_R, 0.05)):
    for i in range(5):
        box("Rocker", (0.012, 0.02, 0.008), M["Trim"], at, (cx0 + i * 0.03, 0.012, 0.004), bevel=0.002, segments=1)

# ---------------------------------------------------------------- glareshield + HUD

# The hood overhangs the panel top and shades the displays.
HOOD_Z = T.z + 0.018
hood = frame(Vector((0, T.y + 0.11, HOOD_Z)), (1, 0, 0), (0, 1, 0))
box("Glareshield", (2 * CW + 0.08, 0.27, 0.022), M["Panel"], hood, bevel=0.008, segments=3)
for s in (-1, 1):
    side = frame(Vector((s * (CW + 0.04), T.y + 0.11, HOOD_Z)), (1, 0, 0), (0, 1, 0)) @ Matrix.Rotation(math.radians(-s * 28), 4, 'Z')
    box("GlareshieldWing", (0.26, 0.26, 0.022), M["Panel"], side, (s * 0.12, 0, 0), bevel=0.008, segments=3)
# Rubber lip along the rear edge of the hood.
tube("GlareLip", [(-CW - 0.04, T.y - 0.022, HOOD_Z - 0.004), (0, T.y - 0.026, HOOD_Z - 0.004), (CW + 0.04, T.y - 0.022, HOOD_Z - 0.004)], 0.008, M["Rubber"])

# HUD combiner: two posts and a tilted glass plate above the hood.
hud_base = Vector((0, T.y + 0.06, HOOD_Z + 0.011))
for s in (-1, 1):
    tube("HudPost", [hud_base + Vector((s * 0.072, 0, 0)), hud_base + Vector((s * 0.072, -0.035, 0.11))], 0.004, M["Frame"], smooth_curve=False)
box("HudBase", (0.17, 0.05, 0.02), M["Frame"], trans(*hud_base), bevel=0.004)
hud_glass = frame(hud_base + Vector((0, -0.018, 0.058)), (1, 0, 0), (0, -0.3, 1))
quad("HudGlass", 0.135, 0.105, M["Glass"], hud_glass)

# Status display on the left hood corner, facing the pilot.
status_at = frame(Vector((-0.47, T.y - 0.09, HOOD_Z + 0.075)), (0.85, 0.53, 0), (0, -0.25, 1))
box("StatusHousing", (0.13, 0.085, 0.03), M["Panel"], status_at, (0, 0, -0.012), bevel=0.006)
screen("Status", 0.11, 0.065, status_at, 0, 0)
cylinder("StatusArm", 0.008, 0.11, M["Frame"], trans(-0.47, T.y - 0.07, HOOD_Z - 0.04))

# ---------------------------------------------------------------- canopy frame

SILL_Z = -0.17
SILL_X = 0.62
for s, side in ((-1, "L"), (1, "R")):
    # Sill rail along each side of the canopy.
    tube("Sill" + side, [(s * SILL_X, 0.95 + DY, SILL_Z), (s * (SILL_X + 0.02), 0.2, SILL_Z), (s * SILL_X, -0.75, SILL_Z)], 0.03, M["Frame"])
    # Windscreen pillar: from the hood corner, up and back to the main arch.
    tube("Pillar" + side, [(s * 0.5, 0.86 + DY, SILL_Z + 0.02), (s * 0.47, 0.6 + DY * 0.6, 0.18), (s * 0.36, 0.25, 0.42), (s * 0.12, 0.1, 0.53)], 0.022, M["Frame"])

# Main canopy arch just behind the pilot's head, and the front windscreen bow.
arch = [(math.sin(a) * SILL_X, -0.06, SILL_Z + math.cos(a) * 0.72) for a in [math.radians(d) for d in range(-90, 91, 15)]]
tube("CanopyArch", arch, 0.03, M["Frame"])
bow = [(math.sin(a) * 0.54, 0.9 + DY - 0.12 * math.cos(a) ** 2, SILL_Z + 0.02 + math.cos(a) * 0.04) for a in [math.radians(d) for d in range(-90, 91, 30)]]
tube("WindscreenBow", bow, 0.018, M["Frame"])
# Spine running back over the head.
tube("CanopySpine", [(0, 0.1, 0.55), (0, -0.06, 0.55), (0, -0.6, 0.42)], 0.02, M["Frame"])
# A couple of grab handles on the arch.
for s in (-1, 1):
    tube("GrabHandle", [(s * 0.5, -0.04, 0.2), (s * 0.47, 0.02, 0.24), (s * 0.43, 0.02, 0.31), (s * 0.4, -0.04, 0.35)], 0.007, M["Hazard"])

# ---------------------------------------------------------------- tub, consoles

for s, side in ((-1, "L"), (1, "R")):
    # Side walls from the sill down to the floor.
    box("Wall" + side, (0.05, 1.7 + DY, 0.85), M["Panel"], Matrix.Identity(4), (s * (SILL_X + 0.01), 0.1 + DY / 2, SILL_Z - 0.43), bevel=0.01)
    # Side console, sloping slightly down toward the front.
    con = frame(Vector((s * 0.45, 0.02 + DY / 2, -0.47)), (1, 0, 0), (0, 1, -0.08))
    box("Console" + side, (0.28, 0.82 + DY, 0.12), M["Panel"], con, (0, 0, -0.06), bevel=0.01, segments=3)
    box("ConsoleTrim" + side, (0.29, 0.83 + DY, 0.006), M["Trim"], con, (0, 0, 0.0005), bevel=0.002, segments=1)
    # Switch fields: rows of toggles with guards.
    for r in range(3):
        for k in range(4):
            px, py = s * (0.36 + k * 0.05), 0.24 - r * 0.07 - (0.32 if s < 0 else 0)
            if s < 0 and r == 0:
                continue
            box("SwitchPlate", (0.03, 0.04, 0.006), M["Bezel"], con, (px - s * 0.45, py, 0.004), bevel=0.0015, segments=1)
            tube("Toggle", [con @ Vector((px - s * 0.45, py, 0.007)), con @ Vector((px - s * 0.45, py + 0.008, 0.028))], 0.0025, M["Trim"], smooth_curve=False)
    # Air vent at the front of each console.
    vent = frame(Vector((s * 0.5, 0.36 + DY, -0.42)), (1, 0, 0), (0, 0, 1))
    cylinder("Vent" + side, 0.035, 0.03, M["Bezel"], vent @ Matrix.Rotation(math.radians(90), 4, 'X'), (0, 0, -0.03))
    for i in range(4):
        box("VentVane", (0.06, 0.004, 0.004), M["Trim"], vent, (0, 0, -0.024 + i * 0.016), bevel=0)

# Floor, footwell walls and the pedestal under the panel.
box("Floor", (1.25, 1.6 + DY, 0.04), M["Panel"], Matrix.Identity(4), (0, 0.1 + DY / 2, -1.04), bevel=0.01)
box("Pedestal", (0.3, 0.3, 0.5), M["Panel"], Matrix.Identity(4), (0, 0.55 + DY, -0.75), bevel=0.02)
box("PedestalPlate", (0.18, 0.006, 0.14), M["Hazard"], Matrix.Identity(4), (0, 0.398 + DY, -0.62), bevel=0.002)

# ---------------------------------------------------------------- seat

box("SeatBack", (0.48, 0.1, 0.72), M["Seat"], frame(Vector((0, -0.3, -0.52)), (1, 0, 0), (0, 0.15, 1)), bevel=0.03, segments=3)
box("Headrest", (0.3, 0.12, 0.16), M["Seat"], Matrix.Identity(4), (0, -0.27, -0.06), bevel=0.03, segments=3)
box("SeatPan", (0.48, 0.5, 0.1), M["Seat"], Matrix.Identity(4), (0, -0.05, -0.88), bevel=0.03, segments=3)
for s in (-1, 1):
    box("SeatRail", (0.05, 0.12, 0.85), M["Frame"], Matrix.Identity(4), (s * 0.27, -0.34, -0.5), bevel=0.01)
    tube("Harness", [(s * 0.12, -0.24, -0.1), (s * 0.14, -0.05, -0.32), (s * 0.06, 0.08, -0.62)], 0.012, M["Hazard"])
box("RearBulkhead", (1.25, 0.04, 1.1), M["Panel"], Matrix.Identity(4), (0, -0.72, -0.55), bevel=0.01)

# ---------------------------------------------------------------- controls

# Flight stick, between the knees. Pivot = bottom of its bounds (the boot).
stick_base = Vector((0, 0.22, -0.98))
cylinder("StickBoot", 0.06, 0.06, M["Rubber"], trans(*stick_base), segs=20)
stick_parts = [
    tube("StickShaft", [stick_base, stick_base + Vector((0, 0.01, 0.3))], 0.012, M["Frame"], smooth_curve=False),
    tube("StickGrip", [stick_base + Vector((0, 0.01, 0.3)), stick_base + Vector((0, 0.03, 0.4)), stick_base + Vector((0, 0.02, 0.45))], 0.024, M["Rubber"]),
    box("StickTrigger", (0.018, 0.02, 0.03), M["Hazard"], trans(*(stick_base + Vector((0, 0.05, 0.38)))), bevel=0.004),
    cylinder("StickHat", 0.008, 0.012, M["Trim"], trans(*(stick_base + Vector((0, 0.03, 0.465))))),
]

# Throttle on the left console, sliding along the console in a slot.
thr_base = Vector((-0.4, 0.0, -0.49))
box("ThrottleSlot", (0.03, 0.3, 0.01), M["Bezel"], trans(*thr_base), bevel=0.002)
throttle_parts = [
    tube("ThrottleArm", [thr_base, thr_base + Vector((0, 0, 0.11))], 0.01, M["Frame"], smooth_curve=False),
    box("ThrottleGrip", (0.1, 0.06, 0.05), M["Rubber"], trans(*(thr_base + Vector((0.025, 0, 0.13)))), bevel=0.015, segments=3),
    box("ThrottleButton", (0.016, 0.016, 0.01), M["Hazard"], trans(*(thr_base + Vector((0.055, 0.01, 0.157)))), bevel=0.003),
]
# Throttle LED ladder next to the slot.
for i in range(10):
    quad("ThrLed%d" % i, 0.016, 0.008, lamp_mat("Thr%d" % i, GREEN if i < 7 else AMBER),
         frame(thr_base + Vector((0.035, -0.135 + i * 0.03, 0.006)), (1, 0, 0), (0, 1, 0)))

def join(name, parts):
    dg = bpy.context.evaluated_depsgraph_get()
    bm = bmesh.new()
    mats = []
    for p in parts:
        me = bpy.data.meshes.new_from_object(p.evaluated_get(dg))
        me.transform(p.matrix_world)
        for poly in me.polygons:
            m = me.materials[poly.material_index]
            if m not in mats:
                mats.append(m)
            poly.material_index = mats.index(m)
        bm.from_mesh(me)
        bpy.data.meshes.remove(me)
        bpy.data.objects.remove(p)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    for m in mats:
        me.materials.append(m)
    o = bpy.data.objects.new(name, me)
    coll.objects.link(o)
    return o

join("Stick", stick_parts)
join("Throttle", throttle_parts)
# Everything else is one multi-material mesh: screens and lamps are found by
# material name, so they don't need objects of their own.
join("Cockpit", [o for o in coll.objects if o.type == 'MESH' and o.name not in ("Stick", "Throttle")])

# ---------------------------------------------------------------- export

bpy.ops.wm.obj_export(filepath=OUT, export_selected_objects=False, forward_axis='NEGATIVE_Z', up_axis='Y',
                      apply_modifiers=True, export_uv=True, export_normals=True, export_materials=True,
                      export_triangulated_mesh=True, path_mode='STRIP')

# Pilot's-eye camera for previews, matching the game's 68 deg vertical FOV.
cam = bpy.data.objects.new("EyeCam", bpy.data.cameras.new("EyeCam"))
coll.objects.link(cam)
cam.data.sensor_fit = 'VERTICAL'
cam.data.angle_y = math.radians(68)
cam.data.clip_start = 0.02
cam.rotation_euler = (math.radians(90), 0, 0)
scene.camera = cam
scene.render.resolution_x, scene.render.resolution_y = 1600, 900
sun = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", 'SUN'))
sun.data.energy = 4
sun.rotation_euler = (math.radians(40), math.radians(-25), math.radians(30))
coll.objects.link(sun)
world = scene.world or bpy.data.worlds.new("World")
scene.world = world
world.use_nodes = True
world.node_tree.nodes["Background"].inputs["Color"].default_value = (0.02, 0.025, 0.04, 1)

scene.render.engine = 'BLENDER_EEVEE'
scene.render.filepath = os.environ.get("COCKPIT_PREVIEW", "")
if scene.render.filepath:
    bpy.ops.render.render(write_still=True)
bpy.ops.wm.save_mainfile()
result = {"exported": OUT, "objects": len(bpy.data.objects)}
print(result)
