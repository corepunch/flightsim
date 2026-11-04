# Builds the capital ships, stations and props and exports one OBJ per asset
# into Resources/Models/Capital/. Ships are kitbashed from the CC0
# "Shipyard" parts set by greyoxide (Art/kit/fetch.sh downloads it), scaled
# up to capital size and combined with procedural glows, trusses and rings.
#
#   Blender -b --factory-startup --python Art/build_capitals.py [-- Name ...]
#   CAPITAL_PREVIEW=<dir> also renders a 3/4 preview of each asset there.
#
# Space: metres, +Y is the bow, +Z up. The OBJ export maps +Y to -Z, the
# game's forward. The kit uses the same convention (nozzles at -Y).
#
# Naming contract with Sources/Capital.m:
#   materials  Hull, HullDark, Trim, Windows, Glow, Lights, Solar, Hangar,
#              Cargo1..3, Rock, ShieldGen, GateGlow, Civil
#   objects    Body                 the hull (one per asset)
#              Turret_<n>           gun turret, fires along its local +Y
#              Engine_<n>           destroyable engine subsystem
#              Shield_<n>           destroyable shield generator
#              Core_<n>             reactor; the ship dies with it

import bpy
import bmesh
import math
import os
import random
import sys
from mathutils import Matrix, Vector, noise

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Resources", "Models", "Capital")
PREVIEW = os.environ.get("CAPITAL_PREVIEW")
TILE = 24.0          # metres per hull texture repeat
WIN_TILE = (16.0, 4.0)

# ---------------------------------------------------------------- mesh builder

class Mesh:
    """Accumulates faces into one bmesh with box-projected UVs."""

    def __init__(self, name):
        self.name = name
        self.bm = bmesh.new()
        self.uv = self.bm.loops.layers.uv.new("UVMap")
        self.mats = []

    def mat(self, name):
        if name not in self.mats:
            self.mats.append(name)
        return self.mats.index(name)

    def faces(self, verts, faces, mat, mats=None):
        """Faces over verts; `mats` gives a material per face instead of `mat`."""
        vs = [self.bm.verts.new(v) for v in verts]
        for k, f in enumerate(faces):
            fm = mats[k] if mats else mat
            mi = self.mat(fm)
            tile = WIN_TILE if fm == "Windows" else (TILE, TILE)
            try:
                face = self.bm.faces.new([vs[i] for i in f])
            except ValueError:
                continue
            face.material_index = mi
            face.smooth = True
            # A new bmesh face has no normal until asked; without this every
            # face fell back to a top-down projection and walls smeared.
            face.normal_update()
            n = face.normal if face.normal.length > 0 else Vector((0, 0, 1))
            ax = max(range(3), key=lambda i: abs(n[i]))
            a, b = [(1, 2), (0, 2), (0, 1)][ax]
            for loop in face.loops:
                co = loop.vert.co
                loop[self.uv].uv = (co[a] / tile[0], co[b] / tile[1])

    def link(self, coll):
        me = bpy.data.meshes.new(self.name)
        bmesh.ops.recalc_face_normals(self.bm, faces=self.bm.faces)
        self.bm.to_mesh(me)
        self.bm.free()
        for m in self.mats:
            me.materials.append(material(m))
        # Smooth curved kit parts, keep hard-surface edges crisp.
        me.set_sharp_from_angle(angle=math.radians(32))
        o = bpy.data.objects.new(self.name, me)
        coll.objects.link(o)
        return o

MATS = {
    "Hull": (0.45, 0.47, 0.5), "HullDark": (0.16, 0.17, 0.19), "Trim": (0.6, 0.6, 0.62),
    "Windows": (0.9, 0.85, 0.6), "Glow": (0.3, 0.6, 1.0), "Lights": (1, 1, 1), "Solar": (0.08, 0.12, 0.3),
    "Hangar": (0.02, 0.02, 0.025), "Cargo1": (0.7, 0.35, 0.1), "Cargo2": (0.15, 0.35, 0.5),
    "Cargo3": (0.55, 0.55, 0.2), "Rock": (0.25, 0.23, 0.21), "ShieldGen": (0.3, 0.8, 1.0),
    "GateGlow": (0.4, 0.8, 1.0), "Civil": (0.85, 0.86, 0.88),
}

def material(name):
    m = bpy.data.materials.get(name)
    if m:
        return m
    m = bpy.data.materials.new(name)
    c = MATS.get(name, (0.5, 0.5, 0.5))
    m.diffuse_color = (*c, 1)
    return m

# ---------------------------------------------------------------- primitives

def box(m, c, s, mat="Hull", rot=None):
    """Box centred on c with size s, optionally rotated (Matrix 3x3)."""
    hx, hy, hz = s[0] / 2, s[1] / 2, s[2] / 2
    vs = [Vector((x * hx, y * hy, z * hz)) for x in (-1, 1) for y in (-1, 1) for z in (-1, 1)]
    if rot:
        vs = [rot @ v for v in vs]
    vs = [Vector(c) + v for v in vs]
    m.faces(vs, [(0, 1, 3, 2), (4, 6, 7, 5), (0, 4, 5, 1), (2, 3, 7, 6), (0, 2, 6, 4), (1, 5, 7, 3)], mat)

def section(w, h, z, ch, sides=8):
    """Chamfered rectangle (octagon) cross-section in XZ."""
    cx, cz = w / 2, h / 2
    k = min(ch, 0.49) * min(w, h)
    pts = [(-cx + k, -cz), (cx - k, -cz), (cx, -cz + k), (cx, cz - k),
           (cx - k, cz), (-cx + k, cz), (-cx, cz - k), (-cx, -cz + k)]
    return [(x, z + y) for x, y in pts]

def loft(m, secs, mat="Hull", ch=0.25, cap=True, x=0.0):
    """Hull through cross-sections (y, width, height, zoffset[, chamfer])."""
    rings = []
    verts = []
    for s in secs:
        y, w, h, z = s[:4]
        c = s[4] if len(s) > 4 else ch
        ring = []
        for px, zz in section(max(w, 0.01), max(h, 0.01), z, c):
            ring.append(len(verts))
            verts.append(Vector((px + x, y, zz)))
        rings.append(ring)
    faces = []
    n = 8
    for a, b in zip(rings, rings[1:]):
        for i in range(n):
            j = (i + 1) % n
            faces.append((a[i], a[j], b[j], b[i]))
    if cap:
        faces.append(tuple(reversed(rings[0])))
        faces.append(tuple(rings[-1]))
    m.faces(verts, faces, mat)

