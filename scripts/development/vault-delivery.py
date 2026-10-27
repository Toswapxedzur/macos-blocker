#!/usr/bin/env python3
"""Integrate, verify on the selected test host, and deliver from one shared checkout."""
import argparse
import fcntl
import hashlib
import inspect
import json
import os
import re
from pathlib import Path
import signal
import shlex
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
BRANCH = "integration/local-delivery"
APPROVED_REMOTE_URL = "git@github.com:Toswapxedzur/macos-blocker.git"
APPROVED_CHECKOUT = Path("/Users/fengyue.john.zhu/Desktop/agentic/worktrees/vault-delivery/macosBlocker")
SUPPORTED_RECONCILIATIONS = {
    ("dc6548d967596df22b3bf6b451ec471ad7093935", "9de26f1db20fe319b7a85dfef1fc44f29afc3bd9"):
        {"tree": "12a36a90a0871e402369bb279ec908045b11d5f9",
         "oldCheckout": "ebddc16ad6270ddc8ea56e9b36750715a24a6adf",
         "oldSource": "7cc1686ccda9bd787125a3686c7905db689b0d27",
         "candidate": "83724b9239c55c3e0866230cd8126dec0cf06ed2",
         "sourceTree": "d0a8fe0e6021be3c27393daadafdce0460e1a98b"},
}


# Owner-approved on 2026-10-27. These are source-identical metadata aliases,
# never a rule for discovering arbitrary equal trees or replacing app history.
SUPPORTED_METADATA_RECOVERIES = {
    "metadata-rewrite-20261027": {
        "integrationHead": "00c1b790ecc6388a1bac6d803bd58a0473539582",
        "minimumSource": "c5e7dc027a1e9d2c7ab663c3a15b99b82c15d2d2",
        "stateSHA256": "08d3b5b9708993b90e45343bee224a6f8bfc3968e237f6405c6e71b5a1d634e3",
        "reconciliationOld": "dc6548d967596df22b3bf6b451ec471ad7093935",
        "reconciliationNew": "9de26f1db20fe319b7a85dfef1fc44f29afc3bd9",
        "delivered": "4012d7a8141af96266c5b02fd9a6c4039ae979f7",
        "allowedSourcePaths": ["scripts/development/vault-delivery.py", "scripts/development/test-metadata-recovery.py",
                               "scripts/development/README.md", "scripts/development/package-info.md"],
        "aliases": {
            "dc6548d967596df22b3bf6b451ec471ad7093935": "8ed2ec0f2eef05e5b63b94d2bf4c592b5f7f3c04",
            "9de26f1db20fe319b7a85dfef1fc44f29afc3bd9": "8ed2ec0f2eef05e5b63b94d2bf4c592b5f7f3c04",
            "ebddc16ad6270ddc8ea56e9b36750715a24a6adf": "3c08e38853d5bc58f934ad592cd5a8aaaea4e94e",
            "7cc1686ccda9bd787125a3686c7905db689b0d27": "420614f0114d63f80a3ee2cf4cc66f6f436070a4",
            "83724b9239c55c3e0866230cd8126dec0cf06ed2": "7e8e804a82091d60e4c3d2caaeadbfab28c1394b",
            "4012d7a8141af96266c5b02fd9a6c4039ae979f7": "02814ad7393bab994e4f54edbaf39f298403bf00",
            "8b7fee490fa81e10fa58bcdc44ef3b47692e05e5": "00c1b790ecc6388a1bac6d803bd58a0473539582",
        },
    },
}


def metadata_archive_path(common, policy_id):
    return common / "vault-history-reconciliation" / (policy_id + ".before.json")


def metadata_ref_prefix(policy_id):
    return "refs/vault-delivery/metadata-recovery/" + policy_id + "/"


def validate_metadata_policy(policy):
    for old, new in policy["aliases"].items():
        if not all(isinstance(sha, str) and re.fullmatch(r"[0-9a-f]{40}", sha) for sha in (old, new)):
            raise RuntimeError("Metadata recovery requires exact reviewed commit IDs.")
        for sha in (old, new):
            if git(ROOT, "rev-parse", sha + "^{commit}") != sha:
                raise RuntimeError("Metadata recovery commit is missing.")
        if git(ROOT, "rev-parse", old + "^{tree}") != git(ROOT, "rev-parse", new + "^{tree}"):
            raise RuntimeError("Metadata recovery aliases have different source trees.")


