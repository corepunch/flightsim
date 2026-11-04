# Builds the capital ships, stations and props and exports one OBJ per asset
# into Resources/Models/Capital/.
#
#   Blender -b --factory-startup --python Art/build_capitals.py [-- Name ...]
#   CAPITAL_PREVIEW=<dir> also renders a 3/4 preview of each asset there.
#
# Space: metres, +Y is the bow, +Z up. The OBJ export maps +Y to -Z, the
# game's forward. All designs are original kitbashes built from the part
# functions below.
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

    def faces(self, verts, faces, mat):
        mi = self.mat(mat)
        vs = [self.bm.verts.new(v) for v in verts]
        tile = WIN_TILE if mat == "Windows" else (TILE, TILE)
        for f in faces:
            try:
                face = self.bm.faces.new([vs[i] for i in f])
            except ValueError:
                continue
            face.material_index = mi
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

def turret(objs, p, up=(0, 0, 1), size=1.0):
    """Twin-barrel turret as its own object, barrels along +Y."""
    t = Mesh("Turret_%d" % (sum(1 for o in objs if o.name.startswith("Turret")) + 1))
    up = Vector(up).normalized()
    p = Vector(p)
    s = size
    rot = Matrix.Identity(3) if up.z > 0.5 else (Matrix.Rotation(math.pi, 3, 'Y') if up.z < -0.5 else
                                                   Matrix.Rotation(-math.copysign(math.pi / 2, up.x), 3, 'Y'))
    def at(v):
        return p + rot @ Vector(v) * s
    cyl(t, at((0, 0, 0)), at((0, 0, 1.2)), 3.2 * s, 2.8 * s, "HullDark", segs=12)
    sphere_pts = at((0, 0, 1.2))
    sphere(t, sphere_pts, 2.4 * s, "Hull", segs=12, rings=4, zmin=0.0) if up.z > 0.5 else box(t, at((0, 0, 2)), (4 * s, 4 * s, 2 * s), "Hull", rot)
    for sx in (-0.9, 0.9):
        cyl(t, at((sx, 0.5, 2.0)), at((sx, 7.5, 2.0)), 0.35 * s, 0.3 * s, "Trim", segs=6)
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
        engine(s, p, size, size * 3.0, "HullDark")
    elif kind == "Core":
        sphere(s, p, size, "ShieldGen", segs=16, rings=8)
        torus(s, p, size * 1.3, size * 0.2, "Trim", segs=32, sides=6, axis='Y')
        torus(s, p, size * 1.3, size * 0.2, "Trim", segs=32, sides=6, axis='X')
    objs.append(s)

# ---------------------------------------------------------------- assets
# Each returns a list of Mesh objects; "Body" first.

def Carrier(rng):
    b = Mesh("Body"); o = [b]
    loft(b, [(-210, 40, 30, 0), (-190, 70, 42, 0), (150, 70, 42, 0), (200, 46, 30, -4), (215, 20, 14, -6)])
    # flight deck with hangar mouths fore and aft
    box(b, (0, 10, 26), (84, 400, 8), "Hull")
    box(b, (0, 209.5, 26), (60, 1, 6), "Hangar")
    box(b, (0, -189.5, 26), (60, 1, 6), "Hangar")
    for x in (-42.5, 42.5):
        box(b, (x, 10, 30.5), (1, 380, 0.6), "Lights")
    for y in range(-180, 200, 20):
        box(b, (0, y, 30.3), (1.2, 6, 0.3), "Lights")
    # starboard island
    tower(b, (36, -40, 30), [(16, 60, 14), (12, 44, 10), (9, 26, 8)])
    antenna(b, (36, -40, 62), 26, 0.8, dish=8)
    antenna(b, (36, -56, 62), 16, 0.6)
    # sponsons, keel, engines
    for s in (-1, 1):
        box(b, (s * 41, -35, -10), (14, 230, 18), "HullDark")
        windows(b, -140, 70, s * 48, -10, h=1.2, rows=3, gap=4, side=s)
    box(b, (0, 0, -24), (40, 320, 10), "HullDark")
    for x in (-24, 0, 24):
        engine(b, (x, -205, 4), 9, 20)
    greebles(b, rng, (0, 0, -29), (36, 300), 60, (0, 0, -1))
    greebles(b, rng, (-30, 0, 30), (20, 360), 40, (0, 0, 1))
    lights(b, [(-44, 205, 26), (44, 205, 26), (0, -212, 30)], 2)
    for p, up in (((-30, 160, 30), (0, 0, 1)), ((-30, -150, 30), (0, 0, 1)), ((0, 120, -29), (0, 0, -1)),
                  ((0, -120, -29), (0, 0, -1)), ((-48, 40, 0), (-1, 0, 0)), ((48, 40, 0), (1, 0, 0))):
        turret(o, p, up, 1.6)
    return o

