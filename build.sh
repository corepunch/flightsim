#!/bin/zsh
# Builds build/SpaceFight.app. Usage: ./build.sh [run]
#
# Sources/Shared  protocol, flight model and data tables (engine and game)
# Sources/Game    the game module: all gameplay, behind GameAPI.h
# Sources/Engine  server, client, renderer, UI and the app itself
set -e
cd "$(dirname "$0")"

APP=build/SpaceFight.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

CFLAGS=(-fobjc-arc -O2 -g -Wall -Wno-unused-function -mmacosx-version-min=13.0)
INCLUDES=(-ISources/Shared -ISources/Game)
for d in Sources/Engine/*/; do INCLUDES+=(-I"$d"); done

clang "${CFLAGS[@]}" "${INCLUDES[@]}" \
    Sources/Shared/*.(m|c) Sources/Game/*.m Sources/Engine/*/*.m \
    -framework Cocoa -framework SceneKit -framework SpriteKit -framework Metal \
    -framework QuartzCore -framework IOKit -framework Carbon -framework ImageIO -framework AVFoundation -framework CoreMedia -framework CoreVideo \
    -o "$APP/Contents/MacOS/SpaceFight"

cp Resources/Info.plist "$APP/Contents/"
cp -R Resources/Models Resources/Shaders Resources/Particles Resources/Textures Resources/Missions "$APP/Contents/Resources/"
cp CREDITS.md "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
if [[ "$1" == "run" ]]; then
    "$APP/Contents/MacOS/SpaceFight"
fi
