#!/usr/bin/env python3
"""Prepare optional Apple-authorized Safari pairing for Mac Vault.

No profile contents, secrets, or signing credentials are printed. Mac Vault
remains unsandboxed so its existing application inventory/quit controls work.
"""
import argparse
import datetime
import pathlib
import plistlib
import shutil
import subprocess
import sys
import tempfile


def validate_profile(data, bundle_id, environment):
    group = 'group.com.adamancia.vault' + ('.development' if environment == 'development' else '')
    entitlements = data.get('Entitlements', {})
    teams = data.get('TeamIdentifier', [])
    if len(teams) != 1 or not isinstance(teams[0], str) or not teams[0]:
        raise ValueError('The Mac Vault profile must authorize one Apple developer team.')
    team = teams[0]
    if entitlements.get('com.apple.developer.team-identifier') != team:
        raise ValueError('The Mac Vault profile has inconsistent developer team authorization.')
    identifier = entitlements.get('com.apple.application-identifier', entitlements.get('application-identifier', ''))
    prefixes = data.get('ApplicationIdentifierPrefix', [team])
    candidates = [prefix + '.' + bundle_id for prefix in prefixes if isinstance(prefix, str) and prefix]
    expected = next((candidate for candidate in candidates if identifier == candidate or
                     isinstance(identifier, str) and identifier.endswith('*') and candidate.startswith(identifier[:-1])), None)
    if expected is None:
        raise ValueError('The Mac Vault profile does not authorize this bundle identifier.')
    if group not in entitlements.get('com.apple.security.application-groups', []):
        raise ValueError('The Mac Vault profile does not authorize this environment\'s shared Vault App Group.')
    certificates = data.get('DeveloperCertificates', [])
    if not certificates or not all(isinstance(certificate, bytes) for certificate in certificates):
        raise ValueError('The Mac Vault profile does not authorize a signing certificate.')
    expiration = data.get('ExpirationDate')
    if isinstance(expiration, datetime.datetime) and expiration.tzinfo is None:
        expiration = expiration.replace(tzinfo=datetime.timezone.utc)
    if not isinstance(expiration, datetime.datetime) or expiration <= datetime.datetime.now(datetime.timezone.utc):
        raise ValueError('The Mac Vault profile has expired.')
    return team, {'com.apple.application-identifier': expected,
                  'com.apple.developer.team-identifier': team,
                  'com.apple.security.application-groups': [group]}


def decode_profile(path):
    if not path.is_file():
        raise ValueError('The selected Mac Vault provisioning profile is missing.')
    result = subprocess.run(['security', 'cms', '-D', '-i', str(path)], capture_output=True, check=True)
    return plistlib.loads(result.stdout)


def development_info():
    return {'CFBundleIdentifier': 'com.adamancia.vault.mac.development',
            'CFBundleExecutable': 'MacBlockerPanel', 'CFBundleName': 'Mac Vault Development',
            'CFBundleDisplayName': 'Mac Vault Development', 'CFBundlePackageType': 'APPL',
            'CFBundleInfoDictionaryVersion': '6.0', 'CFBundleShortVersionString': '1.0',
            'CFBundleVersion': '1', 'LSMinimumSystemVersion': '13.0',
            'NSHighResolutionCapable': True, 'NSSupportsAutomaticTermination': False,
            'VaultEnvironment': 'development'}


def prepare(args):
    if args.binary:
        if args.environment != 'development' or not args.binary.is_file():
            raise ValueError('Only a current development binary can be wrapped by this helper.')
        info = development_info()
    else:
        info = plistlib.loads((args.app / 'Contents/Info.plist').read_bytes())
    team, entitlements = validate_profile(decode_profile(args.profile), info['CFBundleIdentifier'], args.environment)
    # Profile validation precedes bundle replacement so bad credentials do not
    # replace the previous development build or touch a release candidate.
    if args.binary:
        if args.app.exists():
            shutil.rmtree(args.app)
        contents = args.app / 'Contents'
        (contents / 'MacOS').mkdir(parents=True)
        (contents / 'Resources').mkdir()
        shutil.copy2(args.binary, contents / 'MacOS/MacBlockerPanel')
        for resource in sorted(args.binary.parent.glob('*.bundle')):
            shutil.copytree(resource, contents / 'Resources' / resource.name)
        with (contents / 'Info.plist').open('wb') as output:
            plistlib.dump(info, output)
        (contents / 'PkgInfo').write_bytes(b'APPL????')
    (args.app / 'Contents/embedded.provisionprofile').write_bytes(args.profile.read_bytes())
    args.entitlements.parent.mkdir(parents=True, exist_ok=True)
    with args.entitlements.open('wb') as output:
        plistlib.dump(entitlements, output)
    print(team)


def verify(args):
    info = plistlib.loads((args.app / 'Contents/Info.plist').read_bytes())
    profile = decode_profile(args.profile)
    team, expected = validate_profile(profile, info['CFBundleIdentifier'], args.environment)
    signature = subprocess.run(['codesign', '-dv', '--verbose=4', str(args.app)], capture_output=True, text=True, check=True)
    signed_team = next((line.partition('=')[2] for line in signature.stderr.splitlines() if line.startswith('TeamIdentifier=')), '')
    if signed_team != team:
        raise ValueError('Mac Vault signing identity and provisioning profile belong to different developer teams.')
    with tempfile.TemporaryDirectory(prefix='vault-signing-certificate-') as temporary:
        prefix = pathlib.Path(temporary) / 'certificate'
        subprocess.run(['codesign', '-d', '--extract-certificates', str(prefix), str(args.app)], capture_output=True, check=True)
        if prefix.with_name(prefix.name + '0').read_bytes() not in profile['DeveloperCertificates']:
            raise ValueError('The Mac Vault profile does not authorize the actual signing certificate.')
    result = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(args.app)], capture_output=True, check=True)
    actual = plistlib.loads(result.stdout)
    if any(actual.get(key) != value for key, value in expected.items()) or actual.get('com.apple.security.app-sandbox'):
        raise ValueError('Mac Vault does not have its expected unsandboxed App Group signature.')
    if (args.app / 'Contents/embedded.provisionprofile').read_bytes() != args.profile.read_bytes():
        raise ValueError('The signed Mac Vault bundle does not contain the selected provisioning profile.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['prepare', 'verify'])
    parser.add_argument('--environment', required=True, choices=['development', 'production'])
    parser.add_argument('--profile', type=pathlib.Path, required=True)
    parser.add_argument('--app', type=pathlib.Path, required=True)
    parser.add_argument('--entitlements', type=pathlib.Path)
    parser.add_argument('--binary', type=pathlib.Path)
    args = parser.parse_args()
    if args.operation == 'prepare' and not args.entitlements:
        parser.error('prepare requires --entitlements')
    if args.operation == 'prepare':
        prepare(args)
    else:
        verify(args)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error) if isinstance(error, ValueError) else 'Could not validate or prepare Mac Vault\'s Apple App Group signing.')