def metadata_aliases(common, state):
    records = state.get("metadataRecoveries", [])
    if "metadataRecoveries" not in state:
        return {}
    if not isinstance(records, list) or len(records) != 1 or not isinstance(records[0], dict):
        raise RuntimeError("Metadata recovery record is invalid.")
    record = records[0]
    policy_id = record.get("policy")
    policy = SUPPORTED_METADATA_RECOVERIES.get(policy_id)
    if policy is None or record.get("version") != 1 or record.get("stage") != "adopted":
        raise RuntimeError("Metadata recovery policy is unsupported or incomplete.")
    if ROOT != APPROVED_CHECKOUT:
        raise RuntimeError("Metadata recovery is restricted to the approved checkout.")
    path = metadata_archive_path(common, policy_id)
    if path.is_symlink() or not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != policy["stateSHA256"]:
        raise RuntimeError("Original metadata recovery receipt changed or is missing.")
    original = json.loads(path.read_bytes())
    if original.get("historyReconciliations") != state.get("historyReconciliations"):
        raise RuntimeError("Original history reconciliation record changed.")
    validate_metadata_policy(policy)
    prefix = metadata_ref_prefix(policy_id)
    for old, new in policy["aliases"].items():
        if git(ROOT, "rev-parse", prefix + "original/" + old) != old or git(ROOT, "rev-parse", prefix + "rewritten/" + old) != new:
            raise RuntimeError("Metadata preservation ref changed or is missing.")
    source = record.get("source")
    if not isinstance(source, str) or not re.fullmatch(r"[0-9a-f]{40}", source) or git(ROOT, "rev-parse", prefix + "source") != source:
        raise RuntimeError("Reviewed metadata recovery source changed.")
    if not ancestor(policy["minimumSource"], source):
        raise RuntimeError("Metadata recovery source omits accepted task history.")
    return policy["aliases"]


def pushed_source_head(source):
    upstream = git(source, "rev-parse", "--symbolic-full-name", "@{upstream}")
    prefix = "refs/remotes/origin/"
    if not upstream.startswith(prefix):
        raise RuntimeError("Recovery source must track the approved origin.")
    branch = "refs/heads/" + upstream[len(prefix):]
    rows = git(source, "ls-remote", "--exit-code", "origin", branch).splitlines()
    if len(rows) != 1 or len(rows[0].split()) != 2 or rows[0].split()[1] != branch:
        raise RuntimeError("Cannot validate the recovery source's actual remote ref.")
    return rows[0].split()[0]


