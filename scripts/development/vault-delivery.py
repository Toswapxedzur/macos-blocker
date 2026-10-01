#!/usr/bin/env python3
"""Integrate, verify on mini1, and deliver Mac Vault from one shared checkout."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
BRANCH = "integration/local-delivery"


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args], text=True).strip()


def clean(root):
    if git(root, "status", "--porcelain"):
        raise RuntimeError(f"Worktree has uncommitted changes: {root}")


def context():
    checkout = Path(git(ROOT, "config", "--get", "vault.deliveryCheckout")).resolve()
    common = (ROOT / git(ROOT, "rev-parse", "--git-common-dir")).resolve()
    if checkout != ROOT:
        raise RuntimeError(f"Use the shared command in {checkout}")
    if git(ROOT, "branch", "--show-current") != BRANCH:
        raise RuntimeError(f"Delivery checkout must be on {BRANCH}")
    return common


def read_state(common):
    path = common / "vault-delivery.json"
    return json.loads(path.read_text()) if path.exists() else {}


def write_state(common, state):
    path = common / "vault-delivery.json"
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(state, indent=2) + "\n")
    temporary.replace(path)


def check_launch(common):
    clean(ROOT)
    sha = git(ROOT, "rev-parse", "HEAD")
    state = read_state(common)
    if state.get("verified", {}).get("commit") != sha:
        raise RuntimeError("This delivery commit has not passed mini1 verification. Run vault-delivery verify.")
    if git(ROOT, "rev-parse", "@{upstream}") != sha:
        raise RuntimeError("Push the verified delivery branch before launching.")
    previous = state.get("delivered", {}).get("commit")
    if previous and subprocess.run(["git", "-C", str(ROOT), "merge-base", "--is-ancestor", previous, sha]).returncode:
        raise RuntimeError("Delivery would discard previously delivered history. Integrate it first.")
    return sha, state


def integrate(common, source):
    source = Path(source).resolve()
    clean(source)
    clean(ROOT)
    source_common = (source / git(source, "rev-parse", "--git-common-dir")).resolve()
    if source_common != common:
        raise RuntimeError("Source must be a worktree of the same Mac Vault repository.")
    sha = git(source, "rev-parse", "HEAD")
    subprocess.run(["git", "-C", str(ROOT), "merge", "--no-edit", sha], check=True)
    print(f"Integrated {sha}; verify the combined delivery commit on mini1 before launch.")


def verify(common):
    clean(ROOT)
    sha = git(ROOT, "rev-parse", "HEAD")
    # Only committed files cross hosts. Keep mini1's build cache, but remove
    # retired source files from this dedicated verification copy.
    archive = subprocess.Popen(["git", "-C", str(ROOT), "archive", sha], stdout=subprocess.PIPE)
    transfer = 'set -eu; mkdir -p "$HOME/vault-delivery"; vault_stage=$(mktemp -d "$HOME/vault-delivery/snapshot.XXXXXX"); trap \'rm -rf "$vault_stage"\' EXIT; tar -xf - -C "$vault_stage"; mkdir -p "$HOME/vault-delivery/macosBlocker"; rsync -a --delete --exclude=.build "$vault_stage/" "$HOME/vault-delivery/macosBlocker/"'
    try:
        subprocess.run(["ssh", "mini", transfer], stdin=archive.stdout, check=True)
    finally:
        archive.stdout.close()
        if archive.wait():
            raise RuntimeError("Could not export the delivery commit.")
    checks = [
        "python3 scripts/development/test-vault-delivery.py",
        "bash -n run-mac-vault.sh scripts/development/launch-mac-vault-build.sh",
        "swift build --product MacBlockerPanel",
        "$HOME/.local/node/bin/node classifier/Tests/WebUI/autosave.mjs",
        'UI_TEST_SCRIPT=classifier/Tests/WebUI/dropdown-layout.js UI_TEST_EXPRESSION="runDropdownLayoutTests()" $HOME/.local/node/bin/node classifier/Tests/WebUI/autosave.mjs',
    ]
    for command in checks:
        subprocess.run(["ssh", "mini", 'cd "$HOME/vault-delivery/macosBlocker" && ' + command], check=True)
    clean(ROOT)
    if git(ROOT, "rev-parse", "HEAD") != sha:
        raise RuntimeError("Delivery HEAD changed during verification; verify again.")
    state = read_state(common)
    state["verified"] = {"commit": sha, "host": "mini1", "at": time.time(), "checks": checks}
    write_state(common, state)
    print(f"Verified {sha} on mini1.")


def app_processes():
    found = []
    for row in subprocess.check_output(["ps", "-axo", "pid=,comm="], text=True).splitlines():
        parts = row.strip().split(None, 1)
        if len(parts) == 2 and Path(parts[1]).name in {"MacBlockerPanel", "VaultClassifier", "VaultClassifierApp"}:
            found.append(int(parts[0]))
    return found


def launch(common, check_only):
    sha, state = check_launch(common)
    if check_only:
        print(f"Ready to deliver {sha} from {ROOT}")
        return
    previous = app_processes()
    for pid in previous:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    for _ in range(50):
        if not set(previous).intersection(app_processes()):
            break
        time.sleep(0.1)
    else:
        raise RuntimeError("An old Mac Vault instance did not close; delivery stopped.")
    # This is delivery on the laptop, not UI/behavior verification.
    output = Path.home() / "Desktop/agentic/captures/vault-delivery"
    output.mkdir(parents=True, exist_ok=True)
    (output / "package-info.md").write_text("# Shared Mac Vault delivery\n\n- `launch.log`: latest supported launcher output; laptop delivery only.\n")
    log_path = output / "launch.log"
    with log_path.open("w") as log:
        environment = {**os.environ, "VAULT_DELIVERY_COMMIT": sha}
        process = subprocess.Popen(["bash", str(ROOT / "scripts/development/launch-mac-vault-build.sh")], env=environment, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    binary_dir = ROOT / ".build"
    for _ in range(120):
        if process.poll() is not None:
            raise RuntimeError(f"Launcher exited; inspect {log_path}")
        command = subprocess.check_output(["ps", "-p", str(process.pid), "-o", "comm="], text=True).strip()
        if Path(command).name == "MacBlockerPanel" and Path(command).is_relative_to(binary_dir):
            state["delivered"] = {"commit": sha, "pid": process.pid, "checkout": str(ROOT), "at": time.time()}
            write_state(common, state)
            print(f"Delivered {sha}; Mac Vault PID {process.pid}, checkout {ROOT}.")
            return
        time.sleep(1)
    raise RuntimeError(f"Launcher is still building; inspect {log_path}. No delivery receipt was written.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    merge = commands.add_parser("integrate")
    merge.add_argument("--source", required=True)
    commands.add_parser("verify")
    start = commands.add_parser("launch")
    start.add_argument("--check", action="store_true")
    commands.add_parser("status")
    args = parser.parse_args()
    common = context()
    with (common / "vault-delivery.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("Another integration, verification or delivery is active; retry after it finishes.")
        if args.command == "integrate":
            integrate(common, args.source)
        elif args.command == "verify":
            verify(common)
        elif args.command == "launch":
            launch(common, args.check)
        else:
            print(json.dumps({"checkout": str(ROOT), "branch": BRANCH, "head": git(ROOT, "rev-parse", "HEAD"), **read_state(common)}, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(f"Delivery stopped: {error}", file=sys.stderr)
        sys.exit(1)
