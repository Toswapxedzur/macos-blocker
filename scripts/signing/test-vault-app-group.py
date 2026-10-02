#!/usr/bin/env python3
"""mini1-only profile metadata and supported-launcher contract fixtures.

The command tools are fixtures. These checks do not establish Apple signing,
App Group access, or Safari browser acceptance.
"""
import copy
import datetime
import importlib.util
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('group_signing', Path(__file__).with_name('vault-app-group.py'))
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
TEAM = 'EXAMPLETEAM'


def profile(environment):
    suffix = '.development' if environment == 'development' else ''
    return {'TeamIdentifier': [TEAM], 'ApplicationIdentifierPrefix': [TEAM],
            'DeveloperCertificates': [b'fixture authorized certificate'],
            'ExpirationDate': datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None) + datetime.timedelta(days=1),
            'Entitlements': {'com.apple.application-identifier': TEAM + '.com.adamancia.vault.mac' + suffix,
                             'com.apple.developer.team-identifier': TEAM,
                             'com.apple.security.application-groups': ['group.com.adamancia.vault' + suffix]}}


class ProfileTests(unittest.TestCase):
    def test_valid_profile_preserves_unsandboxed_mac_contract(self):
        _, entitlements = helper.validate_profile(profile('development'), 'com.adamancia.vault.mac.development', 'development')
        self.assertNotIn('com.apple.security.app-sandbox', entitlements)
        self.assertEqual(entitlements['com.apple.security.application-groups'], ['group.com.adamancia.vault.development'])

    def test_wrong_environment_is_refused(self):
        with self.assertRaisesRegex(ValueError, 'App Group'):
            helper.validate_profile(profile('production'), 'com.adamancia.vault.mac', 'development')

    def test_wrong_bundle_is_refused(self):
        with self.assertRaisesRegex(ValueError, 'bundle identifier'):
            helper.validate_profile(profile('development'), 'com.unrelated.app', 'development')

    def test_expired_profile_is_refused(self):
        data = profile('development')
        data['ExpirationDate'] = datetime.datetime(2020, 1, 1)
        with self.assertRaisesRegex(ValueError, 'expired'):
            helper.validate_profile(data, 'com.adamancia.vault.mac.development', 'development')

    def test_wrong_team_entitlement_is_refused(self):
        data = profile('development')
        data['Entitlements']['com.apple.developer.team-identifier'] = 'OTHERTEAM'
        with self.assertRaisesRegex(ValueError, 'team'):
            helper.validate_profile(data, 'com.adamancia.vault.mac.development', 'development')

    def test_legacy_application_prefix_is_validated_independently(self):
        data = profile('development')
        data['ApplicationIdentifierPrefix'] = ['LEGACYPREFIX']
        data['Entitlements']['com.apple.application-identifier'] = 'LEGACYPREFIX.com.adamancia.vault.mac.development'
        team, entitlements = helper.validate_profile(data, 'com.adamancia.vault.mac.development', 'development')
        self.assertEqual(team, TEAM)
        self.assertTrue(entitlements['com.apple.application-identifier'].startswith('LEGACYPREFIX.'))

    def test_missing_signing_certificate_is_refused(self):
        data = profile('development')
        data.pop('DeveloperCertificates')
        with self.assertRaisesRegex(ValueError, 'certificate'):
            helper.validate_profile(data, 'com.adamancia.vault.mac.development', 'development')


