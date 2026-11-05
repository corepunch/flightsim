#!/bin/zsh
set -eu
cd "${0:A:h}/.."

# A fresh bundle and log directory keeps earlier runs from masking a failure.
mkdir -p build
qa="$(mktemp -d "$PWD/build/gui-checks.XXXXXX")"
app="$qa/PortraitChecks.app"
contents="$app/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources"
cp Resources/Info.plist "$contents/Info.plist"
/usr/libexec/PlistBuddy \
    -c 'Set CFBundleExecutable PortraitChecks' \
    -c 'Set CFBundleIdentifier com.igor.spacefight.portraitchecks' \
    -c 'Set CFBundleName Portrait Checks' \
    -c 'Add LSUIElement bool true' "$contents/Info.plist"
cp -R Resources/Briefing Resources/Missions "$contents/Resources/"
ln -s "$PWD/Resources/Audio" "$contents/Resources/Audio"

ui=Sources/Engine/UI
clang -fobjc-arc -Wall -mmacosx-version-min=13.0 \
    -ISources/Shared -ISources/Engine/App -I"$ui" \
    Tools/GUI/PortraitChecks.m "$ui"/{Briefing,Progress,UIMotion}.m Sources/Shared/Assets.m Sources/Engine/App/GameAudio.m \
    -framework Cocoa -framework SpriteKit -framework ImageIO -framework CoreGraphics -framework AVFoundation -framework QuartzCore \
    -o "$contents/MacOS/PortraitChecks"
/usr/bin/codesign --force --sign - "$app"

# Launch the bundle in the desktop session. open -W does not report the app's exit status.
if ! /usr/bin/open -n -g -W --stdout "$qa/stdout.log" --stderr "$qa/stderr.log" "$app"; then
    print -u2 "Could not open $app. Run from your macOS desktop session."
    exit 1
fi
if [[ -s "$qa/stderr.log" ]]; then cat "$qa/stderr.log" >&2; fi
if ! /usr/bin/grep -E '^PASS: portrait transitions across [0-9]+ missions at desktop, narrow and iPhone sizes\.$' "$qa/stdout.log"; then
    print -u2 "Portrait checks did not finish successfully. Bundle and logs: $qa"
    exit 1
fi
rm -rf "$qa"