def frame_for(p0, p1):
    d = (Vector(p1) - Vector(p0))
    z = d.normalized()
    up = Vector((0, 0, 1)) if abs(z.z) < 0.9 else Vector((1, 0, 0))
    x = up.cross(z).normalized()
    y = z.cross(x)
    return x, y, z, d.length

def cyl(m, p0, p1, r0, r1=None, mat="Trim", segs=16, caps=True):
    r1 = r0 if r1 is None else r1
    x, y, z, L = frame_for(p0, p1)
    p0 = Vector(p0)
    verts = []
    for k, r in ((0, r0), (1, r1)):
        for i in range(segs):
            a = 2 * math.pi * i / segs
            verts.append(p0 + z * (L * k) + (x * math.cos(a) + y * math.sin(a)) * r)
    faces = [(i, (i + 1) % segs, segs + (i + 1) % segs, segs + i) for i in range(segs)]
    if caps:
        faces.append(tuple(reversed(range(segs))))
        faces.append(tuple(range(segs, 2 * segs)))
    m.faces(verts, faces, mat)

def beam(m, p0, p1, w, mat="Trim"):
    cyl(m, p0, p1, w * 0.7, mat=mat, segs=4)

def sphere(m, c, r, mat="Hull", segs=20, rings=10, scale=(1, 1, 1), zmin=-1.0):
    """UV sphere; zmin > -1 cuts it into a dome."""
    c = Vector(c)
    verts, faces = [], []
    lat = [math.asin(zmin) + (math.pi / 2 - math.asin(zmin)) * i / rings for i in range(rings + 1)]
    for t in lat:
        for i in range(segs):
            a = 2 * math.pi * i / segs
            verts.append(c + Vector((math.cos(t) * math.cos(a) * r * scale[0], math.cos(t) * math.sin(a) * r * scale[1], math.sin(t) * r * scale[2])))
    for k in range(rings):
        for i in range(segs):
            j = (i + 1) % segs
            faces.append((k * segs + i, k * segs + j, (k + 1) * segs + j, (k + 1) * segs + i))
    faces.append(tuple(reversed(range(segs))))
    m.faces(verts, faces, mat)

def torus(m, c, R, r, mat="Hull", segs=64, sides=10, axis='Z', flat=1.0):
    c = Vector(c)
    verts, faces = [], []
    for i in range(segs):
        a = 2 * math.pi * i / segs
        for k in range(sides):
            b = 2 * math.pi * k / sides
            rr = R + r * math.cos(b)
            p = Vector((rr * math.cos(a), rr * math.sin(a), r * math.sin(b) * flat))
            if axis == 'Y':
                p = Vector((p.x, p.z, p.y))
            elif axis == 'X':
                p = Vector((p.z, p.x, p.y))
            verts.append(c + p)
    for i in range(segs):
        for k in range(sides):
            i2, k2 = (i + 1) % segs, (k + 1) % sides
            faces.append((i * sides + k, i2 * sides + k, i2 * sides + k2, i * sides + k2))
    m.faces(verts, faces, mat)

def rock(m, c, r, seed, mat="Rock", detail=3, rough=0.35):
    """Displaced icosphere."""
    bm = bmesh.new()
    bmesh.ops.create_icosphere(bm, subdivisions=detail, radius=1.0)
    off = Vector((seed * 13.1, seed * 7.7, seed * 3.3))
    verts = []
    for v in bm.verts:
        d = v.co.normalized()
        n = noise.fractal(d * 1.3 + off, 0.6, 2.0, 4)
        squash = Vector((1.0, 0.85 + 0.3 * math.sin(seed), 0.75 + 0.2 * math.cos(seed * 2)))
        p = d * r * (1 + rough * n)
        verts.append(Vector(c) + Vector((p.x * squash.x, p.y * squash.y, p.z * squash.z)))
    faces = [tuple(v.index for v in f.verts) for f in bm.faces]
    bm.free()
    m.faces(verts, faces, mat)

# ---------------------------------------------------------------- composite parts

def windows(m, y0, y1, x, z, h=1.2, rows=1, gap=3.0, side=1):
    """Lit window strips on a hull side facing +-X."""
    for r in range(rows):
        box(m, (x + side * 0.15, (y0 + y1) / 2, z + r * gap), (0.4, abs(y1 - y0), h), "Windows")

def windows_top(m, x0, x1, y, z, w=1.2):
    box(m, ((x0 + x1) / 2, y, z + 0.15), (abs(x1 - x0), w, 0.4), "Windows")

def engine(m, p, r, length, mat="HullDark", glow=True):
    """Engine bell pointing aft (-Y), glow disc at the back."""
    p = Vector(p)
    cyl(m, p + Vector((0, length * 0.4, 0)), p, r * 1.1, r, mat, segs=20)
    cyl(m, p, p - Vector((0, length * 0.6, 0)), r, r * 1.25, "Trim", segs=20, caps=False)
    if glow:
        cyl(m, p - Vector((0, length * 0.45, 0)), p - Vector((0, length * 0.5, 0)), r * 1.05, mat="Glow", segs=20)

def greebles(m, rng, center, size, count, normal=(0, 0, 1), mats=("HullDark", "Trim")):
    """Small boxes scattered over a rectangle (size in the two tangent axes)."""
    n = Vector(normal)
    ax = max(range(3), key=lambda i: abs(n[i]))
    t = [i for i in range(3) if i != ax]
    for _ in range(count):
        s = [rng.uniform(0.04, 0.16) * max(size) for _ in range(3)]
        s[ax] = rng.uniform(0.5, 2.5)
        p = list(center)
        p[t[0]] += rng.uniform(-0.5, 0.5) * size[0]
        p[t[1]] += rng.uniform(-0.5, 0.5) * size[1]
        p[ax] += n[ax] * s[ax] / 2
        box(m, p, s, rng.choice(mats))

def lights(m, pts, size=1.2):
    for p in pts:
        box(m, p, (size, size, size), "Lights")

def antenna(m, p, h, r=0.4, dish=0):
    p = Vector(p)
    cyl(m, p, p + Vector((0, 0, h)), r, r * 0.4, "Trim", segs=6)
    lights(m, [p + Vector((0, 0, h))], r * 2.5)
    if dish:
        cyl(m, p + Vector((0, 0, h * 0.6)), p + Vector((0, dish * 0.4, h * 0.6 + dish * 0.2)), dish * 0.15, dish, "Trim", segs=16)

