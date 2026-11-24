#!/usr/bin/env python3
"""Assemble an unsigned Arcline app from a linked Swift executable."""

import argparse
import plistlib
from pathlib import Path
import shutil
import subprocess
import tempfile


IDENTIFIER = "com.corepunch.arcline"
PLATFORMS = {"iphoneos": "iPhoneOS", "iphonesimulator": "iPhoneSimulator"}
RESOURCES = Path(__file__).resolve().parents[1] / "Resources"
STAMP = Path(__file__).resolve().parents[3] / "Tools" / "stamp-bundle.py"


def package(sdk: str, minimum: str, executable: Path, destination: Path) -> None:
    if not executable.is_file():
        raise ValueError(f"Missing Racing executable: {executable}")
    version = subprocess.check_output(
        ["xcrun", "--sdk", sdk, "--show-sdk-version"], text=True
    ).strip()
    info = plistlib.loads((RESOURCES / "Info.plist").read_bytes())
    info.update(
        CFBundleExecutable="Racing",
        CFBundleIdentifier=IDENTIFIER,
        CFBundleName="Racing",
        CFBundleSupportedPlatforms=[PLATFORMS[sdk]],
        DTPlatformName=sdk,
        DTSDKName=sdk + version,
        MinimumOSVersion=minimum,
        UIDeviceFamily=[1, 2],
    )
    scene = info["UIApplicationSceneManifest"]["UISceneConfigurations"]
    scene["UIWindowSceneSessionRoleApplication"][0]["UISceneDelegateClassName"] = "Racing.AppSceneDelegate"

    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".racing-app-", dir=destination.parent) as work:
        stage = Path(work) / destination.name
        stage.mkdir()
        shutil.copy2(executable, stage / "Racing")
        shutil.copytree(RESOURCES / "Audio", stage / "Audio")
        shutil.copy2(RESOURCES / "PrivacyInfo.xcprivacy", stage / "PrivacyInfo.xcprivacy")
        icons = Path(work) / "AppIcon-Info.plist"
        subprocess.run([
            "xcrun", "--sdk", sdk, "actool", "--compile", str(stage),
            "--platform", sdk, "--minimum-deployment-target", minimum,
            "--target-device", "iphone", "--target-device", "ipad",
            "--app-icon", "AppIcon", "--output-partial-info-plist", str(icons),
            str(RESOURCES / "Assets.xcassets"),
        ], check=True)
        # actool owns the generated icon declarations; source owns app identity.
        for key, value in plistlib.loads(icons.read_bytes()).items():
            if key.startswith("CFBundleIcons") or key == "CFBundleIconName":
                info[key] = value
        if "CFBundleIcons" not in info:
            raise ValueError("actool did not produce iPhone icon declarations")
        (stage / "Info.plist").write_bytes(plistlib.dumps(info))
        subprocess.run(["python3", str(STAMP), str(stage), sdk], check=True)
        if destination.exists():
            shutil.rmtree(destination)
        stage.rename(destination)
    print(f"Built unsigned app: {destination}")


def main() -> None:
    args = argparse.ArgumentParser(description=__doc__)
    args.add_argument("sdk", choices=PLATFORMS)
    args.add_argument("minimum")
    args.add_argument("executable", type=Path)
    args.add_argument("app", type=Path)
    options = args.parse_args()
    package(options.sdk, options.minimum, options.executable, options.app)


if __name__ == "__main__":
    main()
