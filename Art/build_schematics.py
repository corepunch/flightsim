#!/usr/bin/env python3
"""Render tactical overlays from the game's OBJ meshes. Requires Pillow."""
import json
import math
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
WIDTH, HEIGHT = 896, 320
PITCH = math.radians(61)
YAW = math.radians(13)


def load_mesh(asset):
    vertices, faces = [], []
    part = "Body"
    path = ROOT / "Resources/Models/Capital" / f"{asset}.obj"
    for line in path.read_text().splitlines():
        tag, _, values = line.partition(" ")
        if tag == "v":
            vertices.append(tuple(map(float, values.split())))
        elif tag == "o":
            part = values.split("_", 1)[0]
        elif tag == "f":
            faces.append((part, [int(corner.split("/")[0]) - 1 for corner in values.split()]))
    return vertices, faces


def project(vertex):
    x, y, z = vertex
    right = -z * math.cos(YAW) - x * math.sin(YAW)
    forward = x * math.cos(YAW) - z * math.sin(YAW)
    up = y * math.cos(PITCH) - forward * math.sin(PITCH)
    depth = y * math.sin(PITCH) + forward * math.cos(PITCH)
    return right, up, depth


def render(asset, kind, output):
    vertices, faces = load_mesh(asset)
    view = [project(v) for v in vertices]
    xs, ys, _ = zip(*view)
    span_x, span_y = max(xs) - min(xs), max(ys) - min(ys)
    scale = min((WIDTH - 100) / span_x, (HEIGHT - 48) / span_y)
    cx, cy = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2
    screen = [(WIDTH / 2 + (x - cx) * scale, HEIGHT / 2 - (y - cy) * scale) for x, y, _ in view]

    assert any(part == kind for part, _ in faces), (asset, kind)
    im = Image.new("RGBA", (WIDTH, HEIGHT))
    draw = ImageDraw.Draw(im)
    faces.sort(key=lambda face: sum(view[i][2] for i in face[1]) / len(face[1]))
    markers = set()
    for part, indices in faces:
        a, b, c = (view[i] for i in indices[:3])
        ab = [y - x for x, y in zip(a, b)]
        ac = [y - x for x, y in zip(a, c)]
        nx = ab[1] * ac[2] - ab[2] * ac[1]
        ny = ab[2] * ac[0] - ab[0] * ac[2]
        nz = ab[0] * ac[1] - ab[1] * ac[0]
        if nz <= 0:
            continue
        shade = (0.25 * nx + 0.55 * ny + 0.80 * nz) / math.sqrt(nx * nx + ny * ny + nz * nz)
        brightness = 0.45 + 0.55 * max(0, shade)
        points = [screen[i] for i in indices]
        if part == kind:
            markers.update(indices)
            color, edge = (255, 92, 86), (255, 125, 98)
        else:
            color, edge = (46, 160, 172), (43, 111, 125)
        draw.polygon(points, fill=tuple(int(c * brightness) for c in color) + (255,),
                     outline=tuple(int(c * brightness) for c in edge) + (255,))
    assert markers, (asset, kind, "selected subsystem is hidden from this view")
    im.save(output / f"{asset}-{kind}.png", optimize=True)


def main():
    output = ROOT / "Resources/Briefing/Schematics"
    output.mkdir(exist_ok=True)
    campaign = json.loads((ROOT / "Resources/Missions/missions.json").read_text())
    requested = set()
    for mission in campaign["missions"]:
        assets = {e["id"]: e["asset"] for e in mission["entities"]}
        for step in mission["briefing"]["steps"]:
            if "schematic" in step:
                requested.add((assets[step["focus"]], step["schematic"]))
    for asset, kind in sorted(requested):
        render(asset, kind, output)


if __name__ == "__main__":
    main()
