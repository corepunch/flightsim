# Builds the pickups and exports each as Models/Capital/<Asset>.obj with one
# material, "Painted", and its texture Textures/<asset>_baked.png.
#
#   Blender -b --factory-startup --python Games/KestrelFrontier/Art/build_pickups.py [-- Name ...]
#   PICKUP_PREVIEW=<dir> also renders each one there.
#
# A pickup is seen from far off and for a moment as it is flown through, so it
# is one big exaggerated shape in a few bold colour blocks, with no fine
# detail. Each block is its own faces, painted as a face-corner colour so its
# edges stay crisp; the colours, darkened by baked ambient occlusion and a
# top-lit gradient, are baked into a small texture that the game draws partly
# self-lit (Data/Styles/pickup-*.json, "baked").
#
# Space: metres, +Z up. A pickup spins about +Z in the game; the OBJ export
# maps +Z to the game's up.

import bmesh
import bpy
import math
import os
import sys
from mathutils import Matrix, Vector

GAME = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODELS = os.path.join(GAME, "Models", "Capital")
TEXTURES = os.path.join(GAME, "Textures")
PREVIEW = os.environ.get("PICKUP_PREVIEW")
SIZE = 256          # baked texture, pixels

# ---------------------------------------------------------------- painting

class Painted:
    """Faces with a colour each, in one bmesh."""

    def __init__(self):
        self.bm = bmesh.new()
        self.col = self.bm.loops.layers.color.new("Col")

    def face(self, pts, colour):
        f = self.bm.faces.new([self.bm.verts.new(p) for p in pts])
        for loop in f.loops:
            loop[self.col] = (*colour, 1)
        return f

    def ring(self, y0, y1, r0, r1, colours, segs=16, cap0=None, cap1=None):
        """A frustum along Y from y0 (radius r0) to y1; colours cycle per segment."""
        a = [2 * math.pi * (i + 0.5) / segs for i in range(segs)]
        p0 = [Vector((math.cos(t) * r0, y0, math.sin(t) * r0)) for t in a]
        p1 = [Vector((math.cos(t) * r1, y1, math.sin(t) * r1)) for t in a]
        for i in range(segs):
            j = (i + 1) % segs
            self.face([p0[i], p0[j], p1[j], p1[i]], colours[i % len(colours)])
        if cap0 and r0 > 0:
            self.face(list(reversed(p0)), cap0)
        if cap1 and r1 > 0:
            self.face(p1, cap1)

    def slab(self, outline, depth, front, side, axis):
        """A flat polygon (2D outline in the plane across `axis`) given depth."""
        def at(u, v, w):
            return Vector((u, w, v)) if axis == 'Y' else Vector((w, u, v)) if axis == 'X' else Vector((u, v, w))
        back = [at(u, v, -depth / 2) for u, v in outline]
        fore = [at(u, v, depth / 2) for u, v in outline]
        self.face(fore, front)
        self.face(list(reversed(back)), front)
        n = len(outline)
        for i in range(n):
            j = (i + 1) % n
            self.face([back[i], back[j], fore[j], fore[i]], side)

    def finish(self, name):
        bmesh.ops.remove_doubles(self.bm, verts=self.bm.verts, dist=1e-4)
        bmesh.ops.recalc_face_normals(self.bm, faces=self.bm.faces)
        me = bpy.data.meshes.new(name)
        self.bm.to_mesh(me)
        self.bm.free()
        o = bpy.data.objects.new(name, me)
        bpy.context.scene.collection.objects.link(o)
        return o

def rgb(h):
    return tuple(int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))

# ---------------------------------------------------------------- pickups

