#!/usr/bin/env python3
"""Render briefing plans from the game's OBJ meshes. Requires Pillow."""
from collections import defaultdict
import json
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

GAME = Path(__file__).resolve().parents[1]
WIDTH, HEIGHT = 896, 320
PITCH = math.radians(74)
GRID = (100, 200, 198)
TARGET = (255, 137, 104)


def load_mesh(asset):
    vertices, faces = [], []
    path = GAME / "Models/Capital" / f"{asset}.obj"
    for line in path.read_text().splitlines():
        tag, _, values = line.partition(" ")
        if tag == "v":
            vertices.append(tuple(map(float, values.split())))
        elif tag == "o":
            part = values
        elif tag == "usemtl":
            material = values
        elif tag == "f":
            # Omit luminous surface decals from the technical drawing.
            if material not in {"Glow", "Lights", "Windows"}:
                faces.append((part, material, [int(corner.split("/")[0]) - 1 for corner in values.split()]))
    return vertices, faces


def project(vertex):
    x, y, z = vertex
    return -z, y * math.cos(PITCH) - x * math.sin(PITCH), y * math.sin(PITCH) + x * math.cos(PITCH)


def face_normal(view, indices):
    a, b, c = (view[i] for i in indices[:3])
    ab = [y - x for x, y in zip(a, b)]
    ac = [y - x for x, y in zip(a, c)]
    normal = (ab[1] * ac[2] - ab[2] * ac[1],
              ab[2] * ac[0] - ab[0] * ac[2],
              ab[0] * ac[1] - ab[1] * ac[0])
    length = math.hypot(*normal)
    return tuple(n / length for n in normal) if length else (0, 0, 0)


def edges(indices):
    return zip(indices, indices[1:] + indices[:1])


def drawing_grid():
    image = Image.new("RGBA", (WIDTH, HEIGHT))
    draw = ImageDraw.Draw(image)
    left, right, top, bottom = 16, WIDTH - 16, 12, HEIGHT - 12
    for x in range(WIDTH // 2 % 36, WIDTH, 36):
        if left < x < right:
            draw.line((x, top, x, bottom), fill=GRID + (22,))
            draw.line((x, bottom - 7, x, bottom), fill=GRID + (90,), width=2)
    for y in range(HEIGHT // 2 % 36, HEIGHT, 36):
        if top < y < bottom:
            draw.line((left, y, right, y), fill=GRID + (22,))
    for x, dx in ((left, 1), (right, -1)):
        for y, dy in ((top, 1), (bottom, -1)):
            draw.line((x, y + 18 * dy, x, y, x + 24 * dx, y), fill=GRID + (160,), width=3)
    return image


def render(asset, kind, output):
    vertices, faces = load_mesh(asset)
    view = [project(v) for v in vertices]
    used = {i for _, _, indices in faces for i in indices}
    xs, ys, _ = zip(*(view[i] for i in used))
    span_x, span_y = max(xs) - min(xs), max(ys) - min(ys)
    scale = min((WIDTH - 84) / span_x, (HEIGHT - 56) / span_y)
    cx, cy = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2
    screen = [(WIDTH / 2 + (x - cx) * scale, HEIGHT / 2 - (y - cy) * scale) for x, y, _ in view]

    # Blender may duplicate vertices along seams. Match edges by position so
    # flat triangulated faces read as a single plate.
    welded = [tuple(round(n, 3) for n in vertex) for vertex in vertices]
    neighbors = defaultdict(list)
    normals = []
    targets = defaultdict(set)
    for part, material, indices in faces:
        normal = face_normal(view, indices)
        normals.append(normal)
        for a, b in edges(indices):
            neighbors[frozenset((welded[a], welded[b]))].append((part, material, normal))
        if part.split("_", 1)[0] == kind:
            targets[part].update(indices)
    assert targets, (asset, kind)

    hull = Image.new("RGBA", (WIDTH, HEIGHT))
    draw = ImageDraw.Draw(hull)
    order = sorted(range(len(faces)), key=lambda f: sum(view[i][2] for i in faces[f][2]) / len(faces[f][2]))
    for f in order:
        part, material, indices = faces[f]
        nx, ny, nz = normals[f]
        if nz <= 0:
            continue
        shade = max(0, 0.25 * nx + 0.55 * ny + 0.80 * nz)
        if part in targets:
            fill = (154, 53, 40)
            stroke = TARGET
        else:
            base = 14 if material in {"HullDark", "Hangar"} else 24
            fill = (base, base + 20, base + 25)
            stroke = (82, 151, 155)
        draw.polygon([screen[i] for i in indices],
                     fill=tuple(c + round(24 * shade) for c in fill) + (255,))
        for a, b in edges(indices):
            adjacent = neighbors[frozenset((welded[a], welded[b]))]
            if len(adjacent) == 1 or any(
                other != part or other_material != material or other_normal[2] <= 0
                or sum(x * y for x, y in zip(normals[f], other_normal)) < 0.8
                for other, other_material, other_normal in adjacent
            ):
                draw.line((screen[a], screen[b]), fill=stroke + (255,), width=2)

    image = drawing_grid()
    # Trace the silhouette separately so it stays stronger than the panel seams.
    outline = Image.new("RGBA", hull.size, (140, 221, 214))
    outline.putalpha(hull.getchannel("A").filter(ImageFilter.MaxFilter(5)))
    image.alpha_composite(outline)
    image.alpha_composite(hull)

    # Mark every physical target, including mounts on the far side of the hull.
    draw = ImageDraw.Draw(image)
    for indices in targets.values():
        tx, ty = zip(*(screen[i] for i in indices))
        x, y = (min(tx) + max(tx)) / 2, (min(ty) + max(ty)) / 2
        radius = max(10, min(16, max(max(tx) - min(tx), max(ty) - min(ty)) / 2))
        draw.ellipse((x - radius, y - radius, x + radius, y + radius),
                     outline=(48, 20, 19), width=7)
        draw.ellipse((x - radius, y - radius, x + radius, y + radius), outline=TARGET, width=3)
        draw.ellipse((x - 3, y - 3, x + 3, y + 3), fill=(255, 224, 186))

    image.save(output / f"{asset}-{kind}.png", optimize=True)


def main():
    output = GAME / "Briefing/Schematics"
    output.mkdir(exist_ok=True)
    campaign = json.loads((GAME / "Campaign/campaign.json").read_text())
    requested = set()
    for mission in campaign["missions"]:
        level = json.loads((GAME / "Levels" / f"{mission['level']}.json").read_text())
        assets = {e["id"]: e["asset"] for e in level["entities"]}
        for step in mission["briefing"]["steps"]:
            if "schematic" in step:
                requested.add((assets[step["focus"]], step["schematic"]))
    for asset, kind in sorted(requested):
        render(asset, kind, output)


if __name__ == "__main__":
    main()