def recover_metadata_history(common, source, policy_id):
    """Explicit approved adoption; preserve both histories without resetting HEAD."""
    if ROOT != APPROVED_CHECKOUT:
        raise RuntimeError("Metadata recovery is restricted to the approved checkout.")
    policy = SUPPORTED_METADATA_RECOVERIES.get(policy_id)
    if policy is None:
        raise RuntimeError("Unsupported metadata recovery policy.")
    source = Path(source).resolve()
    clean(ROOT); clean(source); remote_identity()
    if (source / git(source, "rev-parse", "--git-common-dir")).resolve() != common:
        raise RuntimeError("Metadata recovery source must share the same repository.")
    head = git(ROOT, "rev-parse", "HEAD")
    if head != policy["integrationHead"] or git(ROOT, "rev-parse", "@{upstream}") != head or live_remote_commit() != head:
        raise RuntimeError("Integration or its remote changed since metadata review.")
    candidate = git(source, "rev-parse", "HEAD")
    if git(source, "rev-parse", "@{upstream}") != candidate or pushed_source_head(source) != candidate or not ancestor(policy["minimumSource"], candidate):
        raise RuntimeError("Recovery source must be pushed and include the reviewed task.")
    changed = set(git(source, "diff", "--name-only", policy["minimumSource"], candidate).splitlines())
    if not changed or not changed.issubset(policy["allowedSourcePaths"]):
        raise RuntimeError("Recovery source contains changes outside the reviewed controller scope.")
    raw = (common / "vault-delivery.json").read_bytes()
    if hashlib.sha256(raw).hexdigest() != policy["stateSHA256"]:
        raise RuntimeError("Delivery receipt changed since metadata review.")
    state = json.loads(raw)
    if state.get("metadataRecoveries") or state.get("delivered", {}).get("commit") != policy["delivered"]:
        raise RuntimeError("Metadata recovery already exists or delivery changed.")
    if len(state.get("historyReconciliations", [])) != 1:
        raise RuntimeError("Metadata recovery requires the original reconciliation.")
    record = state["historyReconciliations"][0]
    if (record.get("oldBase"), record.get("newBase")) != (policy["reconciliationOld"], policy["reconciliationNew"]):
        raise RuntimeError("Metadata recovery does not match the original reconciliation.")
    supported_mapping(record["oldBase"], record["newBase"])
    original = snapshot_path(common, record["oldBase"], record["newBase"])
    if original.is_symlink() or not original.is_file() or hashlib.sha256(original.read_bytes()).hexdigest() != record["originalReceiptSHA256"]:
        raise RuntimeError("Original reconciliation receipt changed or is missing.")
    validate_metadata_policy(policy)
    prefix = ref_prefix(record["oldBase"], record["newBase"])
    for name, old in (("old-delivered", record["oldBase"]), ("old-checkout", record["oldCheckout"]),
                      ("old-source", record["oldSource"]), ("new-base", record["newBase"]), ("candidate", record["candidate"])):
        if git(ROOT, "rev-parse", prefix + name) != policy["aliases"].get(old):
            raise RuntimeError("Preserved ref differs from the exact reviewed metadata alias.")
    mapped_new = policy["aliases"][record["newBase"]]
    mapped_candidate = policy["aliases"][record["candidate"]]
    if not ancestor(mapped_new, head) or not ancestor(mapped_candidate, head) or not ancestor(policy["aliases"][policy["delivered"]], head):
        raise RuntimeError("Rewritten integration omits reviewed accepted history.")
    old_exclusive = set(git(ROOT, "rev-list", policy["aliases"][record["oldSource"]], "^" + mapped_new).splitlines())
    if old_exclusive.intersection(git(ROOT, "rev-list", candidate, "^" + mapped_new).splitlines()):
        raise RuntimeError("Recovery source includes discarded history.")
    path = metadata_archive_path(common, policy_id); preservation = metadata_ref_prefix(policy_id)
    if path.exists() or path.is_symlink() or git(ROOT, "for-each-ref", "--format=%(refname)", preservation):
        raise RuntimeError("Partial metadata preservation exists; inspect it before recovery.")
    clean(ROOT); clean(source)
    if (common / "vault-delivery.json").read_bytes() != raw or git(ROOT, "rev-parse", "HEAD") != head or git(source, "rev-parse", "HEAD") != candidate or live_remote_commit() != head or pushed_source_head(source) != candidate:
        raise RuntimeError("Metadata recovery inputs changed during preflight.")
    path.parent.mkdir(exist_ok=True)
    with path.open("xb") as output:
        output.write(raw); output.flush(); os.fsync(output.fileno())
    pairs = [("original/" + old, old) for old in policy["aliases"]] + [("rewritten/" + old, new) for old, new in policy["aliases"].items()] + [("source", candidate)]
    commands = "start\n" + "".join("create " + preservation + name + " " + sha + "\n" for name, sha in pairs) + "prepare\ncommit\n"
    subprocess.run(["git", "-C", str(ROOT), "update-ref", "--stdin"], input=commands, text=True, check=True)
    state["metadataRecoveries"] = [{"version": 1, "stage": "adopted", "policy": policy_id, "source": candidate, "at": time.time()}]
    state.pop("verified", None)  # A metadata alias is never fresh test evidence.
    write_state(common, state)
    validate_reconciled_lineage(common, state, head)
    print("Recovered reviewed metadata mappings; original receipts, both histories and current HEAD preserved. Fresh verification is required.")


