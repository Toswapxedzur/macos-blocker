# Shared Mac Vault delivery

Task branches/worktrees remain independent while work is in progress. The
owner's laptop app is always delivered from `integration/local-delivery` in
the checkout registered by the repository's shared `vault.deliveryCheckout`
Git setting. Never choose a branch by timestamp or launch a task build on the
laptop.

The stable laptop command is `~/Desktop/agentic/tooling/bin/vault-delivery`:

1. Commit and push the completed task; keep unfinished work separate.
2. `vault-delivery integrate --source /absolute/path/to/task/macosBlocker`
3. Resolve any merge conflicts in the delivery checkout. Inspect the combined
   diff; run any additional relevant tests on mini1.
4. `vault-delivery verify` exports only the committed combined tree to a
   dedicated mini1 copy and runs the Mac build, autosave/disclosure and
   dropdown/model-picker suites. No tests run on the laptop.
5. Push `integration/local-delivery` normally to its upstream.
6. `vault-delivery launch` closes every old laptop Mac Vault/standalone
   Classifier instance and runs the supported build launcher from the shared
   checkout. This is delivery only; do not verify laptop UI/behavior.

`status` reports the checkout, HEAD, mini1 verification and delivery receipts.
`launch --check` checks readiness without closing/building/launching anything.
All commands share a nonblocking lock in the common Git directory. Launch
requires a clean integration checkout, a mini1 receipt for the exact HEAD,
matching upstream and inclusion of the previously delivered commit. A new
merge invalidates the old verification automatically. Do not edit the receipt
to bypass these gates.

## Explicit supported history reconciliation

An owner-approved rewrite can have equal source trees while changing Git
ancestry. The controller supports only its pinned, reviewed old/new mapping;
ordinary integration and launch never infer equivalence from timestamps or
arbitrary equal trees. `reconcile-history --source <absolute worktree>
--old-base <exact old SHA> --new-base <exact new SHA>` is an explicit adoption
operation requiring owner approval of that mapping. Its source must be a clean
worktree in the same repository, at the exact reviewed candidate; checkout,
origin, upstream and actual remote base are checked before adoption.

Reconciliation preserves the original receipt bytes and five exact refs,
retains the original delivered record, and invalidates verification. It does
not verify, push, launch, publish, or relabel historical evidence. After
adoption, integrate subsequent verified work through ordinary merges, run
normal verification for the exact combined commit, push normally, then launch.
The original archive/ref and rewritten-lineage guards remain active after
later deliveries; launch also checks the actual remote integration ref.

Existing preparation/adoption records and preservation collisions prevent
replay. If a partial operation fails, preserve its archive, refs and receipt
for reviewed recovery; do not delete evidence, edit receipts or reset refs.
Only the explicit reconciliation command may bootstrap from a reviewed
standalone controller into the registered canonical checkout. All ordinary
commands keep the shared-checkout restriction.

## Approved metadata-rewrite recovery

Owner approval on 2026-10-27 permits the exact `metadata-rewrite-20261027` policy.
An external rewrite changed five preserved refs, the prior delivered commit and the
last verified commit while retaining their source trees. The pinned table in the
controller identifies every original/rewritten object and the exact pre-recovery
receipt digest; it never discovers or adopts arbitrary equal trees.

Run the committed, pushed task controller explicitly:

```sh
python3 /absolute/reviewed/task/scripts/development/vault-delivery.py recover-metadata-history \
  --source /absolute/reviewed/task --policy metadata-rewrite-20261027
```

Only this explicit recovery command may bootstrap from that task into the approved
shared checkout. It requires the reviewed integration/upstream/actual remote HEAD,
a clean pushed source descending from the reviewed feature, and only the listed
controller/docs/tests changes after that feature. It verifies original receipt
bytes, original and rewritten objects, all changed refs, accepted ancestry and
excluded old history before mutating anything. Drift, partial preservation or
unlisted source edits stop the operation.

The command creates new preservation refs for both object histories and an exact
archive of the current receipt; original history records and their earlier archive
remain unchanged. It records the explicit adoption through the controller, drops
old verification and ordinarily merges the reviewed task. It never resets a branch,
force-pushes, relabels test evidence or launches an app. Normal exact-commit remote
verification and a normal integration push are required afterward. Future integrate,
verify and launch operations validate this preserved evidence and mapped ancestry.
The original five audit refs are kept at their reviewed rewritten objects; new refs
preserve every original object independently. Do not edit either receipt by hand.