def Frigate(rng):
    b = Mesh("Body"); o = [b]
    loft(b, [(-60, 16, 16, 0), (-40, 24, 20, 0), (30, 22, 18, 0), (55, 10, 10, 0), (75, 3, 3, 0)])
    box(b, (0, 80, 0), (1, 14, 1), "Trim")
    tower(b, (0, -10, 9), [(10, 22, 6), (7, 12, 5)])
    for s in (-1, 1):
        beam(b, (s * 10, -30, 0), (s * 22, -40, -2), 2, "HullDark")
        loft(b, [(-62, 6, 6, -2), (-20, 8, 8, -2), (-10, 5, 5, -2)], "HullDark", x=s * 22)
        engine(b, (s * 22, -60, -2), 3.5, 8)
        windows(b, -30, 25, s * 11.5, 2, h=0.8, rows=2, gap=3, side=s)
    engine(b, (0, -62, 0), 6, 10)
    greebles(b, rng, (0, 0, 9), (16, 70), 25)
    lights(b, [(-12, 30, 0), (12, 30, 0)])
    turret(o, (0, 30, 9), size=0.9); turret(o, (0, -40, 9), size=0.9)
    turret(o, (0, 10, -9), (0, 0, -1), 0.9); turret(o, (0, -30, -9), (0, 0, -1), 0.9)
    return o

def Freighter(rng):
    b = Mesh("Body"); o = [b]
    box(b, (0, 0, 0), (6, 150, 6), "HullDark")
    loft(b, [(70, 20, 16, 2), (90, 18, 14, 2), (100, 8, 8, 2)])
    windows(b, 80, 96, 9, 6, h=1.0, side=1); windows(b, 80, 96, -9, 6, h=1.0, side=-1)
    box(b, (0, 100.2, 5), (10, 0.4, 2), "Windows")
    for i in range(6):
        y = -55 + i * 21
        for sx in (-1, 1):
            for sz in (-1, 1):
                box(b, (sx * 7, y, sz * 7), (12, 18, 12), rng.choice(["Cargo1", "Cargo2", "Cargo3"]))
    box(b, (0, -80, 0), (24, 20, 18), "Hull")
    for x in (-7, 7):
        engine(b, (x, -92, 0), 5, 10)
    lights(b, [(-10, 100, 2), (10, 100, 2), (0, -90, 10)])
    return o

def Tanker(rng):
    b = Mesh("Body"); o = [b]
    box(b, (0, -10, 0), (5, 130, 5), "HullDark")
    for y in (-40, 0, 40):
        sphere(b, (0, y, 0), 18, "Civil", segs=24, rings=12)
        torus(b, (0, y, 0), 18.3, 0.8, "Trim", segs=40, sides=6, axis='Y')
    loft(b, [(60, 14, 12, 0), (75, 12, 10, 0), (82, 6, 6, 0)])
    windows(b, 64, 78, 7, 3, side=1); windows(b, 64, 78, -7, 3, side=-1)
    box(b, (0, -75, 0), (18, 20, 14), "Hull")
    engine(b, (0, -88, 0), 6, 10)
    lights(b, [(-8, 80, 0), (8, 80, 0), (0, -80, 8)])
    return o

