#!/usr/bin/env python3
"""Checks every ship definition's attachment points against its mesh.

Gun muzzles and exhaust nozzles are given in ship space (forward is -Z); a
point that sits off the model draws its flash or plume in empty space. The
OBJ is read in its own frame (+Z nose) and turned into ship space the way the
renderer does: half a turn about Y.
"""
import glob, json, math, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GUN_REACH, NOZZLE_REACH = 0.5, 0.8     # metres from the nearest vertex


def vertices(path):
    out = []
    with open(path, errors="ignore") as f:
        for line in f:
            if line.startswith("v "):
                x, y, z = (float(c) for c in line.split()[1:4])
                out.append((-x, y, -z))
    return out


def mesh_path(game, mesh):
    for folder in [game] + sorted(glob.glob(os.path.join(ROOT, "Games", "*"))):
        path = os.path.join(folder, "Models", mesh + ".obj")
        if os.path.exists(path):
            return path
    return None


def main():
    problems = 0
    meshes = {}
    for ship in sorted(glob.glob(os.path.join(ROOT, "Games", "*", "Data", "Ships", "*.json"))):
        game = ship.split(os.sep + "Data" + os.sep)[0]
        with open(ship) as f:
            d = json.load(f)
        mesh = d.get("mesh", os.path.basename(ship)[:-5])
        path = mesh_path(game, mesh)
        if not path:
            print(f"{os.path.relpath(ship, ROOT)}: no mesh {mesh}.obj")
            problems += 1
            continue
        if path not in meshes:
            meshes[path] = vertices(path)
        vs = meshes[path]
        for key, reach in (("guns", GUN_REACH), ("nozzles", NOZZLE_REACH)):
            for p in d.get(key, []):
                point = tuple(p[:3])
                gap = min(math.dist(point, v) for v in vs)
                if gap > reach:
                    print(f"{os.path.relpath(ship, ROOT)}: {key} point {list(point)} is {gap:.2f} m off the {mesh} mesh (limit {reach})")
                    problems += 1
    if problems:
        print(f"validate_ships: {problems} problem(s)")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