def tower(m, base, levels, win=True):
    """Stacked boxes (x, y, w, l, h) from base z, windows on each level."""
    z = base[2]
    for (w, l, h) in levels:
        box(m, (base[0], base[1], z + h / 2), (w, l, h), "Hull")
        if win:
            windows(m, base[1] - l * 0.4, base[1] + l * 0.4, base[0] + w / 2, z + h * 0.5, h=h * 0.18, side=1)
            windows(m, base[1] - l * 0.4, base[1] + l * 0.4, base[0] - w / 2, z + h * 0.5, h=h * 0.18, side=-1)
            box(m, (base[0], base[1] + l / 2 + 0.15, z + h * 0.6), (w * 0.8, 0.4, h * 0.2), "Windows")
        z += h
    return z

def truss(m, p0, p1, w, mat="Trim"):
    """Square lattice girder from p0 to p1."""
    x, y, zz, L = frame_for(p0, p1)
    p0 = Vector(p0)
    corners = [(x * sx + y * sy) * w / 2 for sx in (-1, 1) for sy in (-1, 1)]
    for c in corners:
        beam(m, p0 + c, p0 + c + zz * L, w * 0.08, mat)
    steps = max(1, int(L / w))
    for i in range(steps + 1):
        q = p0 + zz * (L * i / steps)
        for a, b in ((0, 1), (1, 3), (3, 2), (2, 0)):
            beam(m, q + corners[a], q + corners[b], w * 0.05, mat)
        if i < steps:
            q2 = p0 + zz * (L * (i + 1) / steps)
            beam(m, q + corners[0], q2 + corners[3], w * 0.04, mat)

# ---------------------------------------------------------------- kit

KIT = os.path.join(ROOT, "Art", "kit", "Shipyard.blend")
PARTS = {}   # name -> (verts, faces, face materials, size), centred on the bounds
KIT_MATS = {"Glass": "Windows", "Flat.001": "HullDark", "Wire": "Hull", "Wire fade": "Hull"}


def load_kit():
    """Bake every kit part (modifiers applied, mirror halves included)."""
    if PARTS:
        return
    with bpy.data.libraries.load(KIT, link=False) as (src, dst):
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
        lo = Vector((min(v.co.x for v in me.vertices), min(v.co.y for v in me.vertices), min(v.co.z for v in me.vertices)))
        hi = Vector((max(v.co.x for v in me.vertices), max(v.co.y for v in me.vertices), max(v.co.z for v in me.vertices)))
        c = (lo + hi) / 2
        verts = [v.co - c for v in me.vertices]
        faces = [tuple(p.vertices) for p in me.polygons]
        names = [me.materials[p.material_index].name if me.materials and me.materials[p.material_index] else "Flat" for p in me.polygons]
        PARTS[o.name] = (verts, faces, names, hi - lo)
        bpy.data.meshes.remove(me)
    for o in objs:
        bpy.data.objects.remove(o, do_unlink=True)


def kit(m, part, at, length=None, scale=None, rot=(0, 0, 0), mirror=False, mat="Hull"):
    """Place a kit part centred at `at`. `length` scales it uniformly to that
    many metres along Y; `scale` is an explicit (x, y, z). Returns the
    placed bounds (lo, hi)."""
    verts, faces, names, size = PARTS[part]
    if scale is None:
        k = (length or size.y) / max(size.y, 1e-3)
        scale = (k, k, k)
    elif not isinstance(scale, (tuple, list)):
        scale = (scale, scale, scale)
    R = (Matrix.Rotation(math.radians(rot[2]), 3, 'Z') @ Matrix.Rotation(math.radians(rot[1]), 3, 'Y')
         @ Matrix.Rotation(math.radians(rot[0]), 3, 'X'))
    sx = -1 if mirror else 1
    pts = [Vector(at) + R @ Vector((v.x * scale[0] * sx, v.y * scale[1], v.z * scale[2])) for v in verts]
    fs = [tuple(reversed(f)) for f in faces] if mirror else faces
    mats = [KIT_MATS.get(n, mat) if n in KIT_MATS else mat for n in names]
    m.faces(pts, fs, mat, mats)
    lo = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
    hi = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
    return lo, hi


def kit_pair(m, part, at, **kw):
    """The same part on both sides of the centreline."""
    a = kit(m, part, at, **kw)
    kit(m, part, (-at[0], at[1], at[2]), mirror=not kw.pop("mirror", False), **kw)
    return a


def glow_disc(m, p, r):
    """Engine glow facing aft."""
    p = Vector(p)
    cyl(m, p, p - Vector((0, 0.5, 0)), r, mat="Glow", segs=20)


def kit_engine(m, part, at, length, glow=0.32):
    """Kit engine pointing aft with a glow disc in its nozzle."""
    lo, hi = kit(m, part, at, length=length, mat="HullDark")
    w = min(hi.x - lo.x, hi.z - lo.z)
    glow_disc(m, ((lo.x + hi.x) / 2, lo.y + 0.3, (lo.z + hi.z) / 2), w * glow)
    return lo, hi


def turret(objs, p, up=(0, 0, 1), size=1.0, part="Turret Set"):
    """Gun turret as its own object, barrels along +Y, base on the hull."""
    t = Mesh("Turret_%d" % (sum(1 for o in objs if o.name.startswith("Turret")) + 1))
    up = Vector(up).normalized()
    rot = (0, 0, 0) if up.z > 0.5 else ((0, 180, 0) if up.z < -0.5 else (0, -math.copysign(90, up.x), 0))
    verts, faces, names, dims = PARTS[part]
    L = 7.5 * size
    k = L / dims.y
    h = dims.z * k
    kit(t, part, Vector(p) + up * h * 0.5, length=L, rot=rot, mat="HullDark")
    objs.append(t)


