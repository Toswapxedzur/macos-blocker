# Personal audit and verified-package foundations

This document describes source code that is present for the local portions of
Steps 3–4. It is not a release or deployment guide.

## Personal audit

The optional personal-audit path is intentionally narrow:

1. The user enables local auditing, sets local token limits, and stores a
   Gemini credential in the macOS Keychain.
2. The app queues only a local risk-selected or user-marked candidate. Queueing
   itself sends nothing.
3. The user explicitly presses **Run Gemini** for a candidate. The app validates
   the fixed Gemini adapter, creates a local reservation, then marks it as
   possibly sent immediately before HTTPS begins.
4. The adapter sends one non-streaming, non-stored Interactions request with no
   tools. Browser evidence is delimited as untrusted quoted JSON; policy
   criteria and the bounded taxonomy-leaf menu are separately generated trusted
   local context. A stable evidence digest stays local and is not sent to the
   provider.
5. A response must be completed, bounded, schema-valid, attributable to the
   same candidate/attempt/evidence, and limited to the current policy menu. A
   false-allow suggestion must actually change an active requested dim/block
   policy when re-evaluated locally.
6. Settled provider token use replaces the reservation. In-flight and uncertain
   calls retain their reservation, because a provider may have charged a request
   whose response was lost. Reported thought/other tokens are preserved even if
   they exceed the local reservation.
7. Provider output never automatically trains the local FTRL model. When local
   polishing is enabled, a person must explicitly confirm a current
   policy-changing false allow; that application is one-time and revalidated.
   The confirmation becomes an explicit local training example and triggers a
   deterministic rebuild from the bounded retained corpus. A person can also
   add positive/negative predictable-leaf labels directly in the app and
   choose when to rebuild. Views, clicks, normal corrections, and unconfirmed
   provider output remain non-labels.

The extension, shared local bridge, local state file, diagnostic export, and Vault
server never receive the provider key. The redacted diagnostic copy action
excludes raw evidence, entry/source/audit identifiers, rationales, credentials,
and stable evidence digests.

No live credential, provider test request, search/research tool, server
contribution, or account/group feature is part of this source slice.

## Local model backup

The app can keep private local snapshots of its active seed package, policies,
retained labels, and personal correction layer. It deliberately excludes the
browsing cache, decision ledger, and audit history. Changing backup mode is gated
by a locally stored owner-code verifier in the macOS Keychain; the code itself
is not written to state, a backup, IPC, diagnostics, or a server. A configured
folder is private to the current filesystem and contains no network transport.
Each successful local model rebuild writes a snapshot when the mode is enabled.
Retention is fixed at four snapshots: the latest plus three previous snapshots.
An explicit **Create backup now** action is available for the owner. Backup
failure cannot undo a successfully persisted model rebuild.

## Verified package lifecycle

`PackageManifestValidator` verifies the canonical manifest, payload checksum,
metadata bounds, and Ed25519 signature against a public keyring. Its resulting
`VerifiedModelPackage` is a non-forgeable module capability: the public
coordinator activation API accepts that type rather than an arbitrary seed
package.

`LocalPackageLifecycle` stages verified payloads privately, atomically activates
or rolls back references, retains bounded rollback packages, avoids symlink
traversal, and prunes only unreferenced private package directories. The daily
sync planner is pure scheduling logic; it opens no network connection.

`PackageDistributionClient` is a separately injected, data-only HTTPS boundary
for a future distribution surface. It accepts only a caller-provided HTTPS base
URL and safe channel, uses fixed manifest and payload paths, refuses redirects,
uses a bounded JSON manifest, and sends an optional bounded ETag only as
`If-None-Match`. It verifies the exact Ed25519 manifest before it derives or
requests the payload path, then verifies the payload length, SHA-256 digest,
and seed package again before returning an in-memory candidate. A `304` never
causes a payload request. The client has no embedded endpoint, account,
credential, private key, automatic scheduler, staging, or activation behavior.

After a verified package activation, the local coordinator can perform an
explicit, caller-bounded two-stage cache backfill. First, it refreshes retained
rows newest-first using direct entry evidence only; those rows are marked
`awaitingCausalReplay` and cannot enter personal-audit work. It then rebuilds a
fresh source profile and final results FIFO oldest-first, so each target is
scored before its own source observation is added. Each batch publishes
atomically only after all of its items classify successfully; it preserves cache
order, timestamps, evidence, capacity, and the historical decision ledger. An
interrupted replay is bound to the signed manifest's release sequence and
payload digest, so it cannot resume under another release with the same display
names. A cache/settings/policy mutation restarts both stages rather than using a
partial source profile. Backfill has no implicit idle worker and does not run
merely because a package was activated.

There is deliberately no production public key, configured package endpoint,
automatic download/activation, release wiring, or deployment in this package.
A future distribution phase must supply and review those pieces separately
before any user receives an update.
