#!/bin/zsh
set -eu
cd "${0:A:h}/.."
./build.sh
qa=$(mktemp -d "$PWD/build/mouse-checks.XXXXXX")
app="$qa/MouseChecks.app"
contents="$app/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources"
cp Resources/Info.plist "$contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set CFBundleExecutable MouseChecks' \
    -c 'Set CFBundleIdentifier com.igor.spacefight.mousechecks' \
    -c 'Set CFBundleName Mouse Checks' -c 'Add LSUIElement bool true' "$contents/Info.plist"
source Tools/engine-library.sh
link_check_resources "$contents/Resources"
clang $engine_cflags Tools/GUI/MouseFlightChecks.m $engine_libs -o "$contents/MacOS/MouseChecks"
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