def Liner(rng):
    b = Mesh("Body"); o = [b]
    loft(b, [(-110, 20, 16, 0, 0.45), (-80, 40, 30, 0, 0.45), (60, 44, 34, 0, 0.45), (100, 24, 20, -2, 0.45), (120, 6, 6, -4, 0.45)], "Civil")
    for s in (-1, 1):
        windows(b, -75, 70, s * 21.6, -6, h=0.9, rows=5, gap=3.2, side=s)
        loft(b, [(-100, 2, 24, 18, 0.2), (-60, 2, 8, 14, 0.2)], "Civil", x=s * 12)
    box(b, (0, 101, 4), (14, 0.5, 4), "Windows")
    box(b, (0, -30, 18), (20, 90, 4), "Windows")
    for x in (-12, 12):
        engine(b, (x, -110, -2), 6, 12)
    lights(b, [(-22, 50, 0), (22, 50, 0), (0, -100, 30)])
    return o

def HospitalShip(rng):
    b = Mesh("Body"); o = [b]
    loft(b, [(-70, 20, 18, 0, 0.4), (-50, 30, 24, 0, 0.4), (40, 30, 24, 0, 0.4), (70, 16, 14, 0, 0.4)], "Civil")
    for s in (-1, 1):
        windows(b, -45, 40, s * 15.2, -4, h=0.9, rows=3, gap=3, side=s)
        box(b, (s * 15.3, 0, 6), (0.4, 80, 2.5), "Glow")   # medical stripe
        box(b, (s * 24, -20, 0), (14, 30, 10), "Civil")
        box(b, (s * 24, -5, 0), (10, 0.5, 6), "Hangar")
    tower(b, (0, 20, 12), [(14, 20, 5)])
    engine(b, (0, -72, 0), 6, 10)
    lights(b, [(-15, 60, 0), (15, 60, 0), (0, 0, 13)], 1.6)
    return o

def ResearchVessel(rng):
    b = Mesh("Body"); o = [b]
    loft(b, [(-50, 14, 12, 0), (-30, 20, 16, 0), (30, 18, 14, 0), (55, 8, 8, 0)])
    torus(b, (0, -10, 0), 34, 2.5, "Hull", segs=48, sides=8, axis='Y')
    for a in range(4):
        ang = a * math.pi / 2 + math.pi / 4
        beam(b, (0, -10, 0), (math.cos(ang) * 33, -10, math.sin(ang) * 33), 1.5, "Trim")
    cyl(b, (0, 55, 0), (0, 62, 0), 2, 16, "Trim", segs=24)   # forward sensor dish
    cyl(b, (0, 50, 0), (0, 56, 0), 1.2, mat="Trim")
    for s in (-1, 1):
        beam(b, (s * 9, 20, 0), (s * 30, 60, 0), 0.8, "Trim")
        lights(b, [(s * 30, 60, 0)], 1.5)
        windows(b, -25, 25, s * 9.5, 2, h=0.8, rows=2, gap=2.5, side=s)
    antenna(b, (0, 0, 8), 14, 0.5, dish=5)
    engine(b, (0, -52, 0), 5, 8)
    return o

def CommRelay(rng):
    b = Mesh("Body"); o = [b]
    cyl(b, (0, 0, -20), (0, 0, 20), 14, 14, "Hull", segs=16)
    cyl(b, (0, 0, 20), (0, 0, 24), 14, 9, "HullDark", segs=16)
    cyl(b, (0, 0, -20), (0, 0, -26), 14, 6, "HullDark", segs=16)
    truss(b, (0, 0, 24), (0, 0, 140), 6)
    for z, d in ((60, 14), (95, 10), (125, 8)):
        for a in (0, 2.1, 4.2):
            dx, dy = math.cos(a), math.sin(a)
            cyl(b, (dx * 4, dy * 4, z), (dx * 6, dy * 6, z + 2), d * 0.15, d, "Trim", segs=16)
    lights(b, [(0, 0, 141)], 3)
    for s in (-1, 1):
        truss(b, (s * 14, 0, 0), (s * 70, 0, 0), 3)
        box(b, (s * 50, 0, 0), (40, 24, 0.6), "Solar")
    windows(b, -8, 8, 14, 5, h=1.2, rows=3, gap=4, side=1)
    windows(b, -8, 8, -14, 5, h=1.2, rows=3, gap=4, side=-1)
    turret(o, (0, 14, 10), (0, 0, 1), 0.8)
    subsystem(o, "Core", (0, 0, 0), 6)
    return o

