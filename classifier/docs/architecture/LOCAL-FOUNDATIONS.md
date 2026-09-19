# Local backups and package lifecycle

These are current local capabilities and foundations. They are deliberately
explicit operations: none schedules provider work, package activation, or
backup transport in the background.

## Local model backups

An owner-code verifier stored in the macOS Keychain gates an optional local
backup mode. A snapshot contains current settings, policies, authored workspace
configuration, collected entries, and per-video LLM stores. Retired classifier
cache, ledger, personal model, and training corpus fields are excluded.
Snapshots are written only to a user-selected local folder and retention is the
current snapshot plus three prior snapshots. No backup is uploaded.

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

## Tests that define the boundary

- `LocalModelBackupTests`: private snapshot contents and four-snapshot
  retention.
- `PackageDistributionClientTests`: signed package and safe distribution
  behavior.
