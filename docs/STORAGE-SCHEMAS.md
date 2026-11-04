# Native local storage schemas

Schema numbers describe formats independently of product versions.
`classifier/Sources/VaultClassifierCore/StorageSchema.swift` owns the
shared policy/codec. `sync-webui.sh` derives the unbundled Mac/Windows writer
versions from Xcode's marketing version and the Windows project version. Signed
Mac bundles use their own app version; Windows supplies its version to the Swift
worker explicitly. A test runner's bundle version is never a product version.

| Family | Current format | Migration |
| --- | --- | --- |
| Rules/editor/usage | `vault.web-store`, flat schema 7 | Compatible raw alpha dictionary preserves opaque keys; canonical browser sanitizer converts flat scopes and retires the saved rule AI model selection. Native writes remain field-surgical. |
| Classifier | `classifier.state`, flat schema 9 | Older compatible alpha states reconcile cloud groups and archive retired Knowledge/dictionary fields before dropping them from active state. |
| Collected entries | `classifier.collected`, envelope schema 1 | Compatible day arrays wrap; dataset/platform/day partitioning remains. |
| Activity | `activity.settings`, `web-icons`, `colors`, `groups`, `watched-facts`, `records.<category>`, envelope schema 1 | Decode compatible alpha settings/maps/arrays fully before atomic wrapping. |
| Linked registry | `hub.clusters`, envelope schema 3 (Mac) | Current explicit-link array migrates; retired automatic links remain retired. Mac uses its existing UserDefaults key; Windows uses its existing file. |
| Local backups | Classifier payload schema 9 and `classifier.backup-manifest` metadata schema 1 | Share the state decoder and storage policy. Retention excludes unreadable or unsupported manifests instead of treating them as oldest and deleting them. ChatGPT credentials are not part of the state payload. |
| Local caches | `provider.model-catalog`, envelope schema 1 | Compatible local model-list cache imports. Dictionary caches/ledgers are dormant and never read by the current app. |

Envelopes contain `storageMetadata` (`format`, `schemaVersion`, `product`,
`writtenByAppVersion`) and `value`. Flat documents keep existing public keys and
add the same metadata, with a matching root `schemaVersion`. This metadata stays
local: it does not alter hub protocol v4, signed package/dictionary formats,
personal import packs, native authentication or provider HTTP payloads. Binary
icons and credentials retain their existing dedicated contracts.

The optional ChatGPT connection uses a separate private `ChatGPT/` directory.
Credential, device-request ledger and first-plan-use acknowledgement documents
have schema 1; unsupported versions are preserved and refused. The host ID and
issued OAuth registration are opaque scalar records. Mac permissions are
0700/0600; Windows additionally uses current-user DPAPI. No OAuth token is exposed
in classifier snapshots, hub messages, request logs or Classifier state backups.

A supported older schema requires a transformation. Version numbers do not
expire a transformation. The first public Beta 1 build is the compatibility
baseline; each later release must directly import every public version from
the preceding rolling 30 days. See `misc/compatibility/INVENTORY.md` for the
release matrix and evidence gate. Older alpha input remains best effort.

All authoritative writers check the existing destination before saving. A newer
or invalid format is preserved, not reset from a fallback/default state.
Late queued Classifier flushes recheck the destination. Activity records refuse
failed writes; group edits return a storage refusal. Unsupported native link
registries refuse edits. Classifier/UI errors and developer storage diagnostics
explain preservation. Successful migrations use atomic saves; failures retain
the previous complete file and retry on next load. Explicit user deletion of
Activity history remains deletion and is not an implicit format reset.

When changing a format, add a schema transformation and fixtures for meaningful
preservation, failure/retry, restart and future-format protection. Remove a
transformation only after no protected public release needs it. All development
tests run on Mini2, including its Windows VM. No build is published by this
source implementation.

Schema 8 makes official dictionaries, personal Knowledge and their separate research lane dormant. Before rewriting an older state, `LocalStateFile.load` preserves only retired fields in a private content-addressed `dormant/knowledge-<sha256>.json` sidecar. Archive failure aborts loading/migration with the original state intact. Current state never decodes those fields. Existing packs/pictures are retained on disk and never read by the classifier. Automatic cache currency advances to prompt p5; human corrections remain authoritative.

Schema 7 removes the retired one-model-per-group `ruleAI` selection. Custom groups retain the optional daily cap, saved prompt and saved context; every `v.ai` call names its model and reasoning effort. Compatible older web stores retain groups/state/usage. The separate `rule-ai-usage.json` ledger is schema 1, UTC-day scoped; atomic private reservations contain linked member IDs only. Link/unlink and restart do not reset counted requests. Corrupt/newer ledgers refuse calls without resetting usage. Named conversation transcripts use one versioned local file per name, shared across all rules on a device; group deletion leaves them intact. An explicit `v.ai({op:"delete",conversation:"name"})` deletes a transcript. The total local limit defaults to 1 GB, can be changed in Settings, and evicts the least recently used transcripts. Earlier private per-member files are imported, preserving distinct same-name histories under aliases. Pending AI requests and responses are not replayed.

Web schema6 adds a group-owned `cbRuleRecords` version1 document. Mac Vault
transacts it under the existing web-store lock using the canonical browser
record module; malformed/future record versions are preserved and refused
without stopping ordinary rules. Group deletion prunes its namespace. Web
schema6 also accepts the browser attachment document version2 as opaque web
state; native Mac application rules have no browser content surface. Browser
and Safari attachment ownership and format are documented in canonical browser
`docs/STORAGE-SCHEMAS.md`.
