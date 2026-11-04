# Kitbash helpers shared by the Art/*.py builders that run inside Blender.
# See Art/README.md for the workflow. (build_capitals.py predates this file
# and keeps its own copy of the same ideas.)
#
#   import sys, os; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
#   from kitbash import Mesh, Kit, box, cyl
#
# Everything accumulates into Mesh objects, one bmesh each, so a scene with
# thousands of parts stays a handful of Blender objects. Every face gets a
# box-projected UV (world metres / tile) as it is added, so tiling textures
# line up across parts without unwrapping.

import bmesh
import bpy
import math
from mathutils import Matrix, Vector


class Mesh:
    """Faces with a material each and box-projected UVs, in one bmesh."""

    def __init__(self, name, tile=4.0, tiles=None):
        self.name = name
        self.tile = tile                 # metres per UV unit
        self.tiles = tiles or {}         # per-material override
        self.bm = bmesh.new()
        self.uv = self.bm.loops.layers.uv.new("UVMap")
        self.mats = []

    def mat(self, name):
        if name not in self.mats:
            self.mats.append(name)
        return self.mats.index(name)

    def faces(self, verts, faces, mat, mats=None, uvs=None):
        """Faces over verts. `mats` gives a material per face; `uvs` gives
        explicit per-vertex UVs (screens) instead of the box projection."""
        vs = [self.bm.verts.new(Vector(v)) for v in verts]
        for k, f in enumerate(faces):
            fm = mats[k] if mats else mat
            try:
                face = self.bm.faces.new([vs[i] for i in f])
            except ValueError:
                continue
            face.material_index = self.mat(fm)
            face.normal_update()
            if uvs:
                for loop, i in zip(face.loops, f):
                    loop[self.uv].uv = uvs[i]
                continue
            t = self.tiles.get(fm, self.tile)
            n = face.normal if face.normal.length > 0 else Vector((0, 0, 1))
            ax = max(range(3), key=lambda i: abs(n[i]))
            a, b = [(1, 2), (0, 2), (0, 1)][ax]
            for loop in face.loops:
                co = loop.vert.co
                loop[self.uv].uv = (co[a] / t, co[b] / t)

    def link(self, materials, coll=None, sharp=30, recalc=True):
        """Make the Blender object; `materials` maps name -> bpy material.
        recalc=False keeps faces as wound (loose quads have no outside)."""
        me = bpy.data.meshes.new(self.name)
        if recalc:
            bmesh.ops.recalc_face_normals(self.bm, faces=self.bm.faces)
        self.bm.to_mesh(me)
        self.bm.free()
        for m in self.mats:
            me.materials.append(materials[m])
        for p in me.polygons:
            p.use_smooth = True
        me.set_sharp_from_angle(angle=math.radians(sharp))
        o = bpy.data.objects.new(self.name, me)
        (coll or bpy.context.scene.collection).objects.link(o)
        return o


# ---------------------------------------------------------------- primitives

BOX_FACES = [(0, 1, 3, 2), (4, 6, 7, 5), (0, 4, 5, 1), (2, 3, 7, 6), (0, 2, 6, 4), (1, 5, 7, 3)]


def box(m, lo, hi, mat):
    """Axis-aligned box between corners lo and hi."""
    lo, hi = Vector(lo), Vector(hi)
    vs = [Vector((x, y, z)) for x in (lo.x, hi.x) for y in (lo.y, hi.y) for z in (lo.z, hi.z)]
    m.faces(vs, BOX_FACES, mat)


def chamfer_box(m, lo, hi, mat, c=0.05):
    """Box with its edges along the longest axis chamfered by c."""
    lo, hi = Vector(lo), Vector(hi)
    size = hi - lo
    ax = max(range(3), key=lambda i: size[i])
    a, b = [i for i in range(3) if i != ax]
    c = min(c, size[a] * 0.45, size[b] * 0.45)
    ring = [(lo[a] + c, lo[b]), (hi[a] - c, lo[b]), (hi[a], lo[b] + c), (hi[a], hi[b] - c),
            (hi[a] - c, hi[b]), (lo[a] + c, hi[b]), (lo[a], hi[b] - c), (lo[a], lo[b] + c)]
    verts = []
    for d in (lo[ax], hi[ax]):
        for pa, pb in ring:
            v = [0, 0, 0]
            v[ax], v[a], v[b] = d, pa, pb
            verts.append(v)
    faces = [(i, (i + 1) % 8, 8 + (i + 1) % 8, 8 + i) for i in range(8)]
    faces += [tuple(reversed(range(8))), tuple(range(8, 16))]
    m.faces(verts, faces, mat)