`test-metadata-recovery.py` uses only disposable local Git remotes/receipts on the
selected test host. It checks preservation, fresh verification/push requirements,
wrong trees, changed receipts/remotes/source, dirty worktrees, partial recovery and
audit tampering. It is included in normal controller verification.

When the owner explicitly selects mini2 for a run, use `verify --host mini2`.
If that host uses a pinned source runtime instead of Homebrew, also pass
`--runtime-prefix /absolute/remote/runtime/install`. All checks still run on
the selected host, and the receipt records that host, prefix and exact commit.
The default remains mini1; host selection does not relax the delivery gates.

When the authorized Mini2 test account differs from its SSH login, use
`verify --host mini2 --account john.zhu.alt1`. Every preflight, committed source
export and check uses the existing SSH connection followed by noninteractive
`sudo -n -H -u` for that account. No SSH configuration or account credentials
are changed. The controller validates a nonroot effective account, UID and its
actual home directory before copying source, then rechecks that identity before
each operation. Existing export parent/target paths must be nonsymlink directories
owned by that UID and contain no Git metadata; unsafe/foreign targets are refused
before any cleanup or copy. Export/build files stay in the selected account's
`~/vault-delivery/macosBlocker`; the SSH login's home is not substituted.

If its UI tools are installed at different existing locations, pass absolute
`--node-executable`, `--playwright-module` and `--browser-executable` paths.
The controller checks readability/executability as the selected account and
passes the module/browser through the UI harness's existing supported variables.
It does not install dependencies, download a browser or launch a visible browser.
Without overrides, the existing home-based Mini1 runtime paths remain the default.
Successful receipts record host, effective account/UID/home, export directory,
UI runtime paths, optional llama runtime prefix and exact tested commit. A failed
identity/runtime check cannot write a new verification receipt. These checks do
not prove native Aqua permissions or live app behavior; those remain separate
acceptance steps. The five verification steps are screen-free builds and isolated
headless UI suites under the selected effective UID/home. Noninteractive sudo is
not proof of an Aqua/audit desktop session or actual desktop input. If a future
suite needs GUI bootstrap, stop for a separately reviewed selected-user route;
never borrow the SSH login's GUI session. Optional `--jobs 2` bounds Swift build
parallelism on a constrained host. It must be a positive integer; omission
preserves the existing Swift default. Only the build command receives this limit,
and the successful receipt records the actual checks and selected job count. Explicit owner host selections take precedence for a run.

`run-mac-vault.sh` in each local worktree dispatches to this shared controller
when the Git setting exists. The lower-level build script accepts a laptop
delivery only from that checkout with the controller's exact commit token.
Mini1 source exports have no laptop Git setting and can use the build script
for testing normally. Never use the lower-level script to bypass laptop
delivery.

Regression checks (mini1 by default, or the explicitly owner-selected host):
`python3 scripts/development/test-vault-delivery.py`,
`python3 scripts/development/test-history-reconciliation.py`,
`python3 scripts/development/test-metadata-recovery.py`, and
`bash -n run-mac-vault.sh scripts/development/launch-mac-vault-build.sh`.

Safari pairing additionally requires a current Apple profile selected with
`MAC_VAULT_APP_PROVISIONING_PROFILE`. It must authorize
`com.adamancia.vault.mac.development` and
`group.com.adamancia.vault.development` under the same developer team used to
sign Safari Vault. With that explicit profile, the supported launcher wraps
the built executable in `.build/.../Mac Vault Development.app`, embeds the
profile, and signs the outer app with its shared group entitlement. It still
executes `MacBlockerPanel` inside the verified checkout, preserving the delivery
controller's process and provenance checks. Mac Vault remains unsandboxed for
its application controls.

Without a selected profile, the launcher retains its ordinary signed
development binary and reports Safari pairing unavailable. It does not invent
an App Group location or publish a secret outside the authorized container.
Production signing accepts a production profile through the same environment
variable; see [App Group signing](../signing/README.md). On mini1, metadata and
launcher fixtures are testable without credentials. Apple-authorized App Group
execution and live Safari acceptance require valid installed signing material
and remain separate verification steps.
