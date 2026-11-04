#!/usr/bin/env python3
"""Sign, install, and launch a FlightSim build on a physical iOS device."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile


def select_device(family, requested):
    command = ['xcrun', 'devicectl', 'list', 'devices', '--json-output', '-', '--timeout', '15']
    if not requested:
        command += ['--filter', "State BEGINSWITH 'available' OR State = 'connected'"]
    devices = json.loads(subprocess.check_output(command))['result']['devices']
    candidates = []
    for device in devices:
        hardware = device.get('hardwareProperties', {})
        if hardware.get('reality') != 'physical' or not hardware.get('udid'):
            continue
        if (hardware.get('deviceType', '').lower() != family
                and family not in hardware.get('marketingName', '').lower()):
            continue
        name = device.get('deviceProperties', {}).get('name')
        if not requested or requested in (device['identifier'], hardware['udid'], name):
            candidates.append(device)

    # As in Orca, prefer the single USB device over other Wi-Fi-paired devices.
    if not requested and len(candidates) > 1:
        wired = [device for device in candidates
                 if device.get('connectionProperties', {}).get('transportType') == 'wired']
        if len(wired) == 1:
            return wired[0]
    if len(candidates) != 1:
        raise ValueError(f'Found {len(candidates)} matching devices. Run make ios-devices '
                         'and use DEVICE=<name-or-identifier> to select one.')
    return candidates[0]


def signing_profile(bundle_id, udid):
    identities = subprocess.check_output(['security', 'find-identity', '-v', '-p', 'codesigning'], text=True)
    fingerprints = set(re.findall(r'^\s*\d+\) ([0-9A-F]{40})\s+"Apple Development:', identities, re.MULTILINE))
    if not fingerprints:
        raise ValueError('No valid Apple Development signing identity found. Check Xcode Settings > Accounts.')

    profile_path = os.environ.get('PROFILE')
    paths = [Path(profile_path).expanduser()] if profile_path else [
        path
        for directory in ('Library/Developer/Xcode/UserData/Provisioning Profiles',
                          'Library/MobileDevice/Provisioning Profiles')
        for path in (Path.home() / directory).glob('*.mobileprovision')
    ]
    requested_team = os.environ.get('TEAM')
    now = datetime.now(timezone.utc).replace(tzinfo=None)
    candidates = []
    for path in paths:
        decoded = subprocess.run(['security', 'cms', '-D', '-i', str(path)], capture_output=True)
        if decoded.returncode:
            continue
        profile = plistlib.loads(decoded.stdout)
        entitlements = profile.get('Entitlements', {})
        team = entitlements.get('com.apple.developer.team-identifier')
        expires = profile.get('ExpirationDate')
        if (not team or (requested_team and requested_team != team)
                or not expires or expires <= now or not entitlements.get('get-task-allow')
                or 'iOS' not in profile.get('Platform', []) or udid not in profile.get('ProvisionedDevices', [])):
            continue
        allowed_id = entitlements.get('application-identifier', '')
        prefix, _, _ = allowed_id.partition('.')
        app_id = f'{prefix}.{bundle_id}'
        if not prefix or (allowed_id != app_id and
                          not (allowed_id.endswith('.*') and app_id.startswith(allowed_id[:-1]))):
            continue
        certificates = {hashlib.sha1(cert).hexdigest().upper() for cert in profile.get('DeveloperCertificates', [])}
        available = sorted(fingerprints & certificates)
        if available:
            candidates.append((expires, path, available[0], app_id, team))

    if not candidates:
        raise ValueError(f'No valid development profile and signing identity cover {bundle_id} '
                         'and the selected device. Install a matching profile or set PROFILE to its path.')
    _, path, identity, app_id, team = max(candidates)
    return path, identity, {
        'application-identifier': app_id,
        'com.apple.developer.team-identifier': team,
        'get-task-allow': True,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('family', choices=('iphone', 'ipad'))
    parser.add_argument('app', type=Path)
    args = parser.parse_args()
    app = args.app.resolve()
    info_path = app / 'Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    bundle_id = os.environ.get('BUNDLE_ID') or info['CFBundleIdentifier']

    device = select_device(args.family, os.environ.get('DEVICE'))
    print('Selected ' + device['deviceProperties']['name'], flush=True)
    profile, identity, entitlements = signing_profile(bundle_id, device['hardwareProperties']['udid'])

    if bundle_id != info['CFBundleIdentifier']:
        info['CFBundleIdentifier'] = bundle_id
        info_path.write_bytes(plistlib.dumps(info))
    shutil.copyfile(profile, app / 'embedded.mobileprovision')
    with tempfile.TemporaryDirectory() as directory:
        entitlements_path = Path(directory) / 'entitlements.plist'
        entitlements_path.write_bytes(plistlib.dumps(entitlements))
        subprocess.run(['codesign', '--force', '--sign', identity, '--entitlements', str(entitlements_path),
                        '--generate-entitlement-der', str(app)], check=True)
    subprocess.run(['codesign', '--verify', '--strict', str(app)], check=True)

    command = ['xcrun', 'devicectl', 'device']
    target = ['--device', device['identifier']]
    subprocess.run(command + ['install', 'app'] + target + [str(app)], check=True)
    subprocess.run(command + ['process', 'launch'] + target + ['--terminate-existing', bundle_id], check=True)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError) as error:
        raise SystemExit(str(error))
    except subprocess.CalledProcessError as error:
        raise SystemExit(f'{error.cmd[0]} failed (exit {error.returncode}). See the tool output above.')
