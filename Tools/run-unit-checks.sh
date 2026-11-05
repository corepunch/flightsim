#!/bin/zsh
# Builds and runs Tools/UnitChecks.m: headless checks of the shared core
# (flight model, wire format, console, campaign data). Needs no window, GPU
# or game module, so it runs on any Mac and in CI.
set -eu
cd "${0:A:h}/.."
mkdir -p build
qa=$(mktemp -d "$PWD/build/unit-checks.XXXXXX")
# A bare executable's main bundle is its directory: give it the resources the
# shared code reads.
mkdir -p "$qa/Games"
ln -s "$PWD/Resources/Strings" "$qa/Strings"
for game in Games/*(N/); do ln -s "$PWD/$game" "$qa/$game"; done
# A game that builds on another (game.json "base"), for the search-path checks.
mkdir -p "$qa/Games/ZCheckMod/Levels"
print '{ "title": "Check", "base": "SpaceFight" }' > "$qa/Games/ZCheckMod/game.json"
print '{ "name": "check", "title": "Check" }' > "$qa/Games/ZCheckMod/Levels/check.json"
# The app's Info.plist (FSDefaultGame), embedded as a bare executable's bundle info.
cp Resources/Info.plist "$qa/Info.plist"
clang -fobjc-arc -Wall -Wno-unused-function -mmacosx-version-min=13.0 \
    -ISources/Shared -ISources/Engine/Common -ISources/Engine/Net -ISources/Engine/Mission -ISources/Engine/Story \
    Tools/UnitChecks.m Sources/Shared/*.m Sources/Shared/*.c Sources/Engine/Common/*.m Sources/Engine/Mission/*.m Sources/Engine/Story/*.m \
    Sources/Engine/Net/NetMsg.m Sources/Engine/Net/NetProtocol.m \
    -framework Foundation -framework QuartzCore \
    -sectcreate __TEXT __info_plist "$qa/Info.plist" -o "$qa/UnitChecks"
if ! "$qa/UnitChecks"; then
    print -u2 "Unit checks failed. Binary: $qa"
    exit 1
fi

# The client draws only through the Refresh facade (Sources/Engine/Render/Refresh.h):
# its files must compile, and pull in no header, without SceneKit.
print '#import <Cocoa/Cocoa.h>\n#import <SpriteKit/SpriteKit.h>' > "$qa/NoSceneKit.h"
includes=(-ISources/Shared ${(@)$(print -l Sources/Engine/*/(/) | sed 's/^/-I/')})
for source in Sources/Engine/Client/*.m; do
    flags=(-fobjc-arc -Wall -mmacosx-version-min=13.0 $includes -include "$qa/NoSceneKit.h")
    if ! clang $flags -fsyntax-only "$source"; then
        print -u2 "FAIL: $source does not build without SceneKit"
        exit 1
    fi
    if clang $flags -M "$source" | grep -q 'SceneKit\.framework'; then
        print -u2 "FAIL: $source includes SceneKit through: $(clang $flags -H -fsyntax-only "$source" 2>&1 | grep -B1 -m1 SceneKit)"
        exit 1
    fi
done
print "PASS: the client builds without SceneKit"
rm -rf "$qa"
python3 -I Tools/validate_strings.py
