#!/usr/bin/env python3
"""Check Arcline's portable bundle contract without an installed Apple SDK."""

import importlib.util
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("package_ios", Path(__file__).with_name("package-ios.py"))
package_ios = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package_ios)


class BundleContract(unittest.TestCase):
    ICON_KEYS = {"CFBundleIcons": {"test": True}, "CFBundleIconName": "AppIcon"}

    def test_both_sdks_keep_the_product_and_stay_unsigned(self):
        with tempfile.TemporaryDirectory() as work:
            folder = Path(work)
            executable = folder / "binary"
            executable.write_bytes(b"test executable")
            executable.chmod(0o755)
            for sdk, platform in package_ios.PLATFORMS.items():
                with self.subTest(sdk=sdk):
                    def fake_actool(argv, *, check):
                        self.assertTrue(check)
                        self.assertEqual(argv[:4], ["xcrun", "--sdk", sdk, "actool"])
                        self.assertEqual(argv[argv.index("--platform") + 1], sdk)
                        self.assertEqual(argv.count("--target-device"), 2)
                        partial = Path(argv[argv.index("--output-partial-info-plist") + 1])
                        partial.write_bytes(plistlib.dumps({**self.ICON_KEYS, "CFBundleIdentifier": "untrusted"}))
                        Path(argv[argv.index("--compile") + 1], "Assets.car").touch()

                    app = folder / sdk / "Racing.app"
                    app.mkdir(parents=True)
                    (app / "embedded.mobileprovision").touch()
                    with patch.object(subprocess, "check_output", return_value="18.5\n"), \
                         patch.object(subprocess, "run", side_effect=fake_actool):
                        package_ios.package(sdk, "16.0", executable, app)

                    info = plistlib.loads((app / "Info.plist").read_bytes())
                    self.assertEqual(info["CFBundleIdentifier"], "com.corepunch.arcline")
                    self.assertEqual(info["CFBundleDisplayName"], "Arcline")
                    self.assertEqual(info["CFBundleVersion"], "5")
                    self.assertEqual(info["CFBundleSupportedPlatforms"], [platform])
                    self.assertEqual(info["UIDeviceFamily"], [1, 2])
                    self.assertEqual(info["NSBonjourServices"], ["_arcline._udp"])
                    self.assertEqual(info["CFBundleIcons"], self.ICON_KEYS["CFBundleIcons"])
                    self.assertNotIn(b"$(", (app / "Info.plist").read_bytes())
                    self.assertTrue((app / "Racing").stat().st_mode & 0o111)
                    self.assertTrue((app / "Assets.car").is_file())
                    self.assertTrue((app / "Audio/music-race-apex.mp3").stat().st_size)
                    self.assertTrue((app / "PrivacyInfo.xcprivacy").is_file())
                    self.assertFalse((app / "embedded.mobileprovision").exists())
                    self.assertFalse((app / "_CodeSignature").exists())

    def test_broken_actool_preserves_previous_build(self):
        with tempfile.TemporaryDirectory() as work:
            folder = Path(work)
            executable = folder / "binary"
            executable.touch()
            app = folder / "Racing.app"
            app.mkdir()
            (app / "old-build").touch()
            with patch.object(subprocess, "check_output", return_value="18.5\n"), \
                 patch.object(subprocess, "run", side_effect=subprocess.CalledProcessError(1, "actool")):
                with self.assertRaises(subprocess.CalledProcessError):
                    package_ios.package("iphoneos", "16.0", executable, app)
            self.assertTrue((app / "old-build").exists())


if __name__ == "__main__":
    unittest.main()
