#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
app=build/KestrelFrontier.app/Contents/MacOS/KestrelFrontier
output=${1:-fastlane/screenshots/en-US}
if [ ! -x "$app" ]; then
    echo 'Build the macOS app with ./build.sh first.' >&2
    exit 1
fi
mkdir -p "$output"
"$app" --render-scene Tools/Capture/torpedo-run.json "$output/iPhone-05-torpedo-ribbon.jpg" 2622 1206
"$app" --render-scene Tools/Capture/corvette-strike.json "$output/iPhone-06-corvette-strike.jpg" 2622 1206
"$app" --render-scene Tools/Capture/cockpit-formation.json "$output/iPhone-08-cockpit-formation.jpg" 2622 1206
"$app" --render-scene Tools/Capture/torpedo-run.json "$output/iPad-05-torpedo-ribbon.jpg" 2752 2064
"$app" --render-scene Tools/Capture/corvette-strike.json "$output/iPad-06-corvette-strike.jpg" 2752 2064
"$app" --render-scene Tools/Capture/cockpit-formation.json "$output/iPad-08-cockpit-formation.jpg" 2752 2064
