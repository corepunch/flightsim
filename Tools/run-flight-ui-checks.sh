#!/bin/zsh
set -eu
cd "${0:A:h}/.."
make -j 6 all
qa=$(mktemp -d "$PWD/build/flight-ui-checks.XXXXXX")
app="$qa/FlightUIChecks.app"
contents="$app/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources" "$contents/PlugIns"
cp Resources/Info.plist "$contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set CFBundleExecutable FlightUIChecks' -c 'Set CFBundleIdentifier com.igor.spacefight.flightuichecks' -c 'Set CFBundleName Flight UI Checks' -c 'Add LSUIElement bool true' "$contents/Info.plist"
source Tools/engine-library.sh
# Bake only the changed cockpit into the existing small model cache.
build/tools/BakeModels build/ModelCache/KestrelFrontier/Models Games/KestrelFrontier/Models/Cockpit.obj
link_check_resources "$contents/Resources"
for module in build/Native/*.dylib; do ln -s "$PWD/$module" "$contents/PlugIns/${module:t}"; done
clang $engine_cflags Tools/GUI/FlightUIChecks.m $engine_libs -o "$contents/MacOS/FlightUIChecks"
codesign --force --sign - "$app"
/usr/bin/open -n -g -W --stdout "$qa/stdout.log" --stderr "$qa/stderr.log" "$app" --args "$qa"
if ! /usr/bin/grep -q '^PASS: flight instruments' "$qa/stdout.log"; then
    cat "$qa/stderr.log" >&2
    print -u2 "Flight UI checks failed: $qa"
    exit 1
fi
print "Flight UI previews: $qa"
rm -rf "$app"
