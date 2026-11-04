#!/bin/zsh
# Downloads the CC0 "Shipyard" kitbash set by greyoxide (OpenGameArt) used
# by Art/build_capitals.py. https://opengameart.org/content/shipyard
set -e
cd "$(dirname "$0")"
curl -sL -o Shipyard.blend.zip https://opengameart.org/sites/default/files/Shipyard.blend.zip
unzip -o Shipyard.blend.zip Shipyard.blend
rm Shipyard.blend.zip
