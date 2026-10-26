#!/usr/bin/env python3
"""Small real Mach-O fixtures exercise packaging without signing or user state."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
spec = importlib.util.spec_from_file_location('verifier', HERE / 'verify-macos-runtime.py')
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='vault-release-fixture-')
        self.base = Path(self.temporary.name)
        self.arch = subprocess.check_output(['uname', '-m'], text=True).strip()
        source = self.base / 'main.c'
        source.write_text('int main(void) { return 0; }')
        self.main = self.base / 'main'
        subprocess.run(['xcrun', 'clang', '-mmacosx-version-min=13.3', str(source), '-o', str(self.main)], check=True, capture_output=True)
        self.env = dict(os.environ)
        self.app = self.base / 'FixtureVault.app'
        (self.app / 'Contents/MacOS').mkdir(parents=True)
        (self.app / 'Contents/Resources').mkdir()
        shutil.copy2(self.main, self.app / 'Contents/MacOS/FixtureVault')
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'LSMinimumSystemVersion': '13.3', 'CFBundleIdentifier': 'com.adamancia.fixture',
            'CFBundleExecutable': 'FixtureVault', 'CFBundlePackageType': 'APPL',
            'CFBundleInfoDictionaryVersion': '6.0'}))
        self.env = dict(os.environ, VAULT_LLAMA_PREFIX=str(self.prefix))

    def tearDown(self):
        self.temporary.cleanup()

    def test_cloud_only_app_is_self_contained_and_executable(self):
        verifier.verify_app(self.app, self.arch)
        subprocess.run([str(self.app / 'Contents/MacOS/FixtureVault')], check=True, capture_output=True)

    def test_retired_runtime_is_rejected(self):
        frameworks = self.app / 'Contents/Frameworks'
        frameworks.mkdir()
        shutil.copy2(self.main, frameworks / 'libllama.0.dylib')
        with self.assertRaisesRegex(ValueError, 'retired local inference'):
            verifier.verify_app(self.app, self.arch)

    def test_release_builder_resolves_swiftpm_output_for_architecture(self):
        commands = self.base / 'commands'
        commands.mkdir()
        output = self.base / 'swift-output'
        output.mkdir()
        shutil.copy2(self.main, output / 'MacBlockerPanel')
        helper_source = self.base / 'helper.c'
        helper_source.write_text('int main(void) { return 0; }')
        subprocess.run(['xcrun', 'clang', '-mmacosx-version-min=13.3', str(helper_source),
                        '-o', str(output / 'VaultLocalHubNativeHost')], check=True, capture_output=True)
        resource = output / 'FixtureResources.bundle'
        resource.mkdir()
        (resource / 'seed.json').write_text('{}')
        swift = commands / 'swift'
        swift.write_text('#!/bin/bash\ncase " $* " in *" --show-bin-path "*) echo "$FIXTURE_BIN" ;; esac\nprintf "%s\\n" "$*" >> "$FIXTURE_LOG"\n')
        swift.chmod(0o755)
        env = dict(self.env, PATH=str(commands) + ':' + os.environ['PATH'], FIXTURE_BIN=str(output),
                   FIXTURE_LOG=str(self.base / 'swift.log'), APP_PATH=str(self.app), APP_NAME='FixtureVault',
                   BUILD_DIR=str(self.base / 'build'), ICON_SOURCE=str(self.base / 'absent.png'), VAULT_BUILD_ARCH=self.arch)
        result = subprocess.run(['/bin/bash', str(HERE / 'build_app.sh')], env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.app / 'Contents/Resources/FixtureResources.bundle/seed.json').is_file())
        self.assertTrue((self.app / 'Contents/MacOS/VaultLocalHubNativeHost').is_file())
        self.assertIn('--arch ' + self.arch, (self.base / 'swift.log').read_text())

    def test_uninstaller_preserves_safari_state_and_grants(self):
        commands = self.base / 'commands'
        commands.mkdir()
        for name in ['hdiutil', 'security', 'osascript', 'pkill', 'sleep']:
            command = commands / name
            command.write_text('#!/bin/bash\nexit 0\n' if name != 'security' else '#!/bin/bash\nexit 1\n')
            command.chmod(0o755)
        env = dict(self.env, PATH=str(commands) + ':' + os.environ['PATH'], APP_PATH=str(self.app),
                   APP_NAME='FixtureVault', BUILD_DIR=str(self.base / 'build'), DIST_DIR=str(self.base / 'dist'))
        result = subprocess.run(['/bin/bash', str(HERE / 'create_dmg.sh')], env=env, text=True, capture_output=True)
        # The hdiutil fixture produces no DMG, so checksum creation fails only after staging.
        uninstaller = self.base / 'build/dmg-root/uninstall.command'
        self.assertTrue(uninstaller.is_file(), result.stderr)
        home = self.base / 'fixture-home'
        group = home / 'Library/Group Containers/group.com.adamancia.vault'
        for name in ['SafariVault-production/rules.json', 'SafariVault-production/bookmarks.json',
                     'macosBlocker/web-store.json', 'safari-local-hub-secret-v4']:
            path = group / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(name)
        text = uninstaller.read_text().replace('$HOME', str(home)).replace('/Applications/FixtureVault.app', str(self.base / 'absent-app'))
        uninstaller.write_text(text)
        result = subprocess.run(['/bin/bash', str(uninstaller)], input='y\ny\n', env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((group / 'SafariVault-production/rules.json').read_text(), 'SafariVault-production/rules.json')
        self.assertTrue((group / 'SafariVault-production/bookmarks.json').is_file())
        self.assertFalse((group / 'macosBlocker').exists())
        self.assertFalse((group / 'safari-local-hub-secret-v4').exists())


if __name__ == '__main__':
    unittest.main()