def subsystem(objs, kind, p, size, up=(0, 0, 1)):
    n = sum(1 for o in objs if o.name.startswith(kind)) + 1
    s = Mesh("%s_%d" % (kind, n))
    p = Vector(p)
    if kind == "Shield":
        cyl(s, p, p + Vector(up) * size * 0.4, size * 0.9, size * 0.8, "HullDark", segs=16)
        sphere(s, p + Vector(up) * size * 0.4, size * 0.7, "ShieldGen", segs=16, rings=6, zmin=0.0 if up[2] > 0 else -1.0,
               scale=(1, 1, 1 if up[2] > 0 else -1))
    elif kind == "Engine":
        kit_engine(s, "eng.bit", p, size * 3.0)
    elif kind == "Core":
        sphere(s, p, size, "ShieldGen", segs=16, rings=8)
        torus(s, p, size * 1.3, size * 0.2, "Trim", segs=32, sides=6, axis='Y')
        torus(s, p, size * 1.3, size * 0.2, "Trim", segs=32, sides=6, axis='X')
    objs.append(s)

# ---------------------------------------------------------------- assets
# Each returns a list of Mesh objects; "Body" first.

def Carrier(rng):
    b = Mesh("Body"); o = [b]
    lo, hi = kit(b, "hull.hangar", (0, 0, 0), scale=(14, 13.5, 6.0))
    dz = hi.z
    # Flight deck on top, hangar mouths at both ends.
    box(b, (0, 0, dz + 3), (86, hi.y - lo.y - 10, 6), "Hull")
    box(b, (0, hi.y - 5.5, dz + 3), (60, 1, 4.5), "Hangar")
    box(b, (0, lo.y + 4.5, dz + 3), (60, 1, 4.5), "Hangar")
    for x in (-43.5, 43.5):
        box(b, (x, 0, dz + 6.4), (1, hi.y - lo.y - 30, 0.6), "Lights")
    for y in range(int(lo.y) + 30, int(hi.y) - 20, 20):
        box(b, (0, y, dz + 6.2), (1.2, 6, 0.3), "Lights")
    kit_pair(b, "hull.long", (40, -20, -4), scale=(8, 11, 6), mat="HullDark")
    for y in (-120, -40, 40):
        kit_pair(b, "Window Block 2", (44, y, dz - 6), length=20)
    # Starboard island.
    bl, bh = kit(b, "Bridge.BeerBelly", (34, -50, dz + 6 + 14), length=34)
    kit(b, "Instrument Mast", (34, -50, bh.z + 18), length=40, rot=(90, 0, 0))
    kit(b, "hardpoint.dev.dish", (34, -72, bh.z + 6), length=12)
    for x in (-24, 0, 24):
        kit_engine(b, "eng.bit", (x, lo.y - 14, -2), length=32)
    kit(b, "Vent Block", (0, -40, lo.z - 8), length=160, mat="HullDark", rot=(180, 0, 0))
    lights(b, [(-46, hi.y - 10, dz + 6), (46, hi.y - 10, dz + 6), (0, lo.y, dz + 8)], 2)
    for p, up in (((-30, 150, dz + 6), (0, 0, 1)), ((-30, -140, dz + 6), (0, 0, 1)), ((0, 110, lo.z - 2), (0, 0, -1)),
                  ((0, -110, lo.z - 2), (0, 0, -1)), ((-50, 60, 0), (-1, 0, 0)), ((50, 60, 0), (1, 0, 0))):
        turret(o, p, up, 1.8)
    return o

def Frigate(rng):
    b = Mesh("Body"); o = [b]
    lo, hi = kit(b, "hull.duckHead", (0, 0, 0), length=140, scale=None)
    kit(b, "Clip bridge", (0, -10, hi.z * 0.3 + 3), length=18)
    for s in (-1, 1):
        kit(b, "eng.strut.foot", (s * 14, -40, -2), length=30, mirror=s < 0, mat="HullDark")
        kit_engine(b, "eng.split", (s * 20, lo.y + 8, -2), length=24)
    kit_engine(b, "eng.Rect", (0, lo.y - 4, 0), length=18)
    windows(b, -40, 30, (hi.x - lo.x) / 2 * 0.9, 0, h=0.8, rows=2, gap=3, side=1)
    windows(b, -40, 30, -(hi.x - lo.x) / 2 * 0.9, 0, h=0.8, rows=2, gap=3, side=-1)
    lights(b, [(-8, 40, 0), (8, 40, 0)])
    turret(o, (0, 30, hi.z - 2), size=0.9, part="hardpoitn.gun.dual"); turret(o, (0, -30, hi.z - 1), size=0.9, part="hardpoitn.gun.dual")
    turret(o, (0, 10, lo.z + 2), (0, 0, -1), 0.9, "hardpoitn.gun.dual"); turret(o, (0, -40, lo.z + 2), (0, 0, -1), 0.9, "hardpoitn.gun.dual")
    return o

def Freighter(rng):
    b = Mesh("Body"); o = [b]
    box(b, (0, -5, 0), (6, 150, 6), "HullDark")
    cl, ch = kit(b, "hull.cruise", (0, 82, 3), length=40, mat="Civil")
    for i in range(6):
        y = -58 + i * 22
        for sx in (-1, 1):
            for sz in (-1, 1):
                kit(b, "Cargo box", (sx * 7.5, y, sz * 7), length=19, mat=rng.choice(["Cargo1", "Cargo2", "Cargo3"]))
    kit(b, "Res Block", (0, -78, 0), length=20, mat="Civil")
    for x in (-7, 7):
        kit_engine(b, "Block Engine single", (x, -95, 0), length=18)
    lights(b, [(-9, 100, 2), (9, 100, 2), (0, -88, 12)])
    return o

def Tanker(rng):
    b = Mesh("Body"); o = [b]
    box(b, (0, -10, 0), (5, 140, 5), "HullDark")
    for y in (-45, 0, 45):
        kit(b, "Tank", (0, y, 0), length=44, mat="Civil")
    kit(b, "Hull.PugNose", (0, 76, 2), length=26, mat="Civil")
    kit(b, "Res Block", (0, -78, 0), length=18, mat="Civil")
    kit_engine(b, "eng.trumpet", (0, -95, 0), length=22)
    lights(b, [(-8, 86, 0), (8, 86, 0), (0, -80, 10)])
    return o

def Liner(rng):
    b = Mesh("Body"); o = [b]
    lo, hi = kit(b, "hull.lump", (0, 0, 0), scale=(11, 14.5, 7), mat="Civil")
    w = (hi.x - lo.x) / 2
    for s in (-1, 1):
        windows(b, lo.y + 40, hi.y - 50, s * w * 0.97, 0, h=0.9, rows=5, gap=3.2, side=s)
    kit(b, "Fore-Bridge", (0, hi.y - 60, hi.z + 6), length=50, mat="Civil")
    kit_pair(b, "Stub Wing", (w + 6, lo.y + 40, 0), length=30, mat="Civil")
    for x in (-12, 12):
        kit_engine(b, "eng.multi", (x, lo.y - 8, 0), length=20)
    lights(b, [(-w, 50, 0), (w, 50, 0), (0, lo.y + 10, hi.z)])
    return o

