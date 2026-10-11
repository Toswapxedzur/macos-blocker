#!/usr/bin/env python3
"""Run on the selected remote test host; Git/process checks use disposable fixtures."""
import fcntl
import importlib.util
import json
import os
import pwd
import shlex
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("delivery", Path(__file__).with_name("vault-delivery.py"))
delivery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(delivery)


class DeliveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name).resolve()
        self.repo = self.base / "delivery"
        self.remote = self.base / "origin.git"
        self.run_git(self.base, "init", "--bare", str(self.remote))
        self.run_git(self.base, "init", "-b", delivery.BRANCH, str(self.repo))
        self.run_git(self.repo, "config", "user.name", "Delivery fixture")
        self.run_git(self.repo, "config", "user.email", "fixture@example.invalid")
        self.run_git(self.repo, "config", "vault.deliveryCheckout", str(self.repo))
        (self.repo / "file").write_text("initial")
        self.run_git(self.repo, "add", "file")
        self.run_git(self.repo, "commit", "-m", "initial")
        self.run_git(self.repo, "remote", "add", "origin", str(self.remote))
        self.run_git(self.repo, "push", "-u", "origin", delivery.BRANCH)
        self.patch = patch.object(delivery, "ROOT", self.repo)
        self.patch.start()
        self.common = delivery.context()
        self.first = delivery.git(self.repo, "rev-parse", "HEAD")

    def tearDown(self):
        self.patch.stop()
        self.temp.cleanup()
        self.assertFalse(self.base.exists(), "Owned fixture directory was not cleaned up")

    def run_git(self, root, *args):
        subprocess.run(["git", "-C", str(root), *args], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def verified(self):
        delivery.write_state(self.common, {"verified": {"commit": delivery.git(self.repo, "rev-parse", "HEAD")}})

    def test_unverified_delivery_is_refused_before_process_changes(self):
        with patch.object(delivery, "app_processes") as processes:
            with self.assertRaisesRegex(RuntimeError, "remote verification"):
                delivery.launch(self.common, False)
            processes.assert_not_called()

    def test_dirty_delivery_is_refused(self):
        self.verified()
        (self.repo / "file").write_text("unfinished")
        with self.assertRaisesRegex(RuntimeError, "uncommitted"):
            delivery.check_launch(self.common)

    def test_integration_preserves_history_and_requires_new_verification(self):
        self.verified()
        delivery.write_state(self.common, {"verified": {"commit": self.first}, "delivered": {"commit": self.first}})
        source = self.base / "task"
        self.run_git(self.repo, "worktree", "add", "-b", "feature/task", str(source))
        (source / "feature").write_text("completed")
        self.run_git(source, "add", "feature")
        self.run_git(source, "commit", "-m", "completed task")
        delivery.integrate(self.common, source)
        self.assertEqual((self.repo / "feature").read_text(), "completed")
        with self.assertRaisesRegex(RuntimeError, "remote verification"):
            delivery.check_launch(self.common)
        self.verified()
        with self.assertRaisesRegex(RuntimeError, "Push"):
            delivery.check_launch(self.common)
        self.run_git(self.repo, "push")
        self.assertEqual(delivery.check_launch(self.common)[0], delivery.git(source, "rev-parse", "HEAD"))

    def test_rollback_that_drops_delivered_history_is_refused(self):
        # An orphan branch simulates a delivery ref mistakenly replaced by an
        # unrelated newer history. Everything is inside the disposable repo.
        self.run_git(self.repo, "checkout", "--orphan", "fixture-unrelated")
        self.run_git(self.repo, "commit", "-m", "unrelated newer history")
        sha = delivery.git(self.repo, "rev-parse", "HEAD")
        self.run_git(self.repo, "push", "-u", "origin", "fixture-unrelated")
        delivery.write_state(self.common, {"verified": {"commit": sha}, "delivered": {"commit": self.first}})
        with self.assertRaisesRegex(RuntimeError, "discard previously delivered"):
            delivery.check_launch(self.common)

    def remote_fixture(self, account="john.zhu.alt1", uid=503, home="/Users/john.zhu.alt1"):
        return {"account":account, "uid":uid, "home":home, "uiRuntime":{
            "node":home + "/.local/node/bin/node", "playwrightModule":home + "/agentic-tooling-test-env/lib/python3.14/site-packages/playwright/driver/package/index.mjs",
            "browser":home + "/chrome-testing/chrome-mac-x64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"}}

    def test_selected_account_routes_export_and_all_checks_and_records_exact_identity(self):
        prefix = "/Users/test/pinned runtime/install"
        identity = self.remote_fixture()
        identity["uiRuntime"] = {"node":"/Users/john.zhu/.local/node/bin/node",
                                 "playwrightModule":"/Library/Application Support/Agentic/Playwright/node_modules/playwright/index.mjs",
                                 "browser":"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"}
        original_run = subprocess.run
        remote = []
        def run(command, **kwargs):
            if command[0] == "ssh":
                remote.append((command, kwargs))
                if kwargs.get("stdin") is not None:
                    kwargs["stdin"].read()
                return subprocess.CompletedProcess(command, 0, stdout=json.dumps(identity))
            return original_run(command, **kwargs)
        with patch.object(delivery.subprocess, "run", side_effect=run):
            delivery.verify(self.common, "mini2", prefix, "john.zhu.alt1",
                            identity["uiRuntime"]["node"], identity["uiRuntime"]["playwrightModule"], identity["uiRuntime"]["browser"], jobs=2)
        self.assertEqual(len(remote), 7)  # preflight, archive, five checks
        scripts = []
        for command, _ in remote:
            self.assertEqual(command[:2], ["ssh", "mini2"])
            selected = shlex.split(command[2])
            self.assertEqual(len(selected),8)
            self.assertEqual(selected[:7], ["/usr/bin/sudo", "-n", "-H", "-u", "john.zhu.alt1", "/bin/sh", "-c"])
            scripts.append(selected[7])
        self.assertIn('tar -xf -', scripts[1])
        self.assertIsNotNone(remote[1][1]["stdin"])
        for script in scripts[1:]:
            self.assertIn(" && { ",script)
            self.assertTrue(script.endswith("; }"))
            guard_options = json.loads(shlex.split(script)[3])
            self.assertEqual(guard_options["expected"], identity)
        self.assertIn("'VAULT_LLAMA_PREFIX=" + prefix + "'", scripts[2])
        self.assertIn('UI_PLAYWRIGHT_MODULE=', scripts[5])
        self.assertIn('UI_BROWSER_EXECUTABLE=', scripts[5])
        verified = delivery.read_state(self.common)["verified"]
        self.assertEqual(verified["host"], "mini2")
        self.assertEqual(verified["account"], "john.zhu.alt1")
        self.assertEqual(verified["uid"], 503)
        self.assertEqual(verified["home"], identity["home"])
        self.assertEqual(verified["uiRuntime"], identity["uiRuntime"])
        self.assertEqual(verified["exportPath"], identity["home"] + '/vault-delivery/macosBlocker')
        self.assertEqual(verified["commit"], self.first)
        self.assertEqual(verified["runtimePrefix"], prefix)
        self.assertEqual(verified["jobs"],2)
        self.assertIn(" -j 2",verified["checks"][2])
        self.assertTrue(all(" -j " not in command for index,command in enumerate(verified["checks"]) if index != 2))

    def test_default_mini1_preserves_direct_alias_and_home_runtime_defaults(self):
        identity = self.remote_fixture("johnzhualt", 501, "/Users/johnzhualt")
        original_run = subprocess.run
        remote = []
        def run(command, **kwargs):
            if command[0] == "ssh":
                remote.append(command)
                if kwargs.get("stdin") is not None:
                    kwargs["stdin"].read()
                return subprocess.CompletedProcess(command, 0, stdout=json.dumps(identity))
            return original_run(command, **kwargs)
        with patch.object(delivery.subprocess, "run", side_effect=run):
            delivery.verify(self.common)
        self.assertEqual(len(remote), 7)
        for command in remote:
            self.assertEqual(command[:2], ["ssh", "mini"])
            self.assertNotIn('/usr/bin/sudo', command[2])
        options = json.loads(shlex.split(remote[0][2])[3])
        self.assertIsNone(options["account"])
        self.assertIsNone(options["node"])
        self.assertIsNone(options["playwrightModule"])
        self.assertIsNone(options["browser"])
        verified = delivery.read_state(self.common)["verified"]
        self.assertEqual(verified["host"], "mini1")
        self.assertNotIn('jobs',verified)
        self.assertTrue(all(' -j ' not in command for command in verified['checks']))

    def test_invalid_jobs_refuse_before_remote_preflight_or_export(self):
        self.verified()
        original = (self.common/'vault-delivery.json').read_bytes()
        for jobs in [0,-1,True,False,'2',2.0]:
            with self.subTest(jobs=jobs), patch.object(delivery,'remote_command') as remote, patch.object(delivery,'export_archive') as archive:
                with self.assertRaisesRegex(RuntimeError,'positive integer'):
                    delivery.verify(self.common,'mini2',account='john.zhu.alt1',jobs=jobs)
                remote.assert_not_called()
                archive.assert_not_called()
        self.assertEqual((self.common/'vault-delivery.json').read_bytes(),original)

    def test_invalid_account_and_host_are_refused_before_ssh(self):
        for host, account in [("mini1","john.zhu.alt1"),("mini2","root"),("mini2","-u root"),
                              ("mini2","john;echo x"),("unreviewed-host",None)]:
            with self.subTest(host=host,account=account), patch.object(delivery.subprocess,"run") as remote:
                with self.assertRaisesRegex(RuntimeError, "account|host"):
                    delivery.remote_command(host,account,"true")
                remote.assert_not_called()

    def test_failed_account_preflight_preserves_receipt_and_never_exports(self):
        self.verified()
        original = (self.common/'vault-delivery.json').read_bytes()
        original_run = subprocess.run
        def run(command, **kwargs):
            if command[0] == "ssh": raise subprocess.CalledProcessError(1,command)
            return original_run(command, **kwargs)
        with patch.object(delivery.subprocess,"run",side_effect=run), \
             patch.object(delivery,"export_archive") as archive:
            with self.assertRaises(subprocess.CalledProcessError):
                delivery.verify(self.common,"mini2",account="john.zhu.alt1")
            archive.assert_not_called()
        self.assertEqual((self.common/'vault-delivery.json').read_bytes(),original)

    def test_mismatched_root_or_malformed_identity_is_refused_before_export(self):
        identities = [self.remote_fixture("john.zhu",501,"/Users/john.zhu"),self.remote_fixture(uid=0),
                      self.remote_fixture(home="relative"), {"account":"john.zhu.alt1","uid":503,"home":"/Users/john.zhu.alt1","uiRuntime":{}},
                      {**self.remote_fixture(),"uiRuntime":dict.fromkeys(['node','playwrightModule','browser'],None)}]
        original_run = subprocess.run
        for identity in identities:
            def run(command, **kwargs):
                if command[0] == "ssh": return subprocess.CompletedProcess(command,0,stdout=json.dumps(identity))
                return original_run(command, **kwargs)
            with self.subTest(identity=identity), patch.object(delivery.subprocess,"run",side_effect=run), \
                 patch.object(delivery,"export_archive") as archive:
                with self.assertRaisesRegex(RuntimeError,"verification identity"):
                    delivery.verify(self.common,"mini2",account="john.zhu.alt1")
                archive.assert_not_called()
        self.assertNotIn("verified",delivery.read_state(self.common))

    def test_failed_check_does_not_replace_success_receipt(self):
        self.verified()
        original = (self.common/'vault-delivery.json').read_bytes()
        identity = self.remote_fixture()
        original_run = subprocess.run
        count = 0
        def run(command, **kwargs):
            nonlocal count
            if command[0] != "ssh": return original_run(command, **kwargs)
            count += 1
            if kwargs.get("stdin") is not None: kwargs["stdin"].read()
            if count == 4: raise subprocess.CalledProcessError(1,command)
            return subprocess.CompletedProcess(command,0,stdout=json.dumps(identity))
        with patch.object(delivery.subprocess,"run",side_effect=run):
            with self.assertRaises(subprocess.CalledProcessError):
                delivery.verify(self.common,"mini2",account="john.zhu.alt1")
        self.assertEqual(count,4)
        self.assertEqual((self.common/'vault-delivery.json').read_bytes(),original)

    def test_failed_guard_blocks_every_semicolon_operation_before_export_writes(self):
        target = self.base/'must-not-exist'
        operation = 'set -eu; mkdir ' + shlex.quote(str(target)) + '; printf changed > ' + shlex.quote(str(target/'marker'))
        result = subprocess.run(['/bin/sh','-c',delivery.guarded_remote_script('false',operation)])
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(target.exists())
        result = subprocess.run(['/bin/sh','-c',delivery.guarded_remote_script('true',operation)])
        self.assertEqual(result.returncode,0)
        self.assertEqual((target/'marker').read_text(),'changed')

    def test_export_target_accepts_absent_and_owned_dedicated_directories_without_changes(self):
        home = self.base / 'selected-home'
        home.mkdir()
        delivery.validate_export_target(str(home),os.getuid())
        self.assertFalse((home/'vault-delivery').exists())
        target = home/'vault-delivery/macosBlocker'
        target.mkdir(parents=True)
        sentinel = target/'preserve-existing-source'
        sentinel.write_bytes(b'unchanged')
        before = sentinel.stat()
        delivery.validate_export_target(str(home),os.getuid())
        self.assertEqual(sentinel.read_bytes(),b'unchanged')
        self.assertEqual(sentinel.stat().st_mtime_ns,before.st_mtime_ns)

    def test_export_target_rejects_symlink_file_git_and_foreign_ownership_without_changes(self):
        for kind in ['parent-symlink','child-symlink','parent-file','child-file','parent-git','child-git','bare-git','foreign-owner']:
            with self.subTest(kind=kind):
                home = self.base / kind
                home.mkdir()
                parent = home/'vault-delivery'
                child = parent/'macosBlocker'
                if kind=='parent-symlink': parent.symlink_to(self.repo,target_is_directory=True)
                elif kind=='parent-file': parent.write_bytes(b'foreign file')
                else:
                    parent.mkdir()
                    if kind=='child-symlink': child.symlink_to(self.repo,target_is_directory=True)
                    elif kind=='child-file': child.write_bytes(b'foreign file')
                    else:
                        child.mkdir()
                        if kind=='parent-git': (parent/'.git').write_bytes(b'repository pointer')
                        if kind=='child-git': (child/'.git').mkdir()
                        if kind=='bare-git':
                            for name in ['HEAD','config']: (child/name).write_bytes(b'bare repository')
                            for name in ['objects','refs']: (child/name).mkdir()
                before = {str(p.relative_to(home)):p.read_bytes() for p in home.rglob('*') if p.is_file() and not p.is_symlink()}
                if kind=='foreign-owner':
                    actual = Path.lstat
                    def foreign(path, *args, **kwargs):
                        metadata = actual(path,*args,**kwargs)
                        if path == parent: return SimpleNamespace(st_mode=metadata.st_mode,st_uid=os.getuid()+1)
                        return metadata
                    with patch.object(Path,'lstat',foreign), self.assertRaisesRegex(RuntimeError,'owned by selected UID'):
                        delivery.validate_export_target(str(home),os.getuid())
                else:
                    with self.assertRaisesRegex(RuntimeError,'export target'):
                        delivery.validate_export_target(str(home),os.getuid())
                after = {str(p.relative_to(home)):p.read_bytes() for p in home.rglob('*') if p.is_file() and not p.is_symlink()}
                self.assertEqual(after,before)

    def preflight_tools(self):
        paths = {}
        for name in ['node', 'module', 'browser']:
            # Literal shell punctuation/spaces verify quoting without execution.
            path = self.base / (name + " ' literal $ punctuation")
            path.write_text("fixture runtime; never executed")
            path.chmod(0o700 if name != 'module' else 0o600)
            paths[name] = str(path)
        return paths

    def test_real_preflight_and_guard_validate_current_nonroot_identity_without_tool_execution(self):
        paths = self.preflight_tools()
        account = pwd.getpwuid(os.getuid()).pw_name
        script = delivery.remote_preflight_script(account,str(self.base),paths['node'],paths['module'],paths['browser'])
        first = subprocess.run(['/bin/sh','-c',script],capture_output=True,text=True,check=True)
        identity = json.loads(first.stdout)
        self.assertEqual(identity['uid'],os.getuid())
        self.assertEqual(identity['account'],account)
        self.assertEqual(identity['home'],pwd.getpwuid(os.getuid()).pw_dir)
        self.assertEqual(identity['uiRuntime']['node'],paths['node'])
        guard = delivery.remote_preflight_script(account,str(self.base),paths['node'],paths['module'],paths['browser'],identity)
        result = subprocess.run(['/bin/sh','-c',guard],capture_output=True,text=True,check=True)
        self.assertEqual(result.stdout,'')
        changed = {**identity,'uid':identity['uid']+1}
        rejected = delivery.remote_preflight_script(account,str(self.base),paths['node'],paths['module'],paths['browser'],changed)
        result = subprocess.run(['/bin/sh','-c',rejected],capture_output=True,text=True)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('identity/runtime changed',result.stderr)

    def test_real_preflight_rejects_missing_nonexecutable_and_relative_runtime(self):
        paths = self.preflight_tools()
        account = pwd.getpwuid(os.getuid()).pw_name
        for prefix, node, module in [(str(self.base),str(self.base/'missing'),paths['module']),
                                     (str(self.base),paths['module'],paths['module']),
                                     ('relative-runtime',paths['node'],paths['module'])]:
            with self.subTest(prefix=prefix,node=node):
                script = delivery.remote_preflight_script(account,prefix,node,module,paths['browser'])
                result = subprocess.run(['/bin/sh','-c',script],capture_output=True,text=True)
                self.assertNotEqual(result.returncode,0)
                self.assertIn('unavailable to selected account',result.stderr)
                self.assertEqual(result.stdout,'')

    def test_check_only_never_closes_or_launches_apps(self):
        self.verified()
        with patch.object(delivery, "check_launch", return_value=(self.first, {})), patch.object(delivery, "app_processes") as processes, patch.object(delivery.subprocess, "Popen") as launch:
            delivery.launch(self.common, True)
            processes.assert_not_called()
            launch.assert_not_called()

    def test_concurrent_delivery_is_refused(self):
        with (self.common / "vault-delivery.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with patch.object(sys, "argv", ["vault-delivery", "status"]):
                with self.assertRaisesRegex(RuntimeError, "Another integration"):
                    delivery.main()

    def test_task_launcher_routes_to_shared_controller(self):
        source = self.base / "task"
        self.run_git(self.repo, "worktree", "add", "-b", "feature/launcher", str(source))
        production = Path(__file__).resolve().parents[2]
        (source / "run-mac-vault.sh").write_text((production / "run-mac-vault.sh").read_text())
        controller = self.repo / "scripts/development/vault-delivery.py"
        controller.parent.mkdir(parents=True)
        controller.write_text('import sys; print("shared-controller:" + sys.argv[1])\n')
        result = subprocess.run(["bash", str(source / "run-mac-vault.sh")], text=True, capture_output=True, check=True)
        self.assertEqual(result.stdout.strip(), "shared-controller:launch")

    def test_direct_task_build_is_refused_before_signing_or_building(self):
        source = self.base / "task"
        self.run_git(self.repo, "worktree", "add", "-b", "feature/direct-build", str(source))
        script = source / "scripts/development/launch-mac-vault-build.sh"
        script.parent.mkdir(parents=True)
        script.write_text(Path(__file__).with_name("launch-mac-vault-build.sh").read_text())
        result = subprocess.run(["bash", str(script)], text=True, capture_output=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("verified shared checkout", result.stderr)


if __name__ == "__main__":
    unittest.main()
