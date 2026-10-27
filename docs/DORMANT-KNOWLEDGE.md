# Dormant Knowledge and dictionaries

Owner decision, 2026-10-27: make official dictionaries and personal Knowledge dormant
in the Vault app, including add/edit/import/export and their separate research lane,
and disable website dictionary endpoints. Cloud tagging retains its four connections,
per-group model/effort choices, always-enabled model-directed search, taxonomy and
house rules. Human tag corrections and creator tag-count priors remain active.

There is no runtime enable flag, automatic dictionary lookup, contribution upload,
startup version check, Knowledge snapshot, worker/MCP action or native onboarding.
Schema 8 archives retired state fields privately before removing them from active
state; archive failure preserves the original state and aborts migration. Existing
packs and pictures stay on disk, outside all active paths. Prompt policy p5 rejects
old automatic caches while retaining authoritative human corrections.

Recoverable source/tests are in Git history at the parent of this change and in the
hashed `knowledge-dormancy-20261027` archives under `~/Desktop/agentic/artifacts/`.
The exact native-model implementation is separately archived from d80dc8a, and its
GGUF remains outside production in Mini2's private dormant-models directory. Restoring
these features requires an explicit future source change and fresh verification.

Verification must cover migration preservation/failure, absent UI/tool routes,
unchanged tagging/provider controls, and no dictionary network/store initialization.
Only the owner-selected Mini2 account is used for this campaign. Public distribution
and laptop app execution remain outside this private delivery.
