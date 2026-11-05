#!/bin/zsh
set -eu
cd "${0:A:h}/.."
./build.sh
qa=$(mktemp -d "$PWD/build/mouse-checks.XXXXXX")
app="$qa/MouseChecks.app"
contents="$app/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources/Shaders"
cp Resources/Info.plist "$contents/Info.plist"
cp Resources/Shaders/*.fsh "$contents/Resources/Shaders/"
for directory in Strings UI; do ln -s "$PWD/Resources/$directory" "$contents/Resources/$directory"; done
/usr/libexec/PlistBuddy -c 'Set CFBundleExecutable MouseChecks' \
    -c 'Set CFBundleIdentifier com.igor.spacefight.mousechecks' \
    -c 'Set CFBundleName Mouse Checks' -c 'Add LSUIElement bool true' "$contents/Info.plist"
objects=(build/Native/engine/**/*.o)
objects=(${objects:#*/main.m.o})
clang -fobjc-arc -Wall -mmacosx-version-min=13.0 \
    -ISources/Shared -ISources/Engine/App -ISources/Engine/Render -ISources/Engine/Common -ISources/Engine/UI \
    Tools/GUI/MouseFlightChecks.m "${objects[@]}" \
    -framework Cocoa -framework SceneKit -framework SpriteKit -framework Metal \
    -framework CoreGraphics -framework QuartzCore -framework IOKit -framework Carbon \
    -framework ImageIO -framework AVFoundation -framework CoreMedia -framework CoreVideo \
    -o "$contents/MacOS/MouseChecks"
codesign --force --sign - "$app"
if ! /usr/bin/open -n -g -W --stdout "$qa/stdout.log" --stderr "$qa/stderr.log" "$app"; then
    print -u2 "Could not launch mouse checks in the desktop session. Bundle and logs: $qa"
    exit 1
fi
if ! /usr/bin/grep '^PASS: mouse flight' "$qa/stdout.log"; then
    cat "$qa/stderr.log" >&2
    print -u2 "Mouse checks failed. Bundle and logs: $qa"
    exit 1
fi
rm -rf "$qa"
