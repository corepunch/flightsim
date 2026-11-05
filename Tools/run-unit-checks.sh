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
ln -s "$PWD/Resources/Missions" "$qa/Missions"
for directory in Ships Capitals Styles Projectiles; do [[ -d Resources/$directory ]] && ln -s "$PWD/Resources/$directory" "$qa/$directory"; done
clang -fobjc-arc -Wall -Wno-unused-function -mmacosx-version-min=13.0 \
    -ISources/Shared -ISources/Engine/Common -ISources/Engine/Net \
    Tools/UnitChecks.m Sources/Shared/*.m Sources/Shared/*.c Sources/Engine/Common/*.m \
    Sources/Engine/Net/NetMsg.m Sources/Engine/Net/NetProtocol.m \
    -framework Foundation -framework QuartzCore \
    -o "$qa/UnitChecks"
if ! "$qa/UnitChecks"; then
    print -u2 "Unit checks failed. Binary: $qa"
    exit 1
fi
rm -rf "$qa"