def TorpedoPack():
    """A fat cartoon torpedo: red nose, hazard band, glowing tail, big fins."""
    p = Painted()
    body, dark, nose, hot = rgb("c9ccd1"), rgb("2b2d33"), rgb("e8401c"), rgb("ffd66b")
    yellow = rgb("ffc21a")
    r = 2.0
    p.ring(-5.5, -5.0, r * 0.7, r, [dark], cap0=hot)                # nozzle, glowing
    p.ring(-5.0, -2.2, r, r, [body])
    p.ring(-2.2, -0.6, r, r, [yellow, dark])                        # hazard band
    p.ring(-0.6, 2.8, r, r, [body])
    p.ring(2.8, 3.3, r, r * 1.02, [dark])
    p.ring(3.3, 5.3, r * 1.02, r * 0.78, [nose])
    p.ring(5.3, 6.5, r * 0.78, r * 0.32, [nose])
    p.ring(6.5, 6.9, r * 0.32, 0.0, [nose])
    fin = [(0, 0), (2.6, -1.0), (2.6, -2.6), (0, -3.6)]             # root along the body, swept back
    for k in range(4):
        R = Matrix.Rotation(math.radians(45 + 90 * k), 3, 'Y')
        outline = [(r * 0.9 + u, -1.9 + v) for u, v in fin]
        q = Painted.__new__(Painted)
        q.bm, q.col = p.bm, p.col
        start = len(p.bm.verts)
        q.slab(outline, 0.6, nose, dark, 'Z')                       # in XY, thickness Z
        for v in list(p.bm.verts)[start:]:
            v.co = R @ v.co
    return p.finish("Body")

def RepairCell():
    """A chunky plus sign: white face, green rim and sides."""
    p = Painted()
    white, green, deep = rgb("f2fff4"), rgb("2bdc5c"), rgb("1a9c45")
    a, w, d, rim = 5.5, 1.9, 2.6, 0.6
    outline = [(-w, a), (w, a), (w, w), (a, w), (a, -w), (w, -w), (w, -a), (-w, -a), (-w, -w), (-a, -w), (-a, w), (-w, w)]
    p.slab(outline, d, green, deep, 'Y')                            # the cross, face across Y
    inner = [(u - math.copysign(rim, u), v - math.copysign(rim, v)) for u, v in outline]
    for s in (1, -1):                                               # raised white centre on both faces
        y = s * (d / 2 + 0.25)
        pts = [Vector((u, y, v)) for u, v in inner]
        p.face(pts if s > 0 else list(reversed(pts)), white)
        base = [Vector((u, s * d / 2, v)) for u, v in inner]
        for i in range(len(inner)):
            j = (i + 1) % len(inner)
            quad = [base[i], base[j], pts[j], pts[i]]
            p.face(quad if s > 0 else list(reversed(quad)), green)
    return p.finish("Body")

ASSETS = {"TorpedoPack": TorpedoPack, "RepairCell": RepairCell}

# ---------------------------------------------------------------- bake + export

def clear():
    for o in list(bpy.data.objects):
        bpy.data.objects.remove(o, do_unlink=True)
    for c in (bpy.data.meshes, bpy.data.materials, bpy.data.images, bpy.data.cameras, bpy.data.lights, bpy.data.worlds):
        for d in list(c):
            c.remove(d)

def select(o):
    bpy.ops.object.select_all(action='DESELECT')
    o.select_set(True)
    bpy.context.view_layer.objects.active = o

def bake(o, kind, image, material):
    nodes = material.node_tree.nodes
    tex = nodes.new("ShaderNodeTexImage")
    tex.image = image
    nodes.active = tex
    select(o)
    bpy.ops.object.bake(type=kind, margin=4, use_clear=True)
    nodes.remove(tex)

