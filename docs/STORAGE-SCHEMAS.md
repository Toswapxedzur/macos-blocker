# Native local storage schemas

Product app versions determine migration retention; schema numbers describe
formats. `classifier/Sources/VaultClassifierCore/StorageSchema.swift` owns the
shared policy/codec. `sync-webui.sh` derives the unbundled Mac/Windows writer
versions from Xcode's marketing version and the Windows project version. Signed
Mac bundles use their own app version; Windows supplies its version to the Swift
worker explicitly. A test runner's bundle version is never a product version.

| Family | Current format | Migration |
| --- | --- | --- |
| Rules/editor/usage | `vault.web-store`, flat schema 3 | Compatible raw alpha dictionary preserves opaque keys; canonical browser sanitizer converts flat scopes. Native writes remain field-surgical. |
| Classifier | `classifier.state`, flat schema 3 | Alpha schemas 0–2 decode once, reconcile effective independent dials, discard retired fields and preserve authored catalog/settings/model identities. |
| Collected entries | `classifier.collected`, envelope schema 1 | Compatible day arrays wrap; dataset/platform/day partitioning remains. |
| Activity | `activity.settings`, `web-icons`, `colors`, `groups`, `watched-facts`, `records.<category>`, envelope schema 1 | Decode compatible alpha settings/maps/arrays fully before atomic wrapping. |
| Linked registry | `hub.clusters`, envelope schema 1 | Current explicit-link array migrates; retired automatic links remain retired. Mac uses its existing UserDefaults key; Windows uses its existing file. |
| Local backups | Classifier payload schema 3 and `classifier.backup-manifest` metadata schema 1 | Share the state decoder/expiry policy. Retention excludes unreadable or unsupported manifests instead of treating them as oldest and deleting them. |
| Local caches | `dictionary.creator-cache`, `dictionary.contribution-ledger`, `provider.model-catalog`, envelope schema 1 | Compatible local data imports; an unsupported contribution ledger also prevents HTTP contributions that could evade deduplication/attempt limits. |

Envelopes contain `storageMetadata` (`format`, `schemaVersion`, `product`,
`writtenByAppVersion`) and `value`. Flat documents keep existing public keys and
add the same metadata, with a matching root `schemaVersion`. This metadata stays
local: it does not alter hub protocol v4, signed package/dictionary formats,
personal import packs, native authentication or provider HTTP payloads. Binary
icons and credentials retain their existing dedicated contracts.

A supported older schema requires a transformation. Keep the preceding product
app major supported; data from app-major 1 may lose transformations at app-major
3 (the earliest allowed boundary) or 4. Current identical formats require no
transformation. Sequential upgrades are supported, skipped majors are not
promised. Compatible unversioned alpha intake expires after the major following
its introduction (Mac 2, Windows 0, browser/Safari 3). Remove expired import code
when increasing the product major, rather than adding indefinite adapters.

All authoritative writers check the existing destination before saving. A newer,
invalid or expired format is preserved, not reset from a fallback/default state.
Late queued Classifier flushes recheck the destination. Activity records refuse
failed writes; group edits return a storage refusal. Unsupported native link
registries refuse edits. Classifier/UI errors and developer storage diagnostics
explain preservation. Successful migrations use atomic saves; failures retain
the previous complete file and retry on next load. Explicit user deletion of
Activity history remains deletion and is not an implicit format reset.

When changing a format, add a schema transformation and fixtures for meaningful
preservation, failure/retry, restart, expiry and future-format protection. Remove
expired transformations at the relevant product major. Tests run on mini1,
including its Windows VM; laptop relaunch is delivery only. No build is published
or relabeled beta by this source implementation.