def HospitalShip(rng):
    b = Mesh("Body"); o = [b]
    lo, hi = kit(b, "hull.pot", (0, 0, 0), length=150, mat="Civil")
    w = (hi.x - lo.x) / 2
    for s in (-1, 1):
        kit(b, "Fin Hangar", (s * (w + 8), -20, 0), length=36, mirror=s < 0, mat="Civil")
        box(b, (s * w * 1.01, 0, 4), (0.4, 90, 2.5), "Glow")
        windows(b, -50, 40, s * w * 0.98, -4, h=0.9, rows=3, gap=3, side=s)
    kit(b, "bridge.compact", (0, 30, hi.z * 0.7 + 6), length=16, mat="Civil")
    kit_engine(b, "eng.trumpet", (0, lo.y - 6, 0), length=20)
    lights(b, [(-w, 60, 0), (w, 60, 0), (0, 0, hi.z)], 1.6)
    return o

def ResearchVessel(rng):
    b = Mesh("Body"); o = [b]
    lo, hi = kit(b, "hull.slick", (0, 0, 0), scale=(9, 10, 6))
    torus(b, (0, -15, 0), 34, 2.5, "Hull", segs=48, sides=8, axis='Y')
    for a in range(4):
        ang = a * math.pi / 2 + math.pi / 4
        beam(b, (0, -15, 0), (math.cos(ang) * 33, -15, math.sin(ang) * 33), 1.5, "Trim")
    kit(b, "hardpoint.dev.dish", (0, hi.y + 4, 2), length=14, rot=(0, 0, 180))
    kit(b, "Telescope", (0, 10, hi.z + 5), length=30)
    kit_engine(b, "eng.Rect", (0, lo.y - 4, 0), length=14)
    lights(b, [(-8, 40, 0), (8, 40, 0)])
    return o

def CommRelay(rng):
    b = Mesh("Body"); o = [b]
    kit(b, "Instrument Tube", (0, 0, 0), length=40, rot=(90, 0, 0))
    truss(b, (0, 0, 22), (0, 0, 140), 6)
    for z in (60, 110):
        for a in (0, 180):
            d = Vector((math.cos(math.radians(a)), math.sin(math.radians(a)), 0))
            kit(b, "hardpoint.dev.dish", d * 7 + Vector((0, 0, z)), length=10, rot=(0, 0, a - 90))
    lights(b, [(0, 0, 141)], 3)
    for s in (-1, 1):
        truss(b, (s * 14, 0, 0), (s * 70, 0, 0), 3)
        box(b, (s * 50, 0, 0), (40, 24, 0.6), "Solar")
    kit_pair(b, "Window Block", (12, 0, -6), length=10)
    turret(o, (0, 14, 12), (0, 0, 1), 0.8, "Small Gun.001")
    subsystem(o, "Core", (0, 0, -28), 6)
    return o

def RingStation(rng):
    b = Mesh("Body"); o = [b]
    torus(b, (0, 0, 0), 220, 18, "Hull", segs=96, sides=12, flat=0.7)
    torus(b, (0, 0, 13), 220, 6, "HullDark", segs=96, sides=6)
    for i in range(48):
        a = 2 * math.pi * i / 48
        box(b, (math.cos(a) * 238.5, math.sin(a) * 238.5, 0), (0.6, 18, 3.2), "Windows", Matrix.Rotation(a, 3, 'Z'))
    for i in range(12):
        a = i * 30
        p = Vector((math.cos(math.radians(a)), math.sin(math.radians(a)), 0)) * 220
        kit(b, rng.choice(["Window Block 2", "Res Block", "Build-up Block", "Vent Block"]), p + Vector((0, 0, 18)), length=28, rot=(0, 0, a))
    for i in range(4):
        a = i * math.pi / 2
        p = Vector((math.cos(a), math.sin(a), 0))
        truss(b, p * 30, p * 205, 10)
        kit(b, "Cargo box", p * 120, length=20, rot=(0, 0, math.degrees(a)))
    kit(b, "Instrument Tube", (0, 0, 0), scale=(14, 18, 14), rot=(90, 0, 0))
    for a in (0.8, 2.3, 3.9, 5.5):
        p = Vector((math.cos(a), math.sin(a), 0))
        truss(b, p * 30 + Vector((0, 0, 40)), p * 120 + Vector((0, 0, 100)), 4)
        box(b, p * 120 + Vector((0, 0, 100)), (60, 30, 0.8), "Solar", Matrix.Rotation(a, 3, 'Z'))
    for i in range(6):
        a = i * math.pi / 3 + 0.3
        turret(o, (math.cos(a) * 220, math.sin(a) * 220, 12.5), (0, 0, 1), 1.4)
    kit(b, "Instrument Mast", (0, 0, 90), length=50, rot=(90, 0, 0))
    subsystem(o, "Core", (0, 0, -70), 14)
    return o

def FuelDepot(rng):
    b = Mesh("Body"); o = [b]
    pts = [Vector((x, y, z)) for x, y, z in ((0, 0, 0), (50, 20, 10), (-50, 20, -10), (20, -50, 15), (-25, -40, -20), (0, 60, 25))]
    for i, p in enumerate(pts):
        if i == 0:
            kit(b, "Res Block", p, length=40)
        else:
            kit(b, "Tank", p, length=36, rot=(0, 0, i * 50), mat="Civil")
            truss(b, pts[0], p, 4)
    kit(b, "Vent Block", (0, 0, -20), length=60, rot=(180, 0, 0), mat="HullDark")
    box(b, (0, 0, 0), (8, 140, 8), "HullDark")
    lights(b, [p + Vector((0, 0, 15)) for p in pts], 2)
    turret(o, (0, 0, 22), (0, 0, 1), 1.0, "Squirtgun")
    turret(o, (0, 0, -24), (0, 0, -1), 1.0, "Squirtgun")
    return o

