#!/bin/zsh
# Builds and runs Tools/UnitChecks.m: headless checks of the shared core
# (flight model, wire format, console, campaign data). Needs no window, GPU
# or game module, so it runs on any Mac and in CI.
set -eu
cd "${0:A:h}/.."
mkdir -p build
if [[ ${1:-} != --unit-worker ]]; then
    exec python3 - "$PWD" <<'BUDGET'
import os, signal, subprocess, sys, tempfile, time
from pathlib import Path
root = Path(sys.argv[1])
started = time.monotonic()
with tempfile.TemporaryDirectory(prefix="unit-checks.", dir=root / "build") as qa:
    process = subprocess.Popen(["/bin/zsh", str(root / "Tools/run-unit-checks.sh"),
                                "--unit-worker", qa], start_new_session=True)
    try:
        result = process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        print("FAIL: unit checks exceeded the 10-second budget", file=sys.stderr)
        sys.exit(124)
print(f"Unit checks: {time.monotonic() - started:.2f}s / 10s budget")
sys.exit(result)
BUDGET
fi
qa=$2
# A bare executable's main bundle is its directory: give it the resources the
# shared code reads.
mkdir -p "$qa/Games"
ln -s "$PWD/Resources/Strings" "$qa/Strings"
for game in Games/*(N/); do ln -s "$PWD/$game" "$qa/$game"; done
# A game that builds on another (game.json "base"), for the search-path checks.
mkdir -p "$qa/Games/ZCheckMod/Levels"
print '{ "title": "Check", "base": "KestrelFrontier" }' > "$qa/Games/ZCheckMod/game.json"
print '{ "name": "check", "title": "Check" }' > "$qa/Games/ZCheckMod/Levels/check.json"
mkdir -p "$qa/Games/ZCheckMod/Data/Ships"
print '{ "displayName": "Plain", "mesh": "Spitfire", "guns": [[0, 0, -3]], "nozzles": [[0, 0, 3, 0.5]] }' \
    > "$qa/Games/ZCheckMod/Data/Ships/zcheck-plain.json"
print '{ "displayName": "Ion boat", "mesh": "Spitfire", "guns": [[0, 0, -3]], "nozzles": [[0, 0, 3, 0.5]], "systems": 0.4,
  "gun": { "ion": true, "damage": 0.2 }, "aiGun": { "damage": 0.3 } }' > "$qa/Games/ZCheckMod/Data/Ships/zcheck-ionboat.json"
print '{ "displayName": "Gunship", "mesh": "Spitfire", "guns": [[0, 0, -3]], "nozzles": [[0, 0, 3, 0.5]],
  "hull": 2.5, "shield": 0, "shieldRegen": 0.2,
  "secondary": { "name": "MISSILE", "short": "MSL", "projectile": "torpedo", "rounds": 6, "range": 1800,
                 "maxSpeed": 600, "damage": 0.8, "capitalDamage": 2 } }' > "$qa/Games/ZCheckMod/Data/Ships/zcheck-gunship.json"
# The app's Info.plist (FSDefaultGame), embedded as a bare executable's bundle info.
cp Resources/Info.plist "$qa/Info.plist"
# Compile the same headless sources concurrently so compiler startup does not
# consume the ten-second budget on a busy development machine.
flags=(-fobjc-arc -Wall -Wno-unused-function -mmacosx-version-min=13.0
       -ISources/Shared -ISources/Common -ISources/Net -ISources/Mission -ISources/Story)
# Parse Foundation once rather than in every Objective-C compiler process.
# This keeps cold CI builds within the same compile-and-test budget.
print '#import <Foundation/Foundation.h>' > "$qa/Foundation.h"
clang $flags -x objective-c-header "$qa/Foundation.h" -o "$qa/Foundation.pch"
sources=(Tools/UnitChecks.m Sources/Shared/*.m Sources/Shared/*.c Sources/Common/*.m Sources/Mission/*.m Sources/Story/*.m
         Sources/Net/NetMsg.m Sources/Net/NetProtocol.m)
objects=() pids=()
unsetopt BGNICE
for source in $sources; do
    object=$qa/${source//\//_}.o
    objects+=("$object")
    prefix=()
    if [[ $source == *.m ]]; then prefix=(-include-pch "$qa/Foundation.pch"); fi
    clang $flags $prefix -c "$source" -o "$object" &
    pids+=($!)
    if (( $#pids == 8 )); then
        for pid in $pids; do wait "$pid"; done
        pids=()
    fi
done
for pid in $pids; do wait "$pid"; done
clang $objects -framework Foundation -framework QuartzCore -framework CoreGraphics \
    -sectcreate __TEXT __info_plist "$qa/Info.plist" -o "$qa/UnitChecks"
if ! "$qa/UnitChecks"; then
    print -u2 "Unit checks failed. Binary: $qa"
    exit 1
fi

python3 -I Tools/validate_strings.py
python3 -I Tools/validate_ships.py
python3 -I Tools/test_story_continuity.py
