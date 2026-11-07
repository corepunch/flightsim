#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p build
if [[ ! -f build/ModelCache/KestrelFrontier/Models/Capital/Destroyer.scn ]]; then ./build.sh; fi
qa=$(mktemp -d "$PWD/build/network-checks.XXXXXX")
trap 'print "Network check artifacts: $qa"' EXIT
includes=(-ISources/Shared -IGames/KestrelFrontier/Game ${(@)$(print -l Sources/*(/) | sed 's/^/-I/')})
# Static game entry point; production server/client/netchan, no renderer instance.
clang -fobjc-arc -O1 -g -Wall -Wno-unused-function -Wno-deprecated-declarations \
    -mmacosx-version-min=13.0 $includes -include Sources/Prefix.h \
    -include Tools/NetworkClock.h -DCACurrentMediaTime=NetworkCheckTime \
    -x objective-c Tools/NetworkChecks.m Sources/Shared/*.m Sources/Shared/*.c \
    Games/KestrelFrontier/Game/*.m Sources/Mission/*.m Sources/Story/*.m Sources/Common/*.m Sources/Server/Server.m \
    Sources/Client/Client.m Sources/Net/Net{Transport,Channel,Msg,Protocol}.m \
    Sources/Net/UDPTransport.m Sources/Net/LANBrowser.m Sources/Collision/ModelInfo.m \
    -framework Cocoa -framework SceneKit -framework SpriteKit -framework QuartzCore \
    -o "$qa/NetworkChecks"
python3 Tools/network-fixtures.py "$qa"
network_status=0
# Repeat the socket teardown/reconnect path on the native runner. Keep a
# separate log so an intermittent failure retains its iteration number.
for iteration in {1..25}; do
    print "UDP disconnect iteration $iteration/25" | tee -a "$qa/udp-disconnect.log"
    "$qa/NetworkChecks" --udp-disconnect 2>&1 | tee -a "$qa/udp-disconnect.log" || { network_status=$?; break; }
done
"$qa/NetworkChecks" 2>&1 | tee "$qa/results.log" || network_status=$?
python3 Tools/network-fixtures.py "$qa" --check-identities
# A separate process and resource tree prevent fixture definitions leaking into
# campaign checks. Assets are linked rather than duplicated.
campaign="$qa/campaign"
mkdir -p "$campaign/Games"
cp "$qa/NetworkChecks" "$campaign/NetworkChecks"
ln -s "$PWD/Resources/Strings" "$campaign/Strings"
for game in Games/*(N/); do
    mkdir -p "$campaign/$game"
    for entry in $game/*(N); do
        case ${entry:t} in Game|Models) continue ;; esac
        ln -s "$PWD/$entry" "$campaign/$entry"
    done
    ln -s "$PWD/build/ModelCache/${game:t}/Models" "$campaign/$game/Models"
done
campaign_status=0
for game in KestrelFrontier EmberReach; do
    "$campaign/NetworkChecks" --campaign "$game" 2>&1 | tee "$qa/campaign-$game.log" || campaign_status=$?
done
exit $(( network_status != 0 || campaign_status != 0 ))