def Corvette(rng):
    b = Mesh("Body"); o = [b]
    # hull.angle is one half of a hull: mirror it into a wedge.
    hw = PARTS["hull.angle"][3].x * 8 / 2
    lo, hi = kit(b, "hull.angle", (hw - 1, 0, 0), scale=(8, 8.5, 5))
    kit(b, "hull.angle", (-hw + 1, 0, 0), scale=(8, 8.5, 5), mirror=True)
    lo.x = -hi.x
    for s in (-1, 1):
        kit_engine(b, "eng.body.tooth", (s * hw, lo.y - 3, 0), length=16)
        box(b, (s * (hi.x - lo.x) * 0.3, 10, hi.z * 0.6), (0.5, 20, 0.8), "Glow")
    kit(b, "spire", (0, -15, hi.z + 1), length=7)
    turret(o, (0, -5, hi.z - 1), size=0.8, part="hardpoint.gun.fork")
    turret(o, (0, 5, lo.z + 1), (0, 0, -1), 0.8, "hardpoint.gun.fork")
    return o

def Destroyer(rng):
    b = Mesh("Body"); o = [b]
    lo, hi = kit(b, "hull.bullHead", (0, 0, 0), scale=(11, 10, 6))
    kit(b, "Beard Block", (0, -20, lo.z - 10), scale=(8, 9, 4), mat="HullDark")
    bl, bh = kit(b, "Bridge.BeerBelly", (0, -90, hi.z + 14), length=30)
    kit(b, "Instrument Mast", (0, -100, bh.z + 10), length=24, rot=(90, 0, 0))
    for s in (-1, 1):
        kit(b, "Dog Ear", (s * 24, -60, 0), length=60, mirror=s < 0, mat="HullDark")
        box(b, (s * 12, 40, hi.z - 4), (1, 60, 1), "Glow")
    for x, z in ((-16, 0), (16, 0), (0, 14)):
        subsystem(o, "Engine", (x, lo.y - 12, z), 7)
    for p, up in (((0, 60, hi.z - 4), (0, 0, 1)), ((-12, 0, hi.z - 2), (0, 0, 1)), ((12, 0, hi.z - 2), (0, 0, 1)),
                  ((0, -40, lo.z - 8), (0, 0, -1)), ((-28, -60, 0), (-1, 0, 0)), ((28, -60, 0), (1, 0, 0))):
        turret(o, p, up, 1.3)
    lights(b, [(-24, -100, 0), (24, -100, 0)], 2)
    return o

def Cruiser(rng):
    b = Mesh("Body"); o = [b]
    lo, hi = kit(b, "hull.large", (0, -30, 0), scale=(16, 8, 7))
    for s in (-1, 1):
        kit(b, "Crab Claw", (s * 26, hi.y + 30, 0), length=90, mirror=s < 0)
        kit(b, "Outrigger", (s * 40, -80, 0), length=110, mirror=s < 0, mat="HullDark")
        subsystem(o, "Shield", (s * 20, -130, hi.z), 9)
        box(b, (s * 22, 40, hi.z - 2), (1.5, 140, 1.5), "Glow")
    kit(b, "Fore-Bridge", (0, -150, hi.z + 18), length=60)
    kit(b, "Instrument Mast-2", (0, -170, hi.z + 50), length=40, rot=(90, 0, 0))
    kit(b, "Vent Block", (0, -20, lo.z - 10), length=200, rot=(180, 0, 0), mat="HullDark")
    for x in (-30, -10, 10, 30):
        kit_engine(b, "Bracket Engine", (x, lo.y - 16, 0), length=34)
    for p, up in (((-18, 80, hi.z), (0, 0, 1)), ((18, 80, hi.z), (0, 0, 1)), ((-18, -40, hi.z), (0, 0, 1)), ((18, -40, hi.z), (0, 0, 1)),
                  ((0, 40, lo.z - 8), (0, 0, -1)), ((0, -100, lo.z - 8), (0, 0, -1)), ((-48, -20, 0), (-1, 0, 0)), ((48, -20, 0), (1, 0, 0))):
        turret(o, p, up, 1.6)
    return o

def Dreadnought(rng):
    b = Mesh("Body"); o = [b]
    lo, hi = kit(b, "hull.large", (0, 0, 0), scale=(40, 18.5, 12))
    for s in (-1, 1):
        kit(b, "hull.long", (s * 95, -80, -10), scale=(26, 23, 12), mirror=s < 0, mat="HullDark")
        windows(b, -380, 180, s * 108, -10, h=1.2, rows=5, gap=5, side=s)
        box(b, (s * 40, 150, hi.z - 4), (2, 300, 2), "Glow")
        for y in (-260, 0):
            subsystem(o, "Shield", (s * 45, y, hi.z + 20 + (0 if y else 10)), 14)
    # Stepped superstructure and the command tower aft.
    kit(b, "Build-up Block", (0, -60, hi.z + 6), scale=(26, 50, 10))
    kit(b, "Vent Block", (0, -200, hi.z + 18), scale=(12, 14, 8))
    tl, th = kit(b, "Bridge-1.001", (0, -320, hi.z + 46), length=140)
    kit(b, "Instrument Mast-2", (0, -330, th.z + 30), length=70, rot=(90, 0, 0))
    # Dorsal trench with the reactor core forward of the tower.
    box(b, (0, 150, hi.z + 1), (30, 120, 2), "Hangar")
    subsystem(o, "Core", (0, 150, hi.z + 8), 10)
    kit(b, "Vent Block", (0, -40, lo.z - 14), scale=(18, 30, 9), rot=(180, 0, 0), mat="HullDark")
    for x in (-60, -20, 20, 60):
        subsystem(o, "Engine", (x, lo.y - 20, 0), 16)
    for i in range(16):
        y = -380 + i * 50
        x = 50 if i % 2 else -50
        turret(o, (x, y, hi.z + 2), (0, 0, 1), 2.4)
        if i % 3 == 0:
            turret(o, (-x * 0.6, y, lo.z - 6), (0, 0, -1), 2.2)
    lights(b, [(-120, -400, 0), (120, -400, 0)], 4)
    return o

def Minelayer(rng):
    b = Mesh("Body"); o = [b]
    lo, hi = kit(b, "hull.block_split", (0, 0, 0), scale=(9, 18, 7))
    for i in range(5):
        cyl(b, (-12 + i * 6, lo.y - 1, -4), (-12 + i * 6, lo.y - 6, -4), 2, mat="Hangar", segs=8)
    kit(b, "Cargo box", (0, lo.y + 10, hi.z + 5), length=20, mat="HullDark")
    for s in (-1, 1):
        kit_engine(b, "eng.body.fish", (s * 12, lo.y - 4, 6), length=14)
    turret(o, (0, 20, hi.z), size=0.8, part="hardpoint.gun.fork")
    return o

