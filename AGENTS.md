# Mac Vault delivery

Read the project instructions at
`/Users/fengyue.john.zhu/Desktop/programme/apps/blockerGroup/AGENTS.md` and its
project-memory entry before work, including from isolated worktrees.

All testing runs on mini1. Completed changes must be integrated into the shared
`integration/local-delivery` branch, verified there on mini1, and pushed before
the laptop app is relaunched. Use
`~/Desktop/agentic/tooling/bin/vault-delivery`; read
`scripts/development/README.md`. Task worktrees are for implementation and
mini1 testing; their laptop launchers route to the shared delivery checkout.
Do not run task binaries or the lower-level build script on the laptop, edit
verification receipts, force-push, or replace the integration branch with a
newer sibling branch. Reconcile completed accepted changes through ordinary
merges; preserve unfinished and unrelated work.
