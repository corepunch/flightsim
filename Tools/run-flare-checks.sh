#!/bin/zsh
set -eu
cd "${0:A:h}/.."

qa="$(mktemp -d "$PWD/build/flare-checks.XXXXXX")"
app="$qa/FlareChecks.app"
contents="$app/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources/Shaders"
cp Resources/Info.plist "$contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set CFBundleExecutable FlareChecks' \
    -c 'Set CFBundleIdentifier com.igor.spacefight.flarechecks' \
    -c 'Set CFBundleName Flare Checks' -c 'Add LSUIElement bool true' "$contents/Info.plist"
cp Resources/Shaders/LensFlare.fsh "$contents/Resources/Shaders/"
clang -fobjc-arc -Wall -mmacosx-version-min=13.0 -ISources/Engine/Render \
    Tools/GUI/LensFlareChecks.m Sources/Engine/Render/LensFlare.m \
    -framework Cocoa -framework SpriteKit -framework SceneKit -framework Metal -o "$contents/MacOS/FlareChecks"
codesign --force --sign - "$app"
if ! /usr/bin/open -n -g -W --stdout "$qa/stdout.log" --stderr "$qa/stderr.log" "$app" --args "$qa"; then
    print -u2 "Could not launch flare checks. Bundle and logs: $qa"
    exit 1
fi
if ! /usr/bin/grep -q '^PASS: rendered flare' "$qa/stdout.log"; then
    cat "$qa/stderr.log" >&2
    print -u2 "Flare checks failed. Bundle and logs: $qa"
    exit 1
fi
cat "$qa/stdout.log"
print "Rendered previews and logs: $qa"
# Keep the small previews and logs; the disposable bundle is no longer needed.
rm -rf "$app"
