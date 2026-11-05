#!/usr/bin/env python3
"""One header per folder: merges every header in a source folder into
<Folder>/<Folder>.h and rewrites #import/#include lines across the tree.

    python3 -I Tools/merge_headers.py analyze   # folder graph, SDK imports, cycles
    python3 -I Tools/merge_headers.py apply     # merge, rewrite, git rm the old headers

Prefix.h files are precompiled-header prefixes the build injects with
-include: they are left as they are. Folders in SKIP keep their headers.
"""
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCOPE = ("Sources/", "Games/")
KEEP = {"Prefix.h"}
INCLUDE = re.compile(r'^(\s*#\s*(?:import|include)\s*)"([^"]+\.h)"(.*)$')
SDK = re.compile(r'^\s*#\s*(?:import|include)\s*<([^>]+)>')
COND_OPEN = re.compile(r'^\s*#\s*if')
COND_CLOSE = re.compile(r'^\s*#\s*endif')
ONCE = re.compile(r'^\s*#\s*pragma\s+once\s*$')
# Files that change folder first. Input/ breaks the App <-> UI header cycle;
# Refresh/ is the SceneKit-free drawing interface the client builds against
# (Tools/run-unit-checks.sh), so it cannot share a header with the renderer;
# Audio/ likewise, as the client plays sound but must not see App's SceneKit.
MOVES = {
    "Sources/Engine/App/GameAudio.h": "Sources/Engine/Audio/GameAudio.h",
    "Sources/Engine/App/GameAudio.m": "Sources/Engine/Audio/GameAudio.m",
    "Sources/Engine/App/Input.h": "Sources/Engine/Input/Input.h",
    "Sources/Engine/App/Input.m": "Sources/Engine/Input/Input.m",
    "Sources/Engine/App/InputIOS.m": "Sources/Engine/Input/InputIOS.m",
    "Sources/Engine/App/InputAction.h": "Sources/Engine/Input/InputAction.h",
    "Sources/Engine/UI/ScreenInput.h": "Sources/Engine/Input/ScreenInput.h",
    "Sources/Engine/UI/ScreenInput.m": "Sources/Engine/Input/ScreenInput.m",
    "Sources/Engine/Render/Refresh.h": "Sources/Engine/Refresh/Refresh.h",
    "Sources/Engine/Render/CockpitFrame.h": "Sources/Engine/Refresh/CockpitFrame.h",
    "Sources/Engine/Render/HUD.h": "Sources/Engine/Refresh/HUD.h",
    "Sources/Engine/Render/HUD.m": "Sources/Engine/Refresh/HUD.m",
}


def git_files(*patterns):
    out = subprocess.check_output(["git", "ls-files", *patterns], cwd=ROOT, text=True)
    return [ROOT / p for p in out.split()]


def headers_by_folder():
    folders = defaultdict(list)
    for h in git_files("*.h"):
        rel = h.relative_to(ROOT).as_posix()
        if rel.startswith(SCOPE) and h.name not in KEEP:
            folders[h.parent].append(h)
    return folders


def target_name(folder):
    # Games/<name>/Game -> Game.h; everything else -> <Folder>.h
    return folder / f"{folder.name}.h"


def name_map(folders):
    """Old header basename -> new header basename (headers are found by -I, by basename)."""
    mapping = {}
    for folder, headers in folders.items():
        new = target_name(folder).name
        for h in headers:
            if h.name in mapping and mapping[h.name] != new:
                sys.exit(f"ambiguous header name {h.name}")
            mapping[h.name] = new
    return mapping


def local_includes(path):
    return [m.group(2) for line in path.read_text().splitlines() if (m := INCLUDE.match(line))]


def topo(headers):
    """Order a folder's headers so each comes after the headers it includes."""
    names = {h.name: h for h in headers}
    deps = {h.name: [n for n in local_includes(h) if n in names and n != h.name] for h in headers}
    order, state = [], {}

    def visit(n, stack):
        if state.get(n) == 2:
            return
        if state.get(n) == 1:
            sys.exit(f"include cycle inside folder: {' -> '.join(stack + [n])}")
        state[n] = 1
        for d in sorted(deps[n]):
            visit(d, stack + [n])
        state[n] = 2
        order.append(names[n])

    for n in sorted(names):
        visit(n, [])
    return order


def folder_graph(folders, mapping):
    graph = defaultdict(set)
    for folder, headers in folders.items():
        me = target_name(folder).name
        for h in headers:
            for inc in local_includes(h):
                new = mapping.get(inc, inc)
                if new != me:
                    graph[me].add(new)
    return graph


def analyze():
    folders = headers_by_folder()
    mapping = name_map(folders)
    graph = folder_graph(folders, mapping)
    for folder, headers in sorted(folders.items()):
        me = target_name(folder).name
        sdk = sorted({m.group(1) for h in headers for line in h.read_text().splitlines() if (m := SDK.match(line))})
        print(f"{folder.relative_to(ROOT)} -> {me}: {', '.join(h.name for h in topo(headers))}")
        print(f"    needs: {', '.join(sorted(graph[me])) or '-'}")
        print(f"    sdk:   {', '.join(sdk) or '-'}")
    # cycles between merged headers
    def reach(a, b, seen=()):
        return any(n == b or (n not in seen and reach(n, b, seen + (n,))) for n in graph.get(a, ()))
    cycles = sorted({tuple(sorted((a, b))) for a in graph for b in graph[a] if reach(b, a)})
    print("cycles:", cycles or "none")


