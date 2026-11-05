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

# Keep the directory structure used by NSBundle resource lookups.
for directory in Audio Briefing Fonts Menu Shaders Ships Capitals Styles Projectiles Particles Textures Missions Strings UI; do
    if [[ -d $destination/$directory ]]; then
        rsync -a --delete "Resources/$directory/" "$destination/$directory/"
    else
        cp -cR "Resources/$directory" "$destination/"
    fi
done
cp -p CREDITS.md "$destination/"

mkdir -p "$destination/Models"
rsync -a --delete --exclude '*.obj' --exclude '*.mtl' --exclude '*.scn' Resources/Models/ "$destination/Models/"
for scene in "$destination"/Models/**/*.scn(N); do
    relative=${scene#"$destination/"}
    [[ -f Resources/${relative:r}.obj ]] || rm "$scene"
done

baked=0
for obj in Resources/Models/**/*.obj; do
    relative=${obj#Resources/}
    scene=$cache/${relative:r}.scn
    mtl=${obj:r}.mtl
    if [[ ! -f $scene || $obj -nt $scene || $mtl -nt $scene || $baker -nt $scene ]]; then
        mode=(--scenekit)
        case "$obj" in
            Resources/Models/Cockpit.obj|Resources/Models/Capital/*) mode=() ;;
        esac
        "$baker" "${mode[@]}" "$scene:h" "$obj"
        baked=$((baked + 1))
    fi
    output=$destination/${relative:r}.scn
    if [[ ! -f $output || $scene -nt $output ]]; then
        mkdir -p "$output:h"
        cp -pc "$scene" "$output"
    fi
done
print "Bundled resources ($baked models baked)"