def DefensePlatform(rng):
    b = Mesh("Body"); o = [b]
    sphere(b, (0, 0, 0), 22, "Hull", segs=24, rings=12)
    torus(b, (0, 0, 0), 23, 2, "HullDark", segs=48, sides=6)
    for i in range(4):
        a = i * 90
        p = Vector((math.cos(math.radians(a)), math.sin(math.radians(a)), 0))
        beam(b, p * 20, p * 60, 4, "HullDark")
        kit(b, "hardpoint.base.3x", p * 62, length=22, rot=(0, 0, a - 90))
        turret(o, p * 62 + Vector((0, 0, 6)), (0, 0, 1), 1.0, "Squirtgun")
        lights(b, [p * 74], 2)
    box(b, (0, 0, 0), (46, 0.5, 4), "Glow")
    turret(o, (0, 0, 22), (0, 0, 1), 1.1, "Squirtgun")
    turret(o, (0, 0, -22), (0, 0, -1), 1.1, "Squirtgun")
    subsystem(o, "Core", (0, 0, 0), 9)
    return o

def Shipyard(rng):
    b = Mesh("Body"); o = [b]
    L, W, H = 480, 160, 120
    for x in (-W / 2, W / 2):
        for z in (-H / 2, H / 2):
            truss(b, (x, -L / 2, z), (x, L / 2, z), 10)
    for y in range(-240, 241, 80):
        for (p0, p1) in (((-W / 2, y, -H / 2), (W / 2, y, -H / 2)), ((-W / 2, y, H / 2), (W / 2, y, H / 2)),
                         ((-W / 2, y, -H / 2), (-W / 2, y, H / 2)), ((W / 2, y, -H / 2), (W / 2, y, H / 2))):
            truss(b, p0, p1, 6)
        lights(b, [(-W / 2, y, H / 2), (W / 2, y, H / 2)], 3)
    # The half-built dreadnought hull inside the frame.
    kit(b, "hull.large", (0, -40, 0), scale=(14, 7, 6), mat="HullDark")
    for y in range(-170, 60, 25):
        torus(b, (0, y, 0), 34, 1.5, "Trim", segs=24, sides=4, axis='Y')
    for s in (-1, 1):
        kit(b, "Window Block 2", (s * 90, 0, 0), length=60)
        kit(b, "Pointer", (s * 60, 100, H / 2 - 10), length=60, rot=(0, 0, 90 * s))
        subsystem(o, "Shield", (s * 90, 0, 34), 8)
    for p in ((-80, 200, 60), (80, 200, 60), (-80, -200, -60), (80, -200, -60)):
        turret(o, p, (0, 0, 1 if p[2] > 0 else -1), 1.3)
    subsystem(o, "Core", (0, -230, 0), 12)
    return o

def PrisonBarge(rng):
    b = Mesh("Body"); o = [b]
    box(b, (0, 0, 0), (8, 230, 8), "HullDark")
    for i in range(5):
        y = -80 + i * 40
        kit(b, "Res Block", (0, y, 0), scale=(18, 14, 14))
        for sd in (-1, 1):
            windows(b, y - 11, y + 11, sd * 18, -6, h=0.6, rows=4, gap=4, side=sd)
    kit(b, "Hull.Jaw", (0, 120, 0), length=40)
    kit(b, "Res Block", (0, -125, 0), length=26, mat="HullDark")
    for x in (-10, 10):
        kit_engine(b, "eng.body.splt", (x, -145, 0), length=16)
    for i in range(6):
        y = -90 + i * 40
        turret(o, (0, y, 16 if i % 2 else -16), (0, 0, 1 if i % 2 else -1), 1.0)
    lights(b, [(-20, 100, 0), (20, 100, 0)], 2)
    return o

def Prototype(rng):
    b = Mesh("Body"); o = [b]
    lo, hi = kit(b, "Fin Runner", (0, 0, 0), scale=(14, 2.1, 1.2), mat="HullDark")
    kit_pair(b, "PE-Wing", (14, -12, 0), length=24, mat="HullDark")
    for s in (-1, 1):
        box(b, (s * 8, lo.y - 0.3, 0), (8, 0.5, 1.5), "Glow")
    subsystem(o, "Core", (0, -10, hi.z + 1), 2.5)
    return o

def CorsairBase(rng):
    b = Mesh("Body"); o = [b]
    rock(b, (0, 0, 0), 220, 3.7, detail=4, rough=0.3)
    modules = ["Window Block", "Res Block", "Beehive", "portal block", "Build-up Block", "Cargo box", "Tank", "Vent Block"]
    for i in range(16):
        a, e = rng.uniform(0, 2 * math.pi), rng.uniform(-0.3, 0.9)
        n = Vector((math.cos(a) * math.cos(e), math.sin(a) * math.cos(e), math.sin(e)))
        p = n * 200
        kit(b, rng.choice(modules), p, length=rng.uniform(30, 60), rot=(0, 0, math.degrees(a)), mat=rng.choice(["Hull", "HullDark", "Cargo1"]))
        lights(b, [p + n * 25], 2.5)
    for a in (0.5, 2.6):
        p = Vector((math.cos(a), math.sin(a), 0.5)).normalized() * 215
        subsystem(o, "Shield", p, 12)
    sphere(b, (0, 0, 228), 26, "Hull", segs=20, rings=6, zmin=0.0)
    kit(b, "Instrument Mast-2", (0, 0, 262), length=50, rot=(90, 0, 0))
    kit(b, "Hangar", (0, 228, 0), length=40, mat="HullDark")
    subsystem(o, "Core", (0, 0, 256), 9)
    for i in range(6):
        a = i * math.pi / 3
        turret(o, (math.cos(a) * 200, math.sin(a) * 200, 80), (0, 0, 1), 1.4, "Squirtgun")
    return o