OBJC = re.compile(r'@interface|@protocol|@class|\bNS[A-Z]\w+|\bid<|#\s*import\s*<Foundation')


def is_objc(header):
    return bool(OBJC.search(header.read_text()))


def merge_folder(folder, headers, mapping):
    me = target_name(folder).name
    ordered = topo(headers)
    pre, objc_pre, bodies = [], [], []
    seen = set()
    # A folder with C sources and Objective-C headers keeps the merged header
    # usable from .c files: the Objective-C parts sit behind __OBJC__.
    mixed = any(folder.glob("*.c")) and len({is_objc(h) for h in ordered}) > 1
    for h in ordered:
        guard = mixed and is_objc(h)
        lines = h.read_text().splitlines()
        body = []
        depth = 0
        for line in lines:
            depth += bool(COND_OPEN.match(line)) - bool(COND_CLOSE.match(line))
            m = INCLUDE.match(line)
            if m:
                new = mapping.get(m.group(2), m.group(2))
                if new == me:
                    continue
                line = f'{m.group(1)}"{new}"{m.group(3)}'
            if ONCE.match(line):
                continue
            # Unconditional top-level imports gather at the top of the merged
            # header; conditional ones stay where they are.
            if (m or SDK.match(line)) and depth == 0:
                key = line.strip()
                if key not in seen:
                    seen.add(key)
                    (objc_pre if guard else pre).append(line)
                continue
            body.append(line)
        while body and not body[0].strip():
            body.pop(0)
        while body and not body[-1].strip():
            body.pop()
        bodies.append((h.stem, body, guard))
    out = ["#pragma once", ""]
    out += sdk_first(pre)
    objc_pre = [l for l in objc_pre if l.strip() not in {p.strip() for p in pre}]
    if objc_pre:
        out += ["#ifdef __OBJC__"] + sdk_first(objc_pre) + ["#endif"]
    for stem, body, guard in bodies:
        out += ["", f"// MARK: - {stem}", ""]
        out += ["#ifdef __OBJC__", ""] + body + ["", "#endif // __OBJC__"] if guard else body
    return "\n".join(out) + "\n"


def sdk_first(lines):
    sdk = [l for l in lines if SDK.match(l)]
    local = [l for l in lines if not SDK.match(l)]
    return sdk + local


def rewrite_includes(path, mapping, own=None):
    """Point includes at the merged headers, dropping duplicates and self-includes."""
    text = path.read_text()
    out, seen, changed = [], set(), False
    depth = 0
    for line in text.splitlines():
        depth += bool(COND_OPEN.match(line)) - bool(COND_CLOSE.match(line))
        m = INCLUDE.match(line)
        if m and m.group(2) in mapping:
            new = mapping[m.group(2)]
            if new == own:
                changed = True
                continue
            key = (m.group(1).strip(), new)
            # Only deduplicate unconditional top-level includes.
            if depth == 0 and key in seen:
                changed = True
                continue
            seen.add(key)
            nl = f'{m.group(1)}"{new}"{m.group(3)}'
            changed |= nl != line
            line = nl
        out.append(line)
    if changed:
        path.write_text("\n".join(out) + ("\n" if text.endswith("\n") else ""))
    return changed


def move():
    for old, new in MOVES.items():
        if (ROOT / old).exists():
            (ROOT / new).parent.mkdir(parents=True, exist_ok=True)
            subprocess.check_call(["git", "mv", old, new], cwd=ROOT)


def apply():
    originals = {h.relative_to(ROOT).as_posix() for h in git_files("*.h")}
    move()
    folders = headers_by_folder()
    mapping = name_map(folders)
    for folder, headers in folders.items():
        target = target_name(folder)
        merged = merge_folder(folder, headers, mapping)
        olds = [h for h in headers if h != target]
        if olds:
            subprocess.check_call(["git", "rm", "-qf", *[str(h) for h in olds]], cwd=ROOT)
        target.write_text(merged)
        subprocess.check_call(["git", "add", str(target)], cwd=ROOT)
        print(f"{target.relative_to(ROOT)} <- {', '.join(h.name for h in headers)}")
    sources = git_files("*.m", "*.mm", "*.c", "*.h")
    n = 0
    for s in sources:
        if s.exists() and rewrite_includes(s, mapping, own=None):
            n += 1
    print(f"rewrote includes in {n} files")
    # Old header paths -> merged header paths.
    paths = {}
    for rel in originals:
        cur = MOVES.get(rel, rel)
        if rel.startswith(SCOPE) and Path(cur).name not in KEEP:
            paths[rel] = (Path(cur).parent / mapping[Path(cur).name]).as_posix()
    paths.update({o: n for o, n in MOVES.items() if not o.endswith(".h")})
    # Mentions of old header names in build scripts and docs.
    for p in git_files("Makefile", "*.sh", "*.mk", "*.py", "*.md"):
        if p.name == Path(__file__).name or not p.exists():
            continue
        text = p.read_text()
        new = text
        for old, nn in sorted(paths.items(), key=lambda kv: -len(kv[0])):
            new = new.replace(old, nn)
        for old, nn in mapping.items():
            if old != nn:
                new = re.sub(rf'(?<![\w/]){re.escape(old)}\b', nn, new)
        if new != text:
            p.write_text(new)
            print(f"updated references in {p.relative_to(ROOT)}")


if __name__ == "__main__":
    {"analyze": analyze, "apply": apply, "move": move}[sys.argv[1] if len(sys.argv) > 1 else "analyze"]()
