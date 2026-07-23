# Personal Audit, backups, and package lifecycle

These are current local capabilities and foundations. They are deliberately
explicit operations: none schedules provider work, package activation, or
backup transport in the background.

## Personal Audit

Personal Audit is separate from LLM Assist. It is a fixed Gemini adapter for
reviewing possible false allows, not a general provider connection or arbitrary
endpoint feature.

1. The user enables local auditing, configures its limits, stores a Gemini API
   key in the macOS Keychain, and enables the separate local-dispatch resource
   permission.
2. The app queues only an eligible local candidate. Queueing sends nothing.
3. The user presses **Run Gemini** for that candidate. The app reserves the
   bounded local budget before starting the non-streaming request.
4. Browser evidence is quoted as untrusted data. Trusted policy context and
   the bounded taxonomy-leaf menu are generated locally; a stable evidence
   digest remains local.
5. A response must be bounded, schema-valid, attributable to the same
   candidate/attempt/evidence, and limited to the current local policy menu.
   A false-allow finding matters only when it changes a current dim/block
   policy decision after local re-evaluation.
6. Provider output never trains a model automatically. A person must explicitly
   confirm a currently policy-changing result before it becomes a local label.

The extension, shared local bridge, workspace state file, diagnostics, and
Vault service never receive the Gemini credential. Redacted diagnostic export
excludes evidence, identifiers, rationales, credentials, and stable evidence
digests.

## Local model backups

An owner-code verifier stored in the macOS Keychain gates an optional local
backup mode. A snapshot contains the active package, policies, explicit local
training corpus, and correction layer; it excludes the activity cache, decision
ledger, and audit history. Snapshots are written only to a user-selected local
folder and retention is the current snapshot plus three prior snapshots. No
backup is uploaded.

## Verified package lifecycle

`PackageManifestValidator` verifies canonical manifest data, payload checksum,
metadata bounds, and an Ed25519 signature against a public keyring. Its
`VerifiedModelPackage` capability is required to activate a coordinator;
arbitrary seed packages cannot bypass that boundary.

`LocalPackageLifecycle` stages verified payloads privately, atomically activates
or rolls back references, retains bounded rollback packages, rejects symlink
traversal, and prunes only unreferenced private package directories. The daily
sync planner is scheduling logic only.

`PackageDistributionClient` is an injected data-only HTTPS boundary. It uses
fixed manifest/payload paths, rejects redirects, validates the signed manifest
before deriving a payload path, and validates the downloaded payload before
returning an in-memory candidate. It has no embedded account, credential,
private key, scheduler, download setting, staging, or activation behavior.

After explicit verified activation, cache backfill is also explicit and
bounded: direct evidence refreshes newest-first, then source profiles and final
results replay FIFO oldest-first. This preserves the no-self/no-future source
prior invariant. Provisional rows cannot enter Personal Audit, and an
interrupted replay is identity-bound to the signed release.

## Tests that define the boundary

- `GeminiPersonalAuditAdapterTests` and `LocalAuditStoreIntegrationTests`:
  request bounds, attribution, conservative budget accounting, and redacted
  diagnostics.
- `LocalModelBackupTests`: private snapshot contents and four-snapshot
  retention.
- `PackageDistributionClientTests`, `CacheBackfillTests`, and
  `ModelIdentityCoordinatorTests`: signed package, safe lifecycle, and causal
  replay behavior.
