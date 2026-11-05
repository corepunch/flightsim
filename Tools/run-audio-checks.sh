#!/bin/zsh
set -eu
cd "${0:A:h}/.."
qa=$(mktemp -d "$PWD/build/audio-checks.XXXXXX")
contents="$qa/AudioChecks.app/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources"
cp Resources/Info.plist "$contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set CFBundleExecutable AudioChecks' \
    -c 'Set CFBundleIdentifier com.igor.spacefight.audiochecks' \
    -c 'Set CFBundleName Audio Checks' -c 'Add LSUIElement bool true' "$contents/Info.plist"
for directory in Audio Menu Strings UI; do ln -s "$PWD/Resources/$directory" "$contents/Resources/$directory"; done
clang -fobjc-arc -Wall -mmacosx-version-min=13.0 \
    -ISources/Shared -ISources/Engine/App -ISources/Engine/UI -ISources/Engine/Common \
    Tools/GUI/AudioChecks.m Sources/Engine/App/GameAudio.m Sources/Engine/UI/{MainMenu,UIMotion,UITheme,UILayout}.m Sources/Engine/Common/{Cvar,Localization}.m \
    -framework Cocoa -framework SpriteKit -framework AVFoundation -framework QuartzCore -framework ImageIO \
    -o "$contents/MacOS/AudioChecks"
codesign --force --sign - "$qa/AudioChecks.app"
/usr/bin/open -n -g -W --stdout "$qa/stdout.log" --stderr "$qa/stderr.log" "$qa/AudioChecks.app" --args "$qa"
cat "$qa/stdout.log"
if ! /usr/bin/grep -q '^PASS: audio assets' "$qa/stdout.log"; then
    cat "$qa/stderr.log" >&2
    print -u2 "Audio checks failed. Logs: $qa"
    exit 1
fi
print "Audio checks and menu previews: $qa"
