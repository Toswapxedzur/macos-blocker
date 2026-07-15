# Phase 2 — local YouTube vertical slice

This source-only Phase 2 implementation adds an opt-in Chrome/Edge adapter and a local native-messaging path. It does not register a native-host manifest, modify an installer, change any version, or enable the feature for an extension user.

## Local path

1. The YouTube content adapter reads only values that are visibly rendered on a feed card or a fully opened watch page. It does not use the YouTube Data API.
2. The extension is inert until its local `vaultClassifierSettings.enabled` setting is `true`. When active, it sends a bounded entry payload to the native host; a missing selector, missing host, invalid envelope, stale message, or timeout leaves the card/page visible.
3. The app owns a 256-bit local pairing secret in the macOS Keychain. The host
   and extension use it only for this local path; subsequent native messages
   have a schema version, correlation ID, timestamp, nonce, body hash, and
   HMAC. Both the host and app keep bounded replay windows.
4. The host uses a `0600` Unix-domain socket in the user Application Support directory, checks that the peer UID is the current user, and forwards the request to the visible app. The app owns the classifier/cache/ledger and returns the decision. There is no HTTP listener or public loopback port.
5. Feed decisions default to **dim**, with reveal/why controls. Hard feed blocking requires the explicit `feedHardBlock` local setting. A matching watch page presents a local block surface with reveal/why controls. Revealing reports a local false-dim/false-block correction to the decision ledger.

## Deliberately not installed

`native-host/com.adamancia.vault_classifier.json.template` is only a template. Its executable path and Chrome/Edge extension ID must be supplied by a future signed installer. Do not copy it into a browser native-messaging directory for a production release.

With no registered host, the extension fails open. This is intentional until packaging, stable extension IDs, and the installer are separately authorized.

## Developer checks

```sh
cd /Users/fengyue.john.zhu/Desktop/blockerGroup/vaultClassifier
swift test
swift build

cd /Users/fengyue.john.zhu/Desktop/blockerGroup/customBlocker
./tests/run.sh
```
