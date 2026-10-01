#!/usr/bin/env python3
"""Run only on mini1; Git and process checks use disposable fixtures."""
import fcntl
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
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

    def run_git(self, root, *args):
        subprocess.run(["git", "-C", str(root), *args], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def verified(self):
        delivery.write_state(self.common, {"verified": {"commit": delivery.git(self.repo, "rev-parse", "HEAD")}})

    def test_unverified_delivery_is_refused_before_process_changes(self):
        with patch.object(delivery, "app_processes") as processes:
            with self.assertRaisesRegex(RuntimeError, "mini1 verification"):
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
        with self.assertRaisesRegex(RuntimeError, "mini1 verification"):
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