def RingStation(rng):
    b = Mesh("Body"); o = [b]
    torus(b, (0, 0, 0), 220, 18, "Hull", segs=96, sides=12, flat=0.7)
    torus(b, (0, 0, 13), 220, 6, "HullDark", segs=96, sides=6)
    for i in range(48):
        a = 2 * math.pi * i / 48
        box(b, (math.cos(a) * 238.5, math.sin(a) * 238.5, 0), (0.6, 18, 3.2), "Windows",
            Matrix.Rotation(a, 3, 'Z'))
    for i in range(4):
        a = i * math.pi / 2
        p = Vector((math.cos(a), math.sin(a), 0))
        truss(b, p * 30, p * 205, 10)
        box(b, p * 120, (14, 14, 14), "HullDark")
    cyl(b, (0, 0, -60), (0, 0, 60), 30, 30, "Hull", segs=24)
    cyl(b, (0, 0, 60), (0, 0, 80), 30, 14, "HullDark", segs=24)
    cyl(b, (0, 0, -60), (0, 0, -90), 30, 10, "HullDark", segs=24)
    for z in range(-50, 60, 12):
        torus(b, (0, 0, z), 30.3, 0.8, "Windows", segs=32, sides=4)
    for a in (0.8, 2.3, 3.9, 5.5):
        p = Vector((math.cos(a), math.sin(a), 0))
        truss(b, p * 30 + Vector((0, 0, 40)), p * 120 + Vector((0, 0, 100)), 4)
        box(b, p * 120 + Vector((0, 0, 100)), (60, 30, 0.8), "Solar", Matrix.Rotation(a, 3, 'Z'))
    for i in range(6):
        a = i * math.pi / 3 + 0.3
        turret(o, (math.cos(a) * 220, math.sin(a) * 220, 12.5), (0, 0, 1), 1.4)
    antenna(b, (0, 0, 80), 40, 1.2, dish=12)
    subsystem(o, "Core", (0, 0, 0), 14)
    return o

def FuelDepot(rng):
    b = Mesh("Body"); o = [b]
    pts = [Vector((x, y, z)) for x, y, z in ((0, 0, 0), (50, 20, 10), (-50, 20, -10), (20, -50, 15), (-25, -40, -20), (0, 60, 25))]
    for i, p in enumerate(pts):
        sphere(b, p, 20 if i == 0 else 14, "Civil" if i else "Hull", segs=20, rings=10)
        if i:
            truss(b, pts[0], p, 4)
    box(b, (0, 0, 0), (8, 140, 8), "HullDark")
    box(b, (0, 70, 0), (20, 4, 20), "Hull")
    lights(b, [p + Vector((0, 0, 15)) for p in pts], 2)
    turret(o, (0, 0, 20), (0, 0, 1), 1.0)
    turret(o, (0, 0, -20), (0, 0, -1), 1.0)
    return o

def Corvette(rng):
    b = Mesh("Body"); o = [b]
    loft(b, [(-40, 34, 10, 0, 0.15), (-20, 30, 12, 0, 0.15), (25, 10, 8, 0, 0.15), (48, 2, 2, 0, 0.15)])
    loft(b, [(-38, 2, 14, 8, 0.1), (0, 2, 6, 6, 0.1)], "HullDark")
    for s in (-1, 1):
        box(b, (s * 15, -30, 0), (6, 16, 8), "HullDark")
        engine(b, (s * 15, -40, 0), 3, 6)
        box(b, (s * 8, 10, 3.6), (0.5, 14, 0.8), "Glow")
    box(b, (0, 0, 6), (6, 10, 2), "Windows")
    greebles(b, rng, (0, -15, 6), (24, 30), 15)
    turret(o, (0, -10, 6), size=0.8)
    turret(o, (0, 0, -6), (0, 0, -1), 0.8)
    return o

