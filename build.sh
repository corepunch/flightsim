#!/bin/zsh
# Builds build/SpaceFight.app. Usage: ./build.sh [run]
#
# Sources/Shared  protocol, flight model and data tables (engine and game)
# Sources/Game    the game module: all gameplay, behind GameAPI.h
# Sources/Engine  server, client, renderer, UI and the app itself
set -e
cd "$(dirname "$0")"

log() {
    printf '[build +%ss] %s\n' "$SECONDS" "$*"
}

APP=build/SpaceFight.app
mkdir -p build
zmodload zsh/system
: >> build/.lock
if ! zsystem flock -t 0 -f build_lock build/.lock 2>/dev/null; then
    log "Waiting for the current build to finish"
    zsystem flock -f build_lock build/.lock
fi

jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null) || jobs=1
log "Checking native targets ($jobs parallel jobs)"
make -j "$jobs" all

# Models: the OBJs in Resources/Models are the sources (what Blender and
# Art/*.py export); the app ships them baked to SceneKit .scn by
# Tools/BakeModels. Bakes are cached in build/ModelCache and redone when the
# OBJ is newer, or all of them when the baker changes.
BAKER=build/tools/BakeModels
CACHE=build/ModelCache
mkdir -p build/tools
for src in Tools/*.(m|h); do
    if [[ ! -x $BAKER || $src -nt $BAKER ]]; then
        log "Rebuilding the model baker and invalidating the model cache"
        clang -fobjc-arc -O2 -Wall -mmacosx-version-min=13.0 -ITools Tools/*.m \
            -framework Cocoa -framework SceneKit -o $BAKER
        rm -rf "$CACHE"
        break
    fi
done
# Capital ships and the cockpit are split into named parts by ObjLoader; the
# fighters go through SceneKit's own importer (see BakeModels.m).
log "Checking the model cache"
PARTS=(Resources/Models/Cockpit.obj Resources/Models/Capital/*.obj)
baked=0
cached=0
for obj in Resources/Models/**/*.obj; do
    rel=${obj#Resources/}
    scn=$CACHE/${rel:r}.scn
    if [[ -f $scn && ! $obj -nt $scn ]]; then
        cached=$((cached + 1))
        continue
    fi
    mode=(--scenekit)
    (( ${PARTS[(Ie)$obj]} )) && mode=()
    log "Baking $rel"
    $BAKER $mode "${scn:h}" $obj
    baked=$((baked + 1))
done
log "Assembling $APP ($cached models cached, $baked baked)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/PlugIns"
cp build/Native/SpaceFight "$APP/Contents/MacOS/"
cp build/Native/game.dylib "$APP/Contents/PlugIns/"
cp Resources/Info.plist "$APP/Contents/"
cp -cR Resources/Briefing Resources/Menu Resources/Shaders Resources/Particles Resources/Textures Resources/Missions "$APP/Contents/Resources/"
cp CREDITS.md "$APP/Contents/Resources/"
rsync -a --exclude '*.obj' --exclude '*.mtl' Resources/Models "$APP/Contents/Resources/"
# Clone cached scenes on APFS. cp falls back to copying on other filesystems.
for dir in "$CACHE/Models" "$CACHE/Models"/**/*(/N); do
    scenes=("$dir"/*.scn(N))
    (( ${#scenes} )) || continue
    dest=$APP/Contents/Resources/${dir#$CACHE/}
    mkdir -p "$dest"
    cp -pc "${scenes[@]}" "$dest/"
done
log "Signing the app bundle"
codesign --force --sign - "$APP" || log "Code signing failed, continuing"

log "Built $APP"
zsystem flock -u "$build_lock"
if [[ "$1" == "run" ]]; then
    log "Launching SpaceFight through macOS Launch Services"
    if ! /usr/bin/open -n -W "$PWD/$APP"; then
        print -u2 "Could not open SpaceFight.app. Run from your macOS desktop session or open the app in Finder."
        exit 1
    fi
fi
