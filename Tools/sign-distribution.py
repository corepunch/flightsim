#!/usr/bin/env python3
"""Sign an app bundle for App Store distribution.

Picks the installed App Store provisioning profile for the bundle's identifier
and platform, whose certificate is an Apple Distribution identity in the
keychain, embeds it and signs the bundle (on the Mac its game modules first)
with the source entitlements plus the identifiers the profile grants. Set
PROFILE to a profile's path to choose one explicitly.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile

PROFILE_DIRECTORIES = ('Library/Developer/Xcode/UserData/Provisioning Profiles',
                       'Library/MobileDevice/Provisioning Profiles')


def distribution_identities():
    listing = subprocess.check_output(['security', 'find-identity', '-v', '-p', 'codesigning'], text=True)
    return dict(re.findall(r'^\s*\d+\) ([0-9A-F]{40}) "(Apple Distribution: [^"]+)"', listing, re.MULTILINE))


def app_store_profile(platform, bundle_id, identities):
    """The latest-expiring App Store profile for bundle_id with a usable identity."""
    chosen = os.environ.get('PROFILE')
    paths = [Path(chosen).expanduser()] if chosen else [
        path for directory in PROFILE_DIRECTORIES
        for path in (Path.home() / directory).glob('*.mobileprovision' if platform == 'ios' else '*.provisionprofile')]
    now = datetime.now(timezone.utc).replace(tzinfo=None)
    candidates = []
    for path in paths:
        decoded = subprocess.run(['security', 'cms', '-D', '-i', str(path)], capture_output=True)
        if decoded.returncode:
            continue
        profile = plistlib.loads(decoded.stdout)
        granted = profile.get('Entitlements', {})
        team = granted.get('com.apple.developer.team-identifier')
        app_id = granted.get('application-identifier') or granted.get('com.apple.application-identifier')
        # Development and ad hoc profiles name devices; App Store profiles name none.
        if (('iOS' if platform == 'ios' else 'OSX') not in profile.get('Platform', [])
                or 'ProvisionedDevices' in profile or profile.get('ProvisionsAllDevices')
                or granted.get('get-task-allow') or app_id != f'{team}.{bundle_id}'
                or profile.get('ExpirationDate', now) <= now):
            continue
        certificates = {hashlib.sha1(cert).hexdigest().upper() for cert in profile.get('DeveloperCertificates', [])}
        usable = sorted(set(identities) & certificates)
        if usable:
            candidates.append((profile['ExpirationDate'], path, profile, usable[0]))
    if not candidates:
        raise ValueError(f'No App Store provisioning profile for {bundle_id} ({platform}) matches an Apple '
                         'Distribution identity in the keychain. Download one from the developer account '
                         '(Xcode Settings > Accounts > Download Manual Profiles) or set PROFILE to its path.')
    _, path, profile, identity = max(candidates, key=lambda candidate: candidate[0])
    return path, profile, identity


def entitlements_for(platform, source, profile):
    """The source entitlements, with the App Store identifiers the profile grants."""
    entitlements = plistlib.loads(source.read_bytes()) if source else {}
    granted = profile['Entitlements']
    team = granted['com.apple.developer.team-identifier']
    entitlements['com.apple.developer.team-identifier'] = team
    if platform == 'ios':
        entitlements['application-identifier'] = granted['application-identifier']
        entitlements['get-task-allow'] = False
        if granted.get('beta-reports-active'):
            entitlements['beta-reports-active'] = True
    else:
        entitlements['com.apple.application-identifier'] = granted['com.apple.application-identifier']
    if 'com.apple.developer.icloud-container-identifiers' in entitlements:
        entitlements['com.apple.developer.icloud-container-environment'] = 'Production'
    missing = [key for key in entitlements if key not in granted and not key.startswith('com.apple.security.')]
    if missing:
        raise ValueError(f'The profile does not grant: {", ".join(sorted(missing))}')
    return entitlements


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('platform', choices=('ios', 'macos'))
    parser.add_argument('app', type=Path)
    parser.add_argument('entitlements', type=Path, nargs='?', help='the app\'s entitlements; none when omitted')
    args = parser.parse_args()
    app = args.app.resolve()
    contents = app if args.platform == 'ios' else app / 'Contents'
    bundle_id = plistlib.loads((contents / 'Info.plist').read_bytes())['CFBundleIdentifier']

    identities = distribution_identities()
    path, profile, fingerprint = app_store_profile(args.platform, bundle_id, identities)
    print(f'Signing {bundle_id} with "{identities[fingerprint]}" and "{profile["Name"]}"', flush=True)
    embedded = contents / ('embedded.mobileprovision' if args.platform == 'ios' else 'embedded.provisionprofile')
    embedded.write_bytes(path.read_bytes())

    sign = ['codesign', '--force', '--sign', fingerprint, '--timestamp=none', '--generate-entitlement-der']
    for module in sorted((contents / 'PlugIns').glob('*.dylib')):
        subprocess.run(sign + [str(module)], check=True)
    with tempfile.TemporaryDirectory() as directory:
        entitlements = Path(directory) / 'entitlements.plist'
        entitlements.write_bytes(plistlib.dumps(entitlements_for(args.platform, args.entitlements, profile)))
        subprocess.run(sign + ['--entitlements', str(entitlements), str(app)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError) as error:
        raise SystemExit(str(error))
    except subprocess.CalledProcessError as error:
        raise SystemExit(f'{error.cmd[0]} failed (exit {error.returncode}). See the tool output above.')