def Destroyer(rng):
    b = Mesh("Body"); o = [b]
    loft(b, [(-135, 40, 26, 0, 0.15), (-80, 56, 30, 0, 0.15), (40, 40, 22, 0, 0.15), (110, 12, 10, -2, 0.15), (145, 2, 2, -3, 0.15)], "Hull")
    loft(b, [(-120, 30, 10, 18, 0.2), (-40, 26, 8, 16, 0.2), (10, 10, 4, 13, 0.2)], "HullDark")
    tower(b, (0, -90, 22), [(22, 30, 8), (16, 18, 6), (26, 8, 4)])
    for s in (-1, 1):
        loft(b, [(-110, 2, 16, 8, 0.1), (-60, 2, 6, 6, 0.1)], "HullDark", x=s * 30)
        box(b, (s * 40, -70, -4), (24, 50, 4), "HullDark")
        windows(b, -100, 30, s * 25, 2, h=0.8, rows=3, gap=3.5, side=s)
        box(b, (s * 18, 40, 8), (1, 60, 1), "Glow")
    greebles(b, rng, (0, -20, 22), (30, 160), 50)
    greebles(b, rng, (0, -20, -13), (40, 180), 40, (0, 0, -1))
    engine(b, (0, -140, 0), 10, 14)
    for x in (-24, 24):
        subsystem(o, "Engine", (x, -138, 0), 7)
    subsystem(o, "Engine", (0, -138, 14), 5)
    for p, up in (((0, 60, 12), (0, 0, 1)), ((-14, 0, 15), (0, 0, 1)), ((14, 0, 15), (0, 0, 1)),
                  ((0, -40, -15), (0, 0, -1)), ((-26, -60, 0), (-1, 0, 0)), ((26, -60, 0), (1, 0, 0))):
        turret(o, p, up, 1.2)
    lights(b, [(-28, -100, 0), (28, -100, 0)], 2)
    return o

def Cruiser(rng):
    b = Mesh("Body"); o = [b]
    loft(b, [(-210, 60, 40, 0, 0.2), (-150, 90, 50, 0, 0.2), (60, 80, 44, 0, 0.2), (120, 60, 30, 0, 0.2)], "Hull")
    for s in (-1, 1):   # twin forked bow
        loft(b, [(110, 22, 26, 0, 0.2), (180, 16, 18, -2, 0.2), (215, 4, 6, -4, 0.2)], "Hull", x=s * 22)
        windows(b, -190, 50, s * 45, 0, h=1, rows=4, gap=5, side=s)
        box(b, (s * 30, 60, 22), (1.5, 120, 1.5), "Glow")
        subsystem(o, "Shield", (s * 30, -120, 25), 9)
    box(b, (0, 170, 0), (26, 70, 10), "Hangar")
    tower(b, (0, -150, 25), [(40, 50, 12), (28, 30, 10), (16, 16, 8)])
    antenna(b, (0, -150, 55), 30, 1.0, dish=10)
    greebles(b, rng, (0, -30, 25), (60, 250), 80)
    greebles(b, rng, (0, -30, -22), (60, 250), 60, (0, 0, -1))
    for x in (-30, -10, 10, 30):
        engine(b, (x, -215, 0), 9, 16)
    for p, up in (((-25, 80, 22), (0, 0, 1)), ((25, 80, 22), (0, 0, 1)), ((-30, -40, 25), (0, 0, 1)), ((30, -40, 25), (0, 0, 1)),
                  ((0, 40, -22), (0, 0, -1)), ((0, -100, -22), (0, 0, -1)), ((-45, -20, 0), (-1, 0, 0)), ((45, -20, 0), (1, 0, 0))):
        turret(o, p, up, 1.5)
    return o

