#!/bin/zsh
# Run from the repository root. Used by both build.sh and the Xcode resource phase.
set -e
destination=${1:?Expected a bundle resource directory}
working_dir=${2:?Expected a build directory}
baker=$working_dir/tools/BakeModels
cache=$working_dir/ModelCache

mkdir -p "$baker:h" "$destination"
for source in Tools/BakeModels.m Tools/ObjLoader.m Tools/ObjLoader.h; do
    if [[ ! -x $baker || $source -nt $baker ]]; then
        print 'Building the macOS model baker'
        # Xcode sets SDKROOT to the target iOS SDK. The baker runs on the Mac.
        mac_sdk=$(xcrun --sdk macosx --show-sdk-path)
        xcrun --sdk macosx clang -isysroot "$mac_sdk" -fobjc-arc -O2 -Wall -mmacosx-version-min=13.0 \
            -ITools Tools/BakeModels.m Tools/ObjLoader.m -framework Cocoa -framework SceneKit -o "$baker"
        break
    fi
done

# The engine's own resources, at the top level of the bundle.
for directory in Audio Fonts Shaders Particles Strings UI; do
    if [[ -d $destination/$directory ]]; then
        rsync -a --delete "Resources/$directory/" "$destination/$directory/"
    else
        cp -cR "Resources/$directory" "$destination/"
    fi
done
cp -p CREDITS.md "$destination/"

# Each game's folder, as Games/<name>/ (Sources/Shared/Shared.h): its data,
# with models baked to .scn. GAMES limits which games ship (the iOS app has one).
games=(${=GAMES:-${(@)$(print -l Games/*/(N:t))}})
# A game also needs the games it builds on (game.json "base").
for (( i = 1; i <= $#games; i++ )); do
    base=$(plutil -extract base raw -o - "Games/$games[i]/game.json" 2>/dev/null || true)
    if [[ -n $base && -d Games/$base ]] && (( ! ${games[(Ie)$base]} )); then games+=($base); fi
done
mkdir -p "$destination/Games"
for existing in "$destination"/Games/*(N/); do
    if (( ! ${games[(Ie)${existing:t}]} )); then rm -rf -- "$existing"; fi
done
baked=0
for game in $games; do
    source_dir=Games/$game
    output_dir=$destination/Games/$game
    mkdir -p "$output_dir"
    rsync -a --delete --exclude '/Game/' --exclude '*.obj' --exclude '*.mtl' --exclude '*.scn' "$source_dir/" "$output_dir/"
    for obj in $source_dir/Models/**/*.obj(N); do
        relative=${obj#$source_dir/}
        scene=$cache/$game/${relative:r}.scn
        mtl=${obj:r}.mtl
        if [[ ! -f $scene || $obj -nt $scene || $mtl -nt $scene || $baker -nt $scene ]]; then
            mode=(--scenekit)
            case "$relative" in
                Models/Cockpit.obj|Models/Capital/*) mode=() ;;
            esac
            "$baker" "${mode[@]}" "$scene:h" "$obj"
            baked=$((baked + 1))
        fi
        output=$output_dir/${relative:r}.scn
        if [[ ! -f $output || $scene -nt $output ]]; then
            mkdir -p "$output:h"
            cp -pc "$scene" "$output"
        fi
    done
done
# Bundles from before the Games/ layout.
for stale in Briefing Menu Missions Models Ships Capitals Styles Projectiles Story Textures; do
    if [[ -e $destination/$stale ]]; then rm -rf -- "$destination/$stale"; fi
done
print "Bundled resources for ${games[*]} ($baked models baked)"