def build(name):
    clear()
    scene = bpy.context.scene
    scene.render.engine = 'CYCLES'
    scene.cycles.device = 'CPU'
    scene.cycles.samples = 64
    o = ASSETS[name]()
    select(o)
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.uv.smart_project(angle_limit=math.radians(50), island_margin=0.02)
    bpy.ops.object.mode_set(mode='OBJECT')
    # Round bodies shade smooth; caps, fins and the cross keep hard edges.
    for poly in o.data.polygons:
        poly.use_smooth = True
    o.data.set_sharp_from_angle(angle=math.radians(30))

    # Bake the painted colours, then occlusion, then combine them with a
    # top-lit gradient so the shape reads whatever the scene's light does.
    m = bpy.data.materials.new("Painted")
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    attr = nt.nodes.new("ShaderNodeVertexColor")
    attr.layer_name = "Col"
    emit = nt.nodes.new("ShaderNodeEmission")
    nt.links.new(attr.outputs[0], emit.inputs[0])
    nt.links.new(emit.outputs[0], out.inputs[0])
    o.data.materials.append(m)
    colour = bpy.data.images.new("colour", SIZE, SIZE, float_buffer=True)
    occlusion = bpy.data.images.new("occlusion", SIZE, SIZE, float_buffer=True)
    shade = bpy.data.images.new("shade", SIZE, SIZE, float_buffer=True)
    bake(o, 'EMIT', colour, m)
    bake(o, 'AO', occlusion, m)
    geo = nt.nodes.new("ShaderNodeNewGeometry")
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    ramp = nt.nodes.new("ShaderNodeMapRange")
    ramp.inputs[1].default_value, ramp.inputs[2].default_value = -1, 1
    ramp.inputs[3].default_value, ramp.inputs[4].default_value = 0.72, 1.12
    nt.links.new(geo.outputs["Normal"], sep.inputs[0])
    nt.links.new(sep.outputs[2], ramp.inputs[0])
    nt.links.new(ramp.outputs[0], emit.inputs[0])
    bake(o, 'EMIT', shade, m)

    c, a, s = (list(i.pixels) for i in (colour, occlusion, shade))
    px = [0.0] * len(c)
    for i in range(0, len(c), 4):
        k = (0.7 + 0.3 * a[i]) * s[i]
        for j in range(3):
            px[i + j] = min(1.0, c[i + j] * k)
        px[i + 3] = 1.0
    result = bpy.data.images.new(name + "_baked", SIZE, SIZE)
    result.pixels = px
    result.filepath_raw = os.path.join(TEXTURES, name.lower() + "_baked.png")
    result.file_format = 'PNG'
    result.save()

    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = result
    nt.links.new(tex.outputs[0], bsdf.inputs["Base Color"])
    nt.links.new(bsdf.outputs[0], out.inputs[0])
    o.data.color_attributes.remove(o.data.color_attributes["Col"])
    bpy.ops.wm.obj_export(filepath=os.path.join(MODELS, name + ".obj"), export_selected_objects=False,
                          forward_axis='NEGATIVE_Z', up_axis='Y', export_uv=True, export_normals=True,
                          export_materials=True, export_triangulated_mesh=True, path_mode='STRIP')
    if PREVIEW:
        preview(name, o)
    return {"asset": name, "faces": len(o.data.polygons)}

def preview(name, o):
    scene = bpy.context.scene
    scene.render.resolution_x, scene.render.resolution_y = 480, 360
    scene.render.image_settings.media_type = 'IMAGE'
    scene.render.image_settings.file_format = 'PNG'
    world = bpy.data.worlds.new("Space")
    world.color = (0.01, 0.01, 0.015)
    scene.world = world
    sun = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", 'SUN'))
    sun.data.energy = 3
    sun.rotation_euler = (0.7, 0.3, 0.8)
    scene.collection.objects.link(sun)
    cam = bpy.data.objects.new("Cam", bpy.data.cameras.new("Cam"))
    scene.collection.objects.link(cam)
    cam.location = (16, -14, 8)
    cam.rotation_euler = (Vector((0, 0, 0)) - cam.location).to_track_quat('-Z', 'Y').to_euler()
    scene.camera = cam
    scene.render.filepath = os.path.join(PREVIEW, name + ".png")
    bpy.ops.render.render(write_still=True)

names = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else list(ASSETS)
for n in names:
    print(build(n))