def Dreadnought(rng):
    b = Mesh("Body"); o = [b]
    loft(b, [(-450, 120, 80, 0, 0.15), (-350, 170, 100, 0, 0.15), (200, 140, 80, 0, 0.15), (380, 60, 40, -6, 0.15), (460, 10, 10, -8, 0.15)], "Hull")
    # stepped superstructure
    for i, (w, l, h) in enumerate([(130, 600, 20), (100, 420, 18), (70, 260, 16)]):
        box(b, (0, -80 - i * 30, 50 + i * 18 + h / 2 - 9), (w, l, h), "HullDark" if i % 2 else "Hull")
    tower(b, (0, -300, 104), [(50, 50, 14), (36, 30, 12), (60, 12, 6)])
    for s in (-1, 1):
        loft(b, [(-400, 4, 60, 30), (-250, 4, 20, 20)], "HullDark", x=s * 100)
        box(b, (s * 90, -100, -10), (30, 500, 30), "HullDark")
        windows(b, -380, 180, s * 105.2, -10, h=1.2, rows=5, gap=5, side=s)
        box(b, (s * 60, 150, 42), (2, 300, 2), "Glow")
        for y in (-260, 0):
            subsystem(o, "Shield", (s * 55, y, 60 + (0 if y else 18)), 14)
    # trench with the reactor core on the dorsal centreline
    box(b, (0, 120, 41), (30, 120, 2), "Hangar")
    subsystem(o, "Core", (0, 120, 46), 10)
    greebles(b, rng, (0, 0, 50), (150, 700), 160)
    greebles(b, rng, (0, -50, -40), (150, 700), 120, (0, 0, -1))
    for x in (-60, -20, 20, 60):
        subsystem(o, "Engine", (x, -452, 0), 16)
    for i in range(16):
        y = -380 + i * 50
        x = 70 if i % 2 else -70
        turret(o, (x, y, 50), (0, 0, 1), 2.2)
        if i % 3 == 0:
            turret(o, (-x * 0.5, y, -40), (0, 0, -1), 2.0)
    lights(b, [(-108, -400, 0), (108, -400, 0)], 4)
    return o

def Minelayer(rng):
    b = Mesh("Body"); o = [b]
    loft(b, [(-55, 30, 20, 0, 0.1), (20, 26, 18, 0, 0.1), (50, 10, 10, 0, 0.1)], "Hull")
    for i in range(5):
        cyl(b, (-12 + i * 6, -56, -6), (-12 + i * 6, -62, -6), 2, mat="Hangar", segs=8)
    box(b, (0, -50, -6), (34, 14, 10), "HullDark")
    for s in (-1, 1):
        engine(b, (s * 12, -58, 6), 4, 8)
        box(b, (s * 13, 0, 4), (0.4, 40, 1), "Glow")
    box(b, (0, 30, 9), (8, 8, 2), "Windows")
    turret(o, (0, 0, 10), size=0.8)
    return o

def DefensePlatform(rng):
    b = Mesh("Body"); o = [b]
    sphere(b, (0, 0, 0), 22, "Hull", segs=24, rings=12)
    torus(b, (0, 0, 0), 23, 2, "HullDark", segs=48, sides=6)
    for i in range(4):
        a = i * math.pi / 2
        p = Vector((math.cos(a), math.sin(a), 0))
        beam(b, p * 20, p * 60, 4, "HullDark")
        box(b, p * 62, (14, 14, 10), "Hull", Matrix.Rotation(a, 3, 'Z'))
        turret(o, p * 62 + Vector((0, 0, 5)), (0, 0, 1), 1.0)
        lights(b, [p * 70], 2)
    box(b, (0, 0, 0), (46, 0.5, 4), "Glow")
    turret(o, (0, 0, 22), (0, 0, 1), 1.1)
    turret(o, (0, 0, -22), (0, 0, -1), 1.1)
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
    # half-built hull inside
    loft(b, [(-160, 50, 36, 0, 0.15), (60, 44, 30, 0, 0.15), (140, 12, 10, 0, 0.15)], "HullDark")
    for y in range(-150, 100, 25):
        torus(b, (0, y, 0), 30, 1.5, "Trim", segs=24, sides=4, axis='Y')
    for s in (-1, 1):
        box(b, (s * 90, 0, 0), (20, 80, 40), "Hull")
        windows(b, -30, 30, s * 100, 0, h=1.2, rows=4, gap=5, side=s)
        beam(b, (s * 80, 100, H / 2), (s * 20, 100, 30), 3, "Cargo1")
        subsystem(o, "Shield", (s * 90, 0, 20), 8)
    for p in ((-80, 200, 60), (80, 200, 60), (-80, -200, -60), (80, -200, -60)):
        turret(o, p, (0, 0, 1 if p[2] > 0 else -1), 1.3)
    subsystem(o, "Core", (0, -230, 0), 12)
    return o