class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='vault-signing-fixture-')
        self.base = Path(self.temp.name)
        self.repo = self.base / 'checkout with spaces'
        self.tools = self.base / 'tools'
        self.tools.mkdir()
        for source in ['scripts/development/launch-mac-vault-build.sh', 'scripts/release/sign_app.sh', 'scripts/signing/vault-app-group.py']:
            target = self.repo / source
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / source, target)
        self.bin_dir = self.repo / '.build/test/debug'
        self.bin_dir.mkdir(parents=True)
        self.binary = self.bin_dir / 'MacBlockerPanel'
        self.binary.write_text('#!/bin/bash\nprintf "%s" "$ADAMANCIA_VAULT_ENVIRONMENT" > "$FIXTURE_RECEIPT"\n')
        self.binary.chmod(0o755)
        bundle = self.bin_dir / 'FixtureResources.bundle'
        bundle.mkdir()
        (bundle / 'seed.json').write_text('{"fixture":true}')
        for relative in ['scripts/development/migrate_state_once.sh', 'classifier/scripts/install-dev-native-host.sh']:
            script = self.repo / relative
            script.parent.mkdir(parents=True, exist_ok=True)
            script.write_text('#!/bin/bash\nexit 0\n')
            script.chmod(0o755)
        self.cms = self.base / 'profile.plist'
        self.cms.write_bytes(plistlib.dumps(profile('development')))
        self.selected = self.base / 'selected.provisionprofile'
        self.selected.write_bytes(b'fixture CMS bytes: not an Apple-signed profile')
        self.code_log = self.base / 'codesign.log'
        self.entitlements = self.base / 'actual-entitlements.plist'
        self.receipt = self.base / 'exec-receipt'
        self.write_tool('swift', '#!/bin/bash\nif [[ "$*" == "build --show-bin-path" ]]; then printf "%s\\n" "$FIXTURE_BIN_DIR"; fi\n')
        self.write_tool('security', '#!/bin/bash\nif [[ "$1" == cms ]]; then cat "$FIXTURE_PROFILE"; else printf "1) DUMMY Fixture Identity\\n"; fi\n')
        self.write_tool('codesign', '''#!/usr/bin/env python3
import json,os,pathlib,shutil,sys
args=sys.argv[1:]
with open(os.environ['FIXTURE_CODESIGN_LOG'],'a') as log: log.write(json.dumps(args)+'\\n')
if '-dv' in args: print('TeamIdentifier='+os.environ.get('FIXTURE_SIGNED_TEAM','EXAMPLETEAM'),file=sys.stderr)
elif '--extract-certificates' in args: pathlib.Path(args[args.index('--extract-certificates')+1]+'0').write_bytes(b'fixture authorized certificate')
elif '-d' in args: sys.stdout.buffer.write(pathlib.Path(os.environ['FIXTURE_ENTITLEMENTS']).read_bytes())
elif '--entitlements' in args: shutil.copyfile(args[args.index('--entitlements')+1],os.environ['FIXTURE_ENTITLEMENTS'])
''')
        self.env = {**os.environ, 'PATH': str(self.tools) + ':' + os.environ['PATH'],
                    'MAC_VAULT_SIGNING_IDENTITY': 'Fixture Identity', 'FIXTURE_BIN_DIR': str(self.bin_dir),
                    'FIXTURE_PROFILE': str(self.cms), 'FIXTURE_CODESIGN_LOG': str(self.code_log),
                    'FIXTURE_ENTITLEMENTS': str(self.entitlements), 'FIXTURE_RECEIPT': str(self.receipt)}
        self.env.pop('MAC_VAULT_APP_PROVISIONING_PROFILE', None)
        self.env.pop('VAULT_DELIVERY_COMMIT', None)

    def tearDown(self):
        self.temp.cleanup()

    def write_tool(self, name, content):
        target = self.tools / name
        target.write_text(content)
        target.chmod(0o755)

    def launch(self):
        return subprocess.run(['bash', str(self.repo / 'scripts/development/launch-mac-vault-build.sh')],
                              env=self.env, text=True, capture_output=True)

    def test_profile_absent_retains_stable_binary_and_reports_pairing_unavailable(self):
        result = self.launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.receipt.read_text(), 'development')
        self.assertIn('Safari pairing unavailable', result.stderr)
        self.assertFalse((self.bin_dir / 'Mac Vault Development.app').exists())

    def test_profile_wrapper_preserves_controller_executable_and_resources(self):
        self.env['MAC_VAULT_APP_PROVISIONING_PROFILE'] = str(self.selected)
        result = self.launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        app = self.bin_dir / 'Mac Vault Development.app'
        self.assertEqual((app / 'Contents/MacOS/MacBlockerPanel').read_bytes(), self.binary.read_bytes())
        self.assertEqual(self.receipt.read_text(), 'development')
        self.assertTrue(app.is_relative_to(self.repo / '.build'))
        self.assertTrue((app / 'Contents/Resources/FixtureResources.bundle/seed.json').is_file())
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        self.assertEqual(info['CFBundleIdentifier'], 'com.adamancia.vault.mac.development')
        self.assertEqual(info['CFBundleExecutable'], 'MacBlockerPanel')
        self.assertEqual((app / 'Contents/embedded.provisionprofile').read_bytes(), self.selected.read_bytes())
        import json
        signs = [json.loads(line) for line in self.code_log.read_text().splitlines()]
        outer = [args for args in signs if '--force' in args and '--entitlements' in args]
        self.assertEqual(len(outer), 1)
        self.assertNotIn('--deep', outer[0])
        self.assertNotIn('com.apple.security.app-sandbox', plistlib.loads(self.entitlements.read_bytes()))

    def test_bad_profile_preserves_previous_wrapper_and_never_executes(self):
        previous = self.bin_dir / 'Mac Vault Development.app'
        previous.mkdir()
        (previous / 'preserve').write_text('previous verified wrapper')
        invalid = profile('development')
        invalid['Entitlements']['com.apple.security.application-groups'] = ['group.unrelated']
        self.cms.write_bytes(plistlib.dumps(invalid))
        self.env['MAC_VAULT_APP_PROVISIONING_PROFILE'] = str(self.selected)
        result = self.launch()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((previous / 'preserve').read_text(), 'previous verified wrapper')
        self.assertFalse(self.receipt.exists())
        self.assertFalse(self.code_log.exists())

    def test_wrong_actual_signing_team_never_executes(self):
        self.env.update({'MAC_VAULT_APP_PROVISIONING_PROFILE': str(self.selected), 'FIXTURE_SIGNED_TEAM': 'OTHERTEAM'})
        result = self.launch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('different developer teams', result.stderr)
        self.assertFalse(self.receipt.exists())

    def test_certificate_from_same_team_must_be_authorized(self):
        data = profile('development')
        data['DeveloperCertificates'] = [b'another certificate from the same team']
        self.cms.write_bytes(plistlib.dumps(data))
        self.env['MAC_VAULT_APP_PROVISIONING_PROFILE'] = str(self.selected)
        result = self.launch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('actual signing certificate', result.stderr)
        self.assertFalse(self.receipt.exists())

    def test_release_group_entitlements_apply_only_to_outer_app(self):
        self.cms.write_bytes(plistlib.dumps(profile('production')))
        app = self.repo / 'release/build/AdamanciaVault.app'
        (app / 'Contents').mkdir(parents=True)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.adamancia.vault.mac'}))
        self.env.update({'MAC_VAULT_APP_PROVISIONING_PROFILE': str(self.selected),
                         'SIGNING_IDENTITY': 'Fixture Identity'})
        result = subprocess.run(['bash', str(self.repo / 'scripts/release/sign_app.sh')], env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        import json
        signs = [json.loads(line) for line in self.code_log.read_text().splitlines() if '--force' in line]
        self.assertEqual(len(signs), 2)
        self.assertIn('--deep', signs[0])
        self.assertNotIn('--entitlements', signs[0])
        self.assertIn('--entitlements', signs[1])
        self.assertNotIn('--deep', signs[1])
        entitlements = plistlib.loads(self.entitlements.read_bytes())
        self.assertEqual(entitlements['com.apple.security.application-groups'], ['group.com.adamancia.vault'])


if __name__ == '__main__':
    unittest.main()
