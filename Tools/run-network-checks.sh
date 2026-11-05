#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p build
qa=$(mktemp -d "$PWD/build/network-checks.XXXXXX")
trap 'print "Network check artifacts: $qa"' EXIT
includes=(-ISources/Shared -IGames/KestrelFrontier/Game ${(@)$(print -l Sources/*(/) | sed 's/^/-I/')})
# Static game entry point; production server/client/netchan, no renderer instance.
clang -fobjc-arc -O1 -g -Wall -Wno-unused-function -Wno-deprecated-declarations \
    -mmacosx-version-min=13.0 $includes -include Sources/Prefix.h \
    -include Tools/NetworkClock.h -DCACurrentMediaTime=NetworkCheckTime \
    -x objective-c Tools/NetworkChecks.m Sources/Shared/*.m Sources/Shared/*.c \
    Games/KestrelFrontier/Game/*.m Sources/Mission/*.m Sources/Common/*.m Sources/Server/Server.m \
    Sources/Client/Client.m Sources/Net/Net{Transport,Channel,Msg,Protocol}.m \
    Sources/Net/UDPTransport.m Sources/Collision/ModelInfo.m \
    -framework Cocoa -framework SceneKit -framework SpriteKit -framework QuartzCore \
    -o "$qa/NetworkChecks"
python3 Tools/network-fixtures.py "$qa"
"$qa/NetworkChecks" 2>&1 | tee "$qa/results.log"
python3 Tools/network-fixtures.py "$qa" --check-identities
