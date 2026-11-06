#!/usr/bin/env python3
"""Download Unity Labs' CC0 Explosion00 and losslessly re-encode it as PNG.

Requires Pillow. The archive is about 3 MB; only its 4 MB TGA is extracted.
Source and license: https://unity.com/blog/engine-platform/free-vfx-image-sequences-flipbooks
"""

from io import BytesIO
from pathlib import Path
from urllib.request import urlopen
from zipfile import ZipFile

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
URL = "https://unity3d.com/files/labs/downloads/vfx/assets01/Explosion00/Explosion00-flipbooks.zip"
CACHE = ROOT / "build/explosion-assets/Explosion00-flipbooks.zip"


def main():
    CACHE.parent.mkdir(parents=True, exist_ok=True)
    if not CACHE.exists():
        with urlopen(URL, timeout=60) as response:
            CACHE.write_bytes(response.read())
    with ZipFile(CACHE) as archive:
        image = Image.open(BytesIO(archive.read("Explosion00_5x5.tga")))
        image.load()
    assert image.size == (1024, 1024) and image.mode == "RGBA"
    destination = ROOT / "Resources/Particles/explosion.png"
    image.save(destination, optimize=True)
    print(destination)


if __name__ == "__main__":
    main()
