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

`run-mac-vault.sh` in each local worktree dispatches to this shared controller
when the Git setting exists. The lower-level build script accepts a laptop
delivery only from that checkout with the controller's exact commit token.
Mini1 source exports have no laptop Git setting and can use the build script
for testing normally. Never use the lower-level script to bypass laptop
delivery.

Regression checks (mini1 only):
`python3 scripts/development/test-vault-delivery.py` and
`bash -n run-mac-vault.sh scripts/development/launch-mac-vault-build.sh`.
