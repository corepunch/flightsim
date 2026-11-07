#!/bin/zsh
set -eu
cd "${0:A:h}/.."
# No asset copies, dependencies or simulator installation. PNGs are 1x scene fixtures.
qa=${1:-"$PWD/build/ui-reference"}
mkdir -p "$qa"
qa=${qa:A}
extra=()
if [[ ${2:-} == --ratings-only || ${2:-} == --network-only ]]; then extra=("$2")
elif [[ -n ${2:-} ]]; then print -u2 "Unknown reference option: $2"; exit 1
fi
contents="$qa/UIReference.app/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources"
cp Resources/Info.plist "$contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set CFBundleExecutable UIReference' -c 'Set CFBundleIdentifier com.igor.spacefight.uireference' -c 'Set CFBundleName UI Reference' -c 'Add LSUIElement bool true' "$contents/Info.plist"
source Tools/engine-library.sh
# Replace only this runner's previous symlinks when refreshing the same catalogue.
rm -rf "$contents/Resources"
mkdir -p "$contents/Resources"
link_check_resources "$contents/Resources"
clang $engine_cflags Tools/GUI/UIReference.m $engine_libs -o "$contents/MacOS/UIReference"
codesign --force --sign - "$qa/UIReference.app"
if [[ ${#extra} == 0 ]]; then rm -f "$qa/manifest.json"; fi
: > "$qa/stdout.log"
: > "$qa/stderr.log"
/usr/bin/open -n -g -W --stdout "$qa/stdout.log" --stderr "$qa/stderr.log" "$qa/UIReference.app" --args "$qa" "${extra[@]}"
if ! /usr/bin/grep -q '^PASS: UI reference rendered' "$qa/stdout.log" || [[ ! -f "$qa/manifest.json" ]]; then
    cat "$qa/stderr.log" >&2
    print -u2 "UI reference failed: $qa"
    exit 1
fi
python3 Tools/GUI/ui_reference.py "$qa"
cat "$qa/stdout.log"
print "Reference sheet: $qa/index.html"