def CorsairCutter(rng):
    b = Mesh("Body"); o = [b]
    lo, hi = kit(b, "Ram", (0, 6, 0), length=40)
    kit(b, "hull.horse", (4, -16, 0), length=36, mat="HullDark")
    kit(b, "Cargo box", (-9, -6, 5), length=14, mat="Cargo1")
    for x in (-7, 5):
        kit_engine(b, "eng.body.fish", (x, -36, 0), length=10)
    turret(o, (0, 5, hi.z + 1), size=0.7, part="hardpoint.gun.barb")
    return o

def Container(rng):
    b = Mesh("Body"); o = [b]
    box(b, (0, 0, 0), (4, 12, 4), "Cargo1")
    for y in (-5.5, -2, 2, 5.5):
        box(b, (0, y, 0), (4.3, 0.4, 4.3), "Trim")
    lights(b, [(0, 6.2, 2)], 0.4)
    return o

def EscapePod(rng):
    b = Mesh("Body"); o = [b]
    sphere(b, (0, 0, 0), 2, "Civil", segs=16, rings=8, scale=(1, 1.4, 1))
    cyl(b, (0, -2.6, 0), (0, -3.4, 0), 0.8, 1.0, "Trim", segs=10)
    box(b, (0, 1.5, 0.8), (1.4, 0.6, 0.5), "Windows")
    lights(b, [(0, 0, 2.1)], 0.5)
    return o

def Mine(rng):
    b = Mesh("Body"); o = [b]
    sphere(b, (0, 0, 0), 1.5, "HullDark", segs=12, rings=6)
    for d in ((1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)):
        cyl(b, Vector(d) * 1.3, Vector(d) * 2.4, 0.25, 0.05, "Trim", segs=6)
    box(b, (0, 0, 0), (3.2, 0.3, 0.3), "Lights")
    return o

def NavBuoy(rng):
    b = Mesh("Body"); o = [b]
    cyl(b, (0, 0, -3), (0, 0, 3), 1.2, 1.2, "Hull", segs=12)
    cyl(b, (0, 0, 3), (0, 0, 4), 1.2, 0.5, "Trim", segs=12)
    antenna(b, (0, 0, 4), 4, 0.15)
    for d in ((1, 0, 0), (-1, 0, 0)):
        box(b, Vector(d) * 2.5, (3, 0.1, 2), "Solar")
    return o

def JumpGate(rng):
    b = Mesh("Body"); o = [b]
    torus(b, (0, 0, 0), 140, 12, "Hull", segs=72, sides=10, axis='Y')
    torus(b, (0, 0, 0), 127, 2.5, "GateGlow", segs=72, sides=6, axis='Y')
    for i in range(8):
        a = i * math.pi / 4
        p = Vector((math.cos(a) * 140, 0, math.sin(a) * 140))
        box(b, p, (26, 30, 26), "HullDark", Matrix.Rotation(-a, 3, 'Y'))
        lights(b, [p * 1.12], 3)
    for s in (-1, 1):
        truss(b, (s * 150, 0, -60), (s * 150, 0, -200), 10)
        box(b, (s * 150, 0, -205), (40, 40, 20), "Hull")
    return o

def Asteroid(seed, r, detail):
    def build(rng):
        b = Mesh("Body")
        rock(b, (0, 0, 0), r, seed, detail=detail, rough=0.4)
        return [b]
    return build

ASSETS = {
    "Carrier": Carrier, "Frigate": Frigate, "Freighter": Freighter, "Tanker": Tanker, "Liner": Liner,
    "HospitalShip": HospitalShip, "ResearchVessel": ResearchVessel, "CommRelay": CommRelay,
    "RingStation": RingStation, "FuelDepot": FuelDepot, "Corvette": Corvette, "Destroyer": Destroyer,
    "Cruiser": Cruiser, "Dreadnought": Dreadnought, "Minelayer": Minelayer, "DefensePlatform": DefensePlatform,
    "Shipyard": Shipyard, "PrisonBarge": PrisonBarge, "Prototype": Prototype, "CorsairBase": CorsairBase,
    "CorsairCutter": CorsairCutter, "Container": Container, "EscapePod": EscapePod, "Mine": Mine,
    "NavBuoy": NavBuoy, "JumpGate": JumpGate,
    "AsteroidA": Asteroid(1.1, 30, 3), "AsteroidB": Asteroid(2.3, 55, 3), "AsteroidC": Asteroid(5.9, 14, 2),
}

# ---------------------------------------------------------------- build + export

def clear():
    for o in list(bpy.data.objects):
        bpy.data.objects.remove(o, do_unlink=True)
    for c in (bpy.data.meshes, bpy.data.materials, bpy.data.cameras, bpy.data.lights):
        for d in list(c):
            c.remove(d)

def preview(name, objs):
    scene = bpy.context.scene
    scene.render.engine = 'BLENDER_WORKBENCH'
    scene.display.shading.light = 'STUDIO'
    scene.display.shading.color_type = 'MATERIAL'
    scene.render.resolution_x, scene.render.resolution_y = 640, 400
    pts = [o.matrix_world @ Vector(c) for o in objs for c in o.bound_box]
    lo = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
    hi = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
    centre, radius = (lo + hi) / 2, (hi - lo).length / 2
    cam = bpy.data.objects.new("Cam", bpy.data.cameras.new("Cam"))
    scene.collection.objects.link(cam)
    cam.data.lens = 50
    d = Vector((1.0, 1.1, 0.6)).normalized()
    cam.location = centre + d * radius * 2.6
    cam.rotation_euler = (centre - cam.location).to_track_quat('-Z', 'Y').to_euler()
    cam.data.clip_end = radius * 10
    scene.camera = cam
    scene.render.filepath = os.path.join(PREVIEW, name + ".png")
    bpy.ops.render.render(write_still=True)

def build(name):
    clear()
    rng = random.Random(hash(name) & 0xffff)
    objs = [m.link(bpy.context.scene.collection) for m in ASSETS[name](rng)]
    os.makedirs(OUT, exist_ok=True)
    bpy.ops.wm.obj_export(filepath=os.path.join(OUT, name + ".obj"), export_selected_objects=False,
                          forward_axis='NEGATIVE_Z', up_axis='Y', export_uv=True, export_normals=True,
                          export_materials=True, export_triangulated_mesh=True, path_mode='STRIP')
    if PREVIEW:
        preview(name, objs)
    tris = sum(len(o.data.polygons) for o in objs)
    return {"asset": name, "objects": len(objs), "faces": tris}

load_kit()
names = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else list(ASSETS)
result = [build(n) for n in names]
for r in result:
    print(r)