def ancestor(old, new):
    result = subprocess.run(["git", "-C", str(ROOT), "merge-base", "--is-ancestor", old, new],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if result.returncode not in (0, 1):
        raise RuntimeError("Cannot validate delivery ancestry.")
    return result.returncode == 0


def remote_identity():
    if git(ROOT, "remote", "get-url", "origin") != APPROVED_REMOTE_URL:
        raise RuntimeError("Reconciliation origin is not the approved repository.")
    if git(ROOT, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}") != "origin/" + BRANCH:
        raise RuntimeError("Reconciliation requires the canonical integration upstream.")


def live_remote_commit():
    remote_identity()
    ref = "refs/heads/" + BRANCH
    rows = subprocess.check_output(["git", "-C", str(ROOT), "ls-remote", "--exit-code", "origin", ref],
                                   text=True, timeout=30).strip().splitlines()
    if len(rows) != 1 or len(rows[0].split()) != 2 or rows[0].split()[1] != ref:
        raise RuntimeError("Cannot validate the exact remote integration ref.")
    return rows[0].split()[0]


def supported_mapping(old, new):
    if not isinstance(old, str) or not isinstance(new, str):
        raise RuntimeError("Unsupported delivered-history reconciliation mapping.")
    policy = SUPPORTED_RECONCILIATIONS.get((old, new))
    if policy is None:
        raise RuntimeError("Unsupported delivered-history reconciliation mapping.")
    tree = policy["tree"]
    for sha in (old, new):
        if git(ROOT, "rev-parse", sha + "^{commit}") != sha or git(ROOT, "rev-parse", sha + "^{tree}") != tree:
            raise RuntimeError("Reconciliation requires the exact supported equal source trees.")
    for sha in (policy["oldCheckout"], policy["oldSource"], policy["candidate"]):
        if git(ROOT, "rev-parse", sha + "^{commit}") != sha:
            raise RuntimeError("Reconciliation requires exact reviewed checkout/source commits.")
    for sha in (policy["oldSource"], policy["candidate"]):
        if git(ROOT, "rev-parse", sha + "^{tree}") != policy["sourceTree"]:
            raise RuntimeError("Old and rewritten reviewed source trees differ.")
    if not ancestor(old, policy["oldCheckout"]) or not ancestor(policy["oldCheckout"], policy["oldSource"]) or not ancestor(new, policy["candidate"]):
        raise RuntimeError("Reviewed source does not preserve the required accepted checkout ancestry.")
    old_exclusive = set(git(ROOT, "rev-list", policy["oldSource"], "^" + new).splitlines())
    if old_exclusive.intersection(git(ROOT, "rev-list", policy["candidate"], "^" + new).splitlines()):
        raise RuntimeError("Reviewed candidate brings old history back into the rewritten lineage.")
    return policy


def ref_prefix(old, new):
    return "refs/vault-delivery/reconciliation/" + old + "-" + new + "/"


def snapshot_path(common, old, new):
    return common / "vault-history-reconciliation" / (old + "-" + new + ".json")


def validate_preserved_record(common, record, delivered):
    if ROOT != APPROVED_CHECKOUT:
        raise RuntimeError("History mapping is restricted to the approved canonical checkout.")
    if record.get("version") != 1 or record.get("stage") != "adopted":
        raise RuntimeError("History reconciliation is incomplete or unsupported.")
    old, new = record.get("oldBase"), record.get("newBase")
    policy = supported_mapping(old, new)
    if any(record.get(key) != value for key, value in policy.items()):
        raise RuntimeError("Reconciliation does not match the original delivered receipt.")
    path = snapshot_path(common, old, new)
    if path.is_symlink() or not path.is_file():
        raise RuntimeError("Original reconciliation receipt was not preserved.")
    raw = path.read_bytes()
    if hashlib.sha256(raw).hexdigest() != record.get("originalReceiptSHA256"):
        raise RuntimeError("Original reconciliation receipt bytes changed.")
    original = json.loads(raw)
    if original.get("delivered", {}).get("commit") != old:
        raise RuntimeError("Original receipt is outside the supported delivered mapping.")
    if delivered.get("commit") == old and original.get("delivered") != delivered:
        raise RuntimeError("Original delivered receipt fields changed.")
    aliases = metadata_aliases(common, read_state(common))
    prefix = ref_prefix(old, new)
    for key, sha in (("old-delivered", old), ("old-checkout", record.get("oldCheckout")),
                     ("old-source", record.get("oldSource")), ("new-base", new), ("candidate", record.get("candidate"))):
        if not sha or git(ROOT, "rev-parse", prefix + key) != aliases.get(sha, sha):
            raise RuntimeError("A preserved reconciliation ref changed or is missing.")
    remote_identity()
    return aliases.get(new, new)


def validate_reconciled_lineage(common, state, sha):
    previous = state.get("delivered", {})
    records = state.get("historyReconciliations", [])
    if not isinstance(records, list) or len(records) != 1 or not isinstance(records[0], dict):
        raise RuntimeError("History reconciliation is incomplete or unsupported.")
    record = records[0]
    new = validate_preserved_record(common, record, previous)
    aliases = metadata_aliases(common, state)
    if not ancestor(new, sha) or not ancestor(aliases.get(record["candidate"], record["candidate"]), sha):
        raise RuntimeError("Delivery is outside the reconciled canonical lineage.")
    old_exclusive = set(git(ROOT, "rev-list", aliases.get(record["oldSource"], record["oldSource"]), "^" + new).splitlines())
    if old_exclusive.intersection(git(ROOT, "rev-list", sha, "^" + new).splitlines()):
        raise RuntimeError("Delivery brings discarded old history into the rewritten lineage.")
    return record


def reconciliation_allows_launch(common, state, sha):
    if not validate_reconciled_lineage(common, state, sha):
        return False
    if live_remote_commit() != sha:
        raise RuntimeError("The actual remote integration ref does not equal the verified delivery HEAD.")
    return True


def reconcile_history(common, source, old, new):
    # This explicit owner-approved command is the only history replacement path.
    # It never pushes, verifies, launches, or substitutes a new delivered receipt.
    source = Path(source).resolve()
    if ROOT != APPROVED_CHECKOUT:
        raise RuntimeError("Reconciliation is restricted to the approved canonical checkout.")
    clean(ROOT)
    clean(source)
    source_common = (source / git(source, "rev-parse", "--git-common-dir")).resolve()
    if source_common != common:
        raise RuntimeError("Reconciliation source must be in this same repository.")
    policy = supported_mapping(old, new)
    state = read_state(common)
    if state.get("delivered", {}).get("commit") != old:
        raise RuntimeError("The original delivered commit does not match the supported mapping.")
    if state.get("historyReconciliations"):
        raise RuntimeError("An existing reconciliation must be inspected; it cannot be overwritten or replayed.")
    before = git(ROOT, "rev-parse", "HEAD")
    candidate = git(source, "rev-parse", "HEAD")
    if before != policy["oldCheckout"] or candidate != policy["candidate"]:
        raise RuntimeError("Checkout/source differs from the exact reviewed commits; preserve and review new work first.")
    if git(ROOT, "rev-parse", "@{upstream}") != new or live_remote_commit() != new:
        raise RuntimeError("The tracking and actual remote integration refs must equal the approved rewritten base.")
    clean(ROOT)
    clean(source)
    if git(ROOT, "rev-parse", "HEAD") != before or git(source, "rev-parse", "HEAD") != candidate:
        raise RuntimeError("Source/delivery changed during preflight; no reconciliation started.")
    path = snapshot_path(common, old, new)
    if path.exists() or path.is_symlink():
        raise RuntimeError("Original receipt archive already exists; inspect partial reconciliation before retrying.")
    prefix = ref_prefix(old, new)
    if git(ROOT, "for-each-ref", "--format=%(refname)", prefix):
        raise RuntimeError("Preservation refs already exist; inspect partial reconciliation before retrying.")
    raw = (common / "vault-delivery.json").read_bytes()
    path.parent.mkdir(exist_ok=True)
    with path.open("xb") as output:
        output.write(raw)
        output.flush()
        os.fsync(output.fileno())
    commands = "start\n" + "".join("create " + prefix + key + " " + value + "\n" for key, value in
        (("old-delivered", old), ("old-checkout", before), ("old-source", policy["oldSource"]),
         ("new-base", new), ("candidate", candidate))) + "prepare\ncommit\n"
    subprocess.run(["git", "-C", str(ROOT), "update-ref", "--stdin"], input=commands, text=True, check=True)
    record = {"version": 1, "stage": "prepared", "oldBase": old, "newBase": new, **policy,
              "originalReceiptSHA256": hashlib.sha256(raw).hexdigest(),
              "at": time.time()}
    state["historyReconciliations"] = [record]
    state.pop("verified", None)  # No verification or launch is carried across rewritten commit identities.
    write_state(common, state)
    # Old HEAD and exact original receipt are already preserved. This is the
    # narrowly authorized replacement of an equal accepted base, never a reset
    # to an arbitrary task/sibling ref. New work is integrated by a normal merge.
    clean(ROOT)
    clean(source)
    if git(ROOT, "rev-parse", "HEAD") != before or git(source, "rev-parse", "HEAD") != candidate:
        raise RuntimeError("Source/delivery changed after preservation; reconciliation held before adoption.")
    subprocess.run(["git", "-C", str(ROOT), "reset", "--keep", new], check=True)
    subprocess.run(["git", "-C", str(ROOT), "merge", "--ff-only", candidate], check=True)
    clean(ROOT)
    if git(ROOT, "rev-parse", "HEAD") != candidate or git(source, "rev-parse", "HEAD") != candidate:
        raise RuntimeError("Source/delivery changed during reconciliation; no adoption receipt written.")
    if live_remote_commit() != new:
        raise RuntimeError("Remote base changed during reconciliation; no adoption receipt written.")
    record["stage"] = "adopted"
    write_state(common, state)
    print(f"Reconciled {old} -> {new}; integrated {candidate}. Original receipt and old refs preserved. Run normal mini1 verify, normal push, then controller launch.")


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
    records = state.get("historyReconciliations", [])
    if not isinstance(records, list) or any(not isinstance(record, dict) or
           record.get("version") != 1 or record.get("stage") != "adopted" for record in records):
        raise RuntimeError("History reconciliation is incomplete or unsupported; delivery is held.")
    if state.get("verified", {}).get("commit") != sha:
        raise RuntimeError("This delivery commit has not passed remote verification. Run vault-delivery verify.")
    if git(ROOT, "rev-parse", "@{upstream}") != sha:
        raise RuntimeError("Push the verified delivery branch before launching.")
    previous = state.get("delivered", {}).get("commit")
    mapped_previous = any(record.get("oldBase") == previous for record in records)
    if records:
        if not reconciliation_allows_launch(common, state, sha):
            raise RuntimeError("Delivery has no valid preserved history reconciliation.")
    effective_previous = metadata_aliases(common, state).get(previous, previous)
    if previous and not mapped_previous and not ancestor(effective_previous, sha):
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
    state = read_state(common)
    if state.get("historyReconciliations"):
        record = validate_reconciled_lineage(common, state, git(ROOT, "rev-parse", "HEAD"))
        aliases = metadata_aliases(common, state)
        base = aliases.get(record["newBase"], record["newBase"])
        old_exclusive = set(git(ROOT, "rev-list", aliases.get(record["oldSource"], record["oldSource"]), "^" + base).splitlines())
        if old_exclusive.intersection(git(ROOT, "rev-list", sha, "^" + base).splitlines()):
            raise RuntimeError("Integration would bring discarded old history into the rewritten lineage.")
    subprocess.run(["git", "-C", str(ROOT), "merge", "--no-edit", sha], check=True)
    print(f"Integrated {sha}; verify the combined delivery commit on mini1 before launch.")


def remote_command(host, account, script):
    if host not in ("mini1", "mini2"):
        raise RuntimeError("Unsupported verification host.")
    if account is not None:
        if host != "mini2" or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.-]*", account) or account == "root":
            raise RuntimeError("Selected account must be a nonroot Mini2 account name.")
        script = shlex.join(["/usr/bin/sudo", "-n", "-H", "-u", account, "/bin/sh", "-c", script])
    return ["ssh", "mini" if host == "mini1" else host, script]


