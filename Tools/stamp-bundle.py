#!/usr/bin/env python3
"""Finish an app bundle's metadata the way Xcode does.

Writes the build environment keys (DTXcode, DTSDKName, BuildMachineOSBuild, …) that
App Store processing reads to tell which SDK and toolchain built the app, the
PkgInfo file, and on iOS devices the arm64 capability. Used by build.sh and
Games/Racing/Tools/package-ios.py for every bundle they assemble.
"""

import argparse
from pathlib import Path
import plistlib
import re
import subprocess


def output(*command):
    return subprocess.check_output(command, text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('app', type=Path)
    parser.add_argument('sdk', choices=('iphoneos', 'iphonesimulator', 'macosx'))
    args = parser.parse_args()
    contents = args.app / 'Contents' if args.sdk == 'macosx' else args.app
    plist = contents / 'Info.plist'
    info = plistlib.loads(plist.read_bytes())

    xcode = output('xcodebuild', '-version')
    version = [int(part) for part in re.search(r'^Xcode (\S+)', xcode, re.MULTILINE).group(1).split('.')] + [0, 0]
    sdk_build = output('xcrun', '--sdk', args.sdk, '--show-sdk-build-version')
    info.update(
        BuildMachineOSBuild=output('sw_vers', '-buildVersion'),
        DTCompiler='com.apple.compilers.llvm.clang.1_0',
        DTPlatformBuild=sdk_build,
        DTPlatformName=args.sdk,
        DTPlatformVersion=output('xcrun', '--sdk', args.sdk, '--show-sdk-platform-version'),
        DTSDKBuild=sdk_build,
        DTSDKName=args.sdk + output('xcrun', '--sdk', args.sdk, '--show-sdk-version'),
        DTXcode=f'{version[0]:02d}{version[1]}{version[2]}',
        DTXcodeBuild=re.search(r'^Build version (\S+)', xcode, re.MULTILINE).group(1),
    )
    if args.sdk == 'iphoneos':
        info['UIRequiredDeviceCapabilities'] = ['arm64']
    plist.write_bytes(plistlib.dumps(info))
    (contents / 'PkgInfo').write_text('APPL????')


if __name__ == '__main__':
    main()
