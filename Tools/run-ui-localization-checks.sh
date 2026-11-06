#!/bin/zsh
set -eu
cd "${0:A:h}/.."
qa="$PWD/build/ui-localization"
contents="$qa/LocalizationChecks.app/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources"
cp Resources/Info.plist "$contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set CFBundleExecutable LocalizationChecks' -c 'Set CFBundleIdentifier com.igor.spacefight.localizationchecks' -c 'Set CFBundleName Localization Checks' -c 'Add LSUIElement bool true' "$contents/Info.plist"
source Tools/engine-library.sh
rm -rf "$contents/Resources"
mkdir -p "$contents/Resources"
link_check_resources "$contents/Resources"
clang $engine_cflags Tools/GUI/LocalizationChecks.m $engine_libs -framework CoreText -o "$contents/MacOS/LocalizationChecks"
codesign --force --sign - "$qa/LocalizationChecks.app"
glyphs_only=0
verify_only=0
flight_only=0
if [[ ${1:-} == --glyphs-only ]]; then glyphs_only=1; shift;
elif [[ ${1:-} == --verify-only ]]; then verify_only=1; shift;
elif [[ ${1:-} == --flight-only ]]; then flight_only=1; shift; fi
locales=("$@")
if [[ $#locales == 0 ]]; then locales=(${(@)$(python3 -I -c 'from pathlib import Path; print("\n".join(p.stem for p in sorted(Path("Resources/Strings").glob("*.json"))))')}); fi
games=(KestrelFrontier)
if (( glyphs_only )); then games+=(EmberReach); fi
for locale in $locales; do
  for game in $games; do
    log=$locale
    extra=()
    if (( glyphs_only )); then log=$locale-$game-glyphs; extra=(--glyphs-only "$game"); fi
    if (( verify_only )); then log=$locale-layout; extra=(--verify-only); fi
    if (( flight_only )); then log=$locale-flight; extra=(--flight-only); fi
    : > "$qa/$log.stdout.log"
    : > "$qa/$log.stderr.log"
    # Very short checks can exit before LaunchServices attaches its wait event.
    # The marker is written only after the native checks finish successfully.
    launch_status=0
    /usr/bin/open -n -g -W --stdout "$qa/$log.stdout.log" --stderr "$qa/$log.stderr.log" "$qa/LocalizationChecks.app" --args "$qa" "$locale" $extra -AppleLanguages "($locale)" || launch_status=$?
    if ! /usr/bin/grep -q "^PASS: localization $locale " "$qa/$log.stdout.log"; then
        cat "$qa/$log.stderr.log" >&2
        print -u2 "Localization check failed: $locale (launch status $launch_status; $qa)"
        exit 1
    fi
    cat "$qa/$log.stdout.log"
  done
done
if (( glyphs_only )); then print 'All engine and game catalogs passed native glyph checks.'; exit 0; fi
if (( verify_only )); then print 'All localized layouts passed.'; exit 0; fi
python3 - "$qa" <<'PY'
import json,sys
from pathlib import Path
root=Path(sys.argv[1]); entries=[]
for catalog in sorted(root.glob('*.json')):
    if catalog.name!='manifest.json': entries.extend(json.loads(catalog.read_text()))
(root/'manifest.json').write_text(json.dumps(entries,ensure_ascii=False,indent=2)+'\n')
PY
python3 Tools/GUI/ui_reference.py "$qa"
print "Localized reference: $qa/index.html"