def guarded_remote_script(guard, operation):
    # Group semicolon-separated operations so a failed guard cannot skip only
    # their first command and then continue into mkdir/tar/rsync.
    return guard + " && { " + operation + "; }"


def validate_export_target(home, uid):
    import os
    import stat
    from pathlib import Path
    parent = Path(home) / "vault-delivery"
    for target in (parent, parent / "macosBlocker"):
        if os.path.lexists(target):
            metadata = target.lstat()
            if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != uid:
                raise RuntimeError("Verification export target must be a nonsymlink directory owned by selected UID: " + str(target))
        bare_repository = (target / "HEAD").is_file() and (target / "config").is_file() and (target / "objects").is_dir() and (target / "refs").is_dir()
        if os.path.lexists(target / ".git") or bare_repository:
            raise RuntimeError("Verification export target contains Git metadata; no operation performed: " + str(target))


def remote_preflight_script(account, runtime_prefix, node_executable, playwright_module, browser_executable, expected=None):
    options = {"account": account, "runtimePrefix": runtime_prefix, "node": node_executable,
               "playwrightModule": playwright_module, "browser": browser_executable, "expected": expected}
    # Run this before the archive and again in the same shell as every operation.
    # sudo -H supplies the selected HOME; never substitute the SSH user's HOME.
    code = "import json, os, pwd, sys\n" + inspect.getsource(validate_export_target) + """
options = json.loads(sys.argv[1])
user = pwd.getpwuid(os.getuid())
requested = pwd.getpwnam(options['account']) if options['account'] else user
home = os.environ.get('HOME')
if user.pw_uid == 0 or user.pw_name != requested.pw_name or user.pw_uid != requested.pw_uid or home != requested.pw_dir:
    raise SystemExit('Verification account/UID/HOME mismatch; no operation performed.')
validate_export_target(home, user.pw_uid)
tools = {
    'node': options['node'] or home + '/.local/node/bin/node',
    'playwrightModule': options['playwrightModule'] or home + '/agentic-tooling-test-env/lib/python3.14/site-packages/playwright/driver/package/index.mjs',
    'browser': options['browser'] or home + '/chrome-testing/chrome-mac-x64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing',
}
for key, value in tools.items():
    mode = os.R_OK if key == 'playwrightModule' else os.R_OK | os.X_OK
    if not os.path.isabs(value) or not os.path.isfile(value) or not os.access(value, mode):
        raise SystemExit('Verification runtime is unavailable to selected account: ' + key)
prefix = options['runtimePrefix']
if prefix and (not os.path.isabs(prefix) or not os.path.isdir(prefix) or not os.access(prefix, os.R_OK | os.X_OK)):
    raise SystemExit('Verification runtime prefix is unavailable to selected account.')
identity = {'account':user.pw_name, 'uid':user.pw_uid, 'home':home, 'uiRuntime':tools}
if options['expected'] is not None:
    if identity != options['expected']:
        raise SystemExit('Verification identity/runtime changed; no operation performed.')
else:
    print(json.dumps(identity))
"""
    return shlex.join(["/usr/bin/python3", "-c", code, json.dumps(options)])