def PrisonBarge(rng):
    b = Mesh("Body"); o = [b]
    box(b, (0, 0, 0), (8, 230, 8), "HullDark")
    for i in range(5):
        y = -80 + i * 40
        box(b, (0, y, 0), (40, 30, 30), "Hull")
        for s in (-1, 1):
            windows(b, y - 12, y + 12, s * 20, -6, h=0.6, rows=4, gap=4, side=s)
    loft(b, [(105, 30, 24, 0, 0.2), (125, 22, 16, 0, 0.2), (135, 8, 6, 0, 0.2)])
    box(b, (0, -125, 0), (34, 20, 26), "HullDark")
    for x in (-10, 10):
        engine(b, (x, -137, 0), 6, 10)
    for i in range(6):
        y = -90 + i * 40
        turret(o, (0, y, 15 if i % 2 else -15), (0, 0, 1 if i % 2 else -1), 1.0)
    lights(b, [(-20, 100, 0), (20, 100, 0)], 2)
    return o

def Prototype(rng):
    b = Mesh("Body"); o = [b]
    loft(b, [(-30, 44, 4, 0, 0.45), (-10, 36, 6, 0, 0.45), (20, 12, 4, 0, 0.45), (34, 1, 1, 0, 0.45)], "HullDark")
    loft(b, [(-25, 10, 3, 3, 0.45), (5, 6, 2, 3, 0.45)], "HullDark")
    for s in (-1, 1):
        box(b, (s * 12, -30.5, 0), (10, 0.5, 1.5), "Glow")
        box(b, (s * 10, 0, 2.2), (0.3, 30, 0.3), "Glow")
    subsystem(o, "Core", (0, -10, 0), 2.5)
    return o

def CorsairBase(rng):
    b = Mesh("Body"); o = [b]
    rock(b, (0, 0, 0), 220, 3.7, detail=4, rough=0.3)
    for i in range(14):
        a, e = rng.uniform(0, 2 * math.pi), rng.uniform(-0.3, 0.9)
        n = Vector((math.cos(a) * math.cos(e), math.sin(a) * math.cos(e), math.sin(e)))
        p = n * 205
        s = rng.uniform(15, 40)
        box(b, p, (s, s, s * 0.6), rng.choice(["Hull", "HullDark", "Cargo1"]))
        lights(b, [p + n * s * 0.4], 2.5)
        if i % 3 == 0:
            windows(b, p.y - s * 0.3, p.y + s * 0.3, p.x + s * 0.5, p.z, h=1.2, rows=2, gap=3, side=1)
    for a in (0.5, 2.6):
        p = Vector((math.cos(a), math.sin(a), 0.5)).normalized() * 215
        subsystem(o, "Shield", p, 12)
    sphere(b, (0, 0, 228), 26, "Hull", segs=20, rings=6, zmin=0.0)
    antenna(b, (0, 0, 250), 40, 1.5, dish=10)
    box(b, (0, 225, 0), (60, 30, 30), "HullDark")
    box(b, (0, 240.5, 0), (40, 1, 18), "Hangar")
    subsystem(o, "Core", (0, 0, 254), 9)
    for i in range(6):
        a = i * math.pi / 3
        turret(o, (math.cos(a) * 200, math.sin(a) * 200, 80), (0, 0, 1), 1.4)
    return o

def CorsairCutter(rng):
    b = Mesh("Body"); o = [b]
    loft(b, [(-30, 16, 12, 0, 0.1), (10, 18, 14, 0, 0.1), (35, 8, 8, -2, 0.1)], "Hull")
    box(b, (10, -5, 7), (12, 20, 6), "Cargo1")
    box(b, (-9, 15, 5), (6, 12, 6), "HullDark")
    for x in (-8, 4):
        engine(b, (x, -32, 0), 3, 6)
    box(b, (0, 30, 3), (6, 4, 2), "Windows")
    turret(o, (0, 5, 10), size=0.7)
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

names = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else list(ASSETS)
result = [build(n) for n in names]
for r in result:
    print(r)
