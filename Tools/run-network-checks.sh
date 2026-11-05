#!/bin/zsh
set -eu
cd "${0:A:h}/.."
mkdir -p build
qa=$(mktemp -d "$PWD/build/network-checks.XXXXXX")
trap 'print "Network check artifacts: $qa"' EXIT
includes=(-ISources/Shared -ISources/Game ${(@)$(print -l Sources/Engine/*/(/) | sed 's/^/-I/')})
# Static game entry point; production server/client/netchan, no renderer instance.
clang -fobjc-arc -O1 -g -Wall -Wno-unused-function -Wno-deprecated-declarations \
    -mmacosx-version-min=13.0 $includes -include Sources/Engine/Prefix.h \
    -include Tools/NetworkClock.h -DCACurrentMediaTime=NetworkCheckTime \
    Tools/NetworkChecks.m Sources/Shared/*.m Sources/Shared/*.c \
    Sources/Game/*.m Sources/Engine/Common/*.m Sources/Engine/Server/Server.m \
    Sources/Engine/Client/Client.m Sources/Engine/Net/Net{Transport,Channel,Msg,Protocol}.m \
    Sources/Engine/Render/ModelInfo.m \
    -framework Cocoa -framework SceneKit -framework SpriteKit -framework QuartzCore \
    -o "$qa/NetworkChecks"
python3 Tools/network-fixtures.py "$qa"
"$qa/NetworkChecks" 2>&1 | tee "$qa/results.log"
python3 Tools/network-fixtures.py "$qa" --check-identities