def export_archive(sha):
    return subprocess.Popen(["git", "-C", str(ROOT), "archive", sha], stdout=subprocess.PIPE)


def verify(common, host="mini1", runtime_prefix=None, account=None, node_executable=None,
           playwright_module=None, browser_executable=None, jobs=None):
    if jobs is not None and (type(jobs) is not int or jobs < 1):
        raise RuntimeError("Verification jobs must be a positive integer.")
    clean(ROOT)
    sha = git(ROOT, "rev-parse", "HEAD")
    state = read_state(common)
    if state.get("historyReconciliations"):
        validate_reconciled_lineage(common, state, sha)
    preflight = remote_preflight_script(account, runtime_prefix, node_executable, playwright_module, browser_executable)
    result = subprocess.run(remote_command(host, account, preflight), check=True, capture_output=True, text=True, timeout=30)
    try:
        identity = json.loads(result.stdout)
        if (not isinstance(identity, dict) or not isinstance(identity.get("account"), str)
                or type(identity.get("uid")) is not int or identity["uid"] <= 0
                or not isinstance(identity.get("home"), str) or not Path(identity["home"]).is_absolute()
                or not identity["account"] or identity["account"] == "root"
                or account is not None and identity["account"] != account
                or not isinstance(identity.get("uiRuntime"), dict)
                or set(identity["uiRuntime"]) != {"node", "playwrightModule", "browser"}
                or any(not isinstance(value, str) or not Path(value).is_absolute()
                       for value in identity["uiRuntime"].values())):
            raise ValueError("Invalid verification identity")
    except (ValueError, TypeError):
        raise RuntimeError("Cannot validate selected verification identity; no export performed.")
    guard = remote_preflight_script(account, runtime_prefix, node_executable, playwright_module, browser_executable, identity)
    # Only committed files cross hosts. Keep the selected account's build cache,
    # but remove retired source files from its dedicated verification copy.
    archive = export_archive(sha)
    transfer = 'set -eu; mkdir -p "$HOME/vault-delivery"; vault_stage=$(mktemp -d "$HOME/vault-delivery/snapshot.XXXXXX"); trap \'rm -rf "$vault_stage"\' EXIT; tar -xf - -C "$vault_stage"; mkdir -p "$HOME/vault-delivery/macosBlocker"; rsync -a --delete --exclude=.build "$vault_stage/" "$HOME/vault-delivery/macosBlocker/"'
    try:
        subprocess.run(remote_command(host, account, guarded_remote_script(guard, transfer)), stdin=archive.stdout, check=True)
    finally:
        archive.stdout.close()
        if archive.wait():
            raise RuntimeError("Could not export the delivery commit.")
    node = shlex.quote(identity["uiRuntime"]["node"])
    checks = [
        "python3 scripts/development/test-vault-delivery.py && python3 scripts/development/test-history-reconciliation.py && python3 scripts/development/test-metadata-recovery.py",
        "bash -n run-mac-vault.sh scripts/development/launch-mac-vault-build.sh",
        "swift build --product MacBlockerPanel",
        node + " classifier/Tests/WebUI/autosave.mjs",
        'UI_TEST_SCRIPT=classifier/Tests/WebUI/dropdown-layout.js UI_TEST_EXPRESSION="runDropdownLayoutTests()" ' + node + ' classifier/Tests/WebUI/autosave.mjs',
    ]
    if jobs is not None:
        checks[2] += " -j " + str(jobs)
    values = {"UI_PLAYWRIGHT_MODULE": identity["uiRuntime"]["playwrightModule"],
              "UI_BROWSER_EXECUTABLE": identity["uiRuntime"]["browser"]}
    if runtime_prefix:
        values.update({"VAULT_LLAMA_PREFIX": runtime_prefix, "HOMEBREW_PREFIX": runtime_prefix,
                       "PKG_CONFIG_PATH": runtime_prefix + "/lib/pkgconfig"})
        checks[2] += " -Xlinker -rpath -Xlinker " + shlex.quote(runtime_prefix + "/lib")
    environment = "export " + " ".join(shlex.quote(key + "=" + value) for key, value in values.items()) + " && "
    for command in checks:
        operation = 'cd "$HOME/vault-delivery/macosBlocker" && ' + environment + command
        subprocess.run(remote_command(host, account, guarded_remote_script(guard, operation)), check=True)
    clean(ROOT)
    if git(ROOT, "rev-parse", "HEAD") != sha:
        raise RuntimeError("Delivery HEAD changed during verification; verify again.")
    state = read_state(common)
    state["verified"] = {"commit": sha, "host": host, "account": identity["account"], "uid": identity["uid"],
                         "home": identity["home"], "exportPath": identity["home"] + "/vault-delivery/macosBlocker",
                         "uiRuntime": identity["uiRuntime"], "at": time.time(), "checks": checks}
    if runtime_prefix:
        state["verified"]["runtimePrefix"] = runtime_prefix
    if jobs is not None:
        state["verified"]["jobs"] = jobs
    write_state(common, state)
    print(f"Verified {sha} on {host} as {identity['account']} (UID {identity['uid']}).")


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
    global ROOT
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    merge = commands.add_parser("integrate")
    merge.add_argument("--source", required=True)
    verification = commands.add_parser("verify")
    verification.add_argument("--host", choices=["mini1", "mini2"], default="mini1")
    verification.add_argument("--runtime-prefix", help="Absolute pinned llama runtime prefix on the selected test host")
    verification.add_argument("--jobs", type=int, help="Optional positive Swift build job count; default retains Swift's existing behavior")
    verification.add_argument("--account", help="Optional Mini2 account selected through existing SSH and noninteractive sudo")
    verification.add_argument("--node-executable", help="Absolute Node executable readable/executable by the selected remote account")
    verification.add_argument("--playwright-module", help="Absolute existing Playwright JS module readable by the selected remote account")
    verification.add_argument("--browser-executable", help="Absolute existing browser executable readable/executable by the selected remote account")
    start = commands.add_parser("launch")
    start.add_argument("--check", action="store_true")
    commands.add_parser("status")
    reconciliation = commands.add_parser("reconcile-history", help="Explicit supported rewrite reconciliation; requires owner approval before use")
    reconciliation.add_argument("--source", required=True)
    reconciliation.add_argument("--old-base", required=True)
    reconciliation.add_argument("--new-base", required=True)
    recovery = commands.add_parser("recover-metadata-history", help="Adopt only the explicitly owner-approved metadata mapping; then ordinarily integrate its reviewed source")
    recovery.add_argument("--source", required=True)
    recovery.add_argument("--policy", choices=SUPPORTED_METADATA_RECOVERIES, required=True)
    args = parser.parse_args()
    if args.command in ("reconcile-history", "recover-metadata-history"):
        source = Path(args.source).resolve()
        clean(source)
        checkout = Path(git(source, "config", "--get", "vault.deliveryCheckout")).resolve()
        if checkout != APPROVED_CHECKOUT:
            raise RuntimeError("Reconciliation is restricted to the approved canonical checkout.")
        source_common = (source / git(source, "rev-parse", "--git-common-dir")).resolve()
        checkout_common = (checkout / git(checkout, "rev-parse", "--git-common-dir")).resolve()
        if source_common != checkout_common:
            raise RuntimeError("Reconciliation cannot route to another repository.")
        ROOT = checkout  # Only this explicit command may bootstrap from a reviewed offline controller.
    common = context()
    with (common / "vault-delivery.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("Another integration, verification or delivery is active; retry after it finishes.")
        if args.command == "integrate":
            integrate(common, args.source)
        elif args.command == "verify":
            verify(common, args.host, args.runtime_prefix, args.account,
                   args.node_executable, args.playwright_module, args.browser_executable, args.jobs)
        elif args.command == "launch":
            launch(common, args.check)
        elif args.command == "reconcile-history":
            reconcile_history(common, args.source, args.old_base, args.new_base)
        elif args.command == "recover-metadata-history":
            recover_metadata_history(common, args.source, args.policy)
            integrate(common, args.source)
        else:
            print(json.dumps({"checkout": str(ROOT), "branch": BRANCH, "head": git(ROOT, "rev-parse", "HEAD"), **read_state(common)}, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(f"Delivery stopped: {error}", file=sys.stderr)
        sys.exit(1)