def quad(m, corners, mat, uv=((0, 0), (1, 0), (1, 1), (0, 1))):
    """One quad with explicit UVs (counter-clockwise seen from its front)."""
    m.faces(corners, [(0, 1, 2, 3)], mat, uvs=list(uv))


def frame_for(p0, p1):
    d = Vector(p1) - Vector(p0)
    z = d.normalized()
    up = Vector((0, 0, 1)) if abs(z.z) < 0.9 else Vector((1, 0, 0))
    x = up.cross(z).normalized()
    return x, z.cross(x), z, d.length


def cyl(m, p0, p1, r0, r1=None, mat="Metal", segs=12, caps=True):
    r1 = r0 if r1 is None else r1
    x, y, z, L = frame_for(p0, p1)
    p0 = Vector(p0)
    verts = [p0 + z * (L * k) + (x * math.cos(2 * math.pi * i / segs) + y * math.sin(2 * math.pi * i / segs)) * r
             for k, r in ((0, r0), (1, r1)) for i in range(segs)]
    faces = [(i, (i + 1) % segs, segs + (i + 1) % segs, segs + i) for i in range(segs)]
    if caps:
        faces += [tuple(reversed(range(segs))), tuple(range(segs, 2 * segs))]
    m.faces(verts, faces, mat)


def polyline(m, pts, r, mat, segs=8):
    """A tube through points, one cylinder per segment."""
    for a, b in zip(pts, pts[1:]):
        cyl(m, a, b, r, mat=mat, segs=segs)


# ---------------------------------------------------------------- kit

class Kit:
    """Parts from a kitbash .blend, baked (modifiers applied) and centred on
    their bounds. `place` drops one into a Mesh, rotated and scaled, with the
    kit's own materials mapped through `mats` (unmapped ones take `mat`)."""

    def __init__(self, path, mats=None):
        self.mats = mats or {}
        self.parts = {}
        with bpy.data.libraries.load(path, link=False) as (src, dst):
            dst.objects = list(src.objects)
        coll = bpy.context.scene.collection
        objs = [o for o in dst.objects if o is not None]
        for o in objs:
            coll.objects.link(o)
        dg = bpy.context.evaluated_depsgraph_get()
        dg.update()
        for o in objs:
            if o.type != 'MESH':
                continue
            me = bpy.data.meshes.new_from_object(o.evaluated_get(dg))
            me.transform(o.matrix_world)
            if not me.vertices:
                continue
            lo = Vector([min(v.co[i] for v in me.vertices) for i in range(3)])
            hi = Vector([max(v.co[i] for v in me.vertices) for i in range(3)])
            c = (lo + hi) / 2
            names = [me.materials[p.material_index].name if me.materials and me.materials[p.material_index] else "Flat"
                     for p in me.polygons]
            self.parts[o.name] = ([v.co - c for v in me.vertices], [tuple(p.vertices) for p in me.polygons], names, hi - lo)
            bpy.data.meshes.remove(me)
        for o in objs:
            bpy.data.objects.remove(o, do_unlink=True)

    def size(self, part):
        return self.parts[part][3]

    def place(self, m, part, at, size=None, scale=None, rot=(0, 0, 0), mirror=False, mat="Metal", mats=None):
        """Centre `part` at `at`. `size` fits its bounds (before rotation) into
        (x, y, z) metres, None entries keeping proportion; `scale` is a plain
        factor or (x, y, z). rot is XYZ degrees. Returns placed (lo, hi)."""
        verts, faces, names, dims = self.parts[part]
        if size is not None:
            ks = [s / max(d, 1e-4) for s, d in zip(size, dims) if s is not None]
            k = min(ks) if ks else 1.0
            scale = tuple(s / max(d, 1e-4) if s is not None else k for s, d in zip(size, dims))
        elif scale is None:
            scale = (1, 1, 1)
        elif not isinstance(scale, (tuple, list)):
            scale = (scale, scale, scale)
        R = (Matrix.Rotation(math.radians(rot[2]), 3, 'Z') @ Matrix.Rotation(math.radians(rot[1]), 3, 'Y')
             @ Matrix.Rotation(math.radians(rot[0]), 3, 'X'))
        sx = -1 if mirror else 1
        pts = [Vector(at) + R @ Vector((v.x * scale[0] * sx, v.y * scale[1], v.z * scale[2])) for v in verts]
        fs = [tuple(reversed(f)) for f in faces] if mirror else faces
        table = dict(self.mats, **(mats or {}))
        m.faces(pts, fs, mat, [table.get(n, mat) for n in names])
        lo = Vector([min(p[i] for p in pts) for i in range(3)])
        hi = Vector([max(p[i] for p in pts) for i in range(3)])
        return lo, hi
