#!/bin/zsh
set -eu
cd "${0:A:h}/.."
mkdir -p build
qa="$(mktemp -d "$PWD/build/dialogue-checks.XXXXXX")"
app="$qa/DialogueChecks.app"
contents="$app/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources"
cp Resources/Info.plist "$contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set CFBundleExecutable DialogueChecks' \
    -c 'Set CFBundleIdentifier com.igor.spacefight.dialoguechecks' \
    -c 'Set CFBundleName Dialogue Checks' -c 'Add LSUIElement bool true' "$contents/Info.plist"
# Share read-only artwork rather than copying the campaign for every visual run.
ln -s "$PWD/Resources/Briefing" "$contents/Resources/Briefing"
ln -s "$PWD/Resources/Missions" "$contents/Resources/Missions"
ln -s "$PWD/Resources/Audio" "$contents/Resources/Audio"
ln -s "$PWD/Resources/Fonts" "$contents/Resources/Fonts"
ln -s "$PWD/Resources/Capitals" "$contents/Resources/Capitals"
for directory in Strings UI Story; do ln -s "$PWD/Resources/$directory" "$contents/Resources/$directory"; done
source Tools/engine-library.sh
clang $engine_cflags Tools/GUI/DialogueChecks.m $engine_libs -o "$contents/MacOS/DialogueChecks"
/usr/bin/codesign --force --sign - "$app"
/usr/bin/open -n -g -W --stdout "$qa/stdout.log" --stderr "$qa/stderr.log" "$app" --args "$qa"
cat "$qa/stderr.log" >&2
if ! /usr/bin/grep -q '^PASS: dialogue caret' "$qa/stdout.log"; then
    print -u2 "Dialogue checks failed. Previews and logs: $qa"
    exit 1
fi
cat "$qa/stdout.log"
print "Previews: $qa"
