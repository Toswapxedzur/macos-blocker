# Shared local browser bridge

Vault Classifier, Mac Vault, and the Chromium Vault extension share one local
WebSocket hub at `ws://127.0.0.1:8787` using protocol version 4. The hub is a
loopback coordination channel, not a public network service.
Each participant starts, hosts, or joins this transport automatically while it
runs. There is no user-facing connection switch.

## Authentication and connection

Vault Classifier first attempts to host the fixed loopback address. If the
address is already owned, it joins only after the peer's authenticated v4
`welcome` frame identifies Mac Vault or Vault Classifier as the hub. If that
host disconnects, the remaining desktop app tries to host again instead of
blindly reconnecting.

For every WebSocket connection, the listener sends a fresh random `challenge`.
The peer must send a v4 `hello` containing a HMAC-SHA-256 proof bound to both
its declared program and that challenge. Old v3 peers and unauthenticated
peers are rejected before they can issue a request.

Desktop apps keep the 32-byte per-device proof secret in the macOS Keychain.
The Chromium extension never receives that secret: it asks the registered
`com.adamancia.vault.local_hub` Native Messaging host to answer the challenge.
The native host accepts only its exact extension origin and a code-signed
Chromium-family parent process. The native-host manifest is a template in
`native-host/`; it is intentionally not registered by the app build. Until a
matching signed installer registers it with the current extension ID, the
extension fails closed as disconnected rather than using an unauthenticated
fallback.

The Keychain record is recreated when it is missing or malformed. This is a
bounded local recovery path: the extension holds no copy, so the next native
proof automatically uses the replacement. There is no user-facing rotation
control in this minimal implementation.

This boundary stops an unrelated local process that merely knows port 8787.
It does not contain a compromised Chromium extension, browser, native host, or
same-user malware that can access the relevant Keychain item.

## Bounded routing

The browser path is limited to `bridge-info`, `collection-info`, `diagnostic`,
`collect`, `video-tags`, `video-tags-batch`, and development-only `dev-log`.
The hub owns request correlation, destination routing, a bounded global route
count, and route expiry. A classifier response cannot select a different
browser peer.

The classifier returns only policy identifiers/names and bounded per-video tag
projections. It never sends its full tree, local model prompt, collected corpus,
provider credentials, or Keychain data over the bridge.

## Collection and enforcement

Collection is separately enabled per supported platform. The extension sends
bounded rendered public evidence only when collection is enabled; ads are not
retained. Classifier routes are available automatically whenever a compatible
Vault Classifier peer is present.

A matched policy carries one decision — *suppress* — and its presentation is
fixed by surface, not a per-policy choice. List and feed surfaces (home,
search, sidebar, channel grids, and Shorts cards) are **dimmed**, keeping the
content in place with local reveal/why affordances. Only the actual
watch/playback page is **blocked**, and that block is a hard stop with no
in-page reveal. There is no separate hard-feed-block setting and no page-level
dim.

Fail-open is independent of that decision: a disconnected peer, invalid
message, unavailable classifier, or timeout leaves content visible. The browser
path never hides content it could not positively classify.

## Tests that define the boundary

- `SharedHubBrokerTests`: fixed hub contract, ownership, routing, and failure
  behavior.
- `LocalHubAuthentication` tests: a proof is bound to both program and fresh
  challenge.
- `ConnectionHubProtocolTests`: Mac Vault rejects unauthenticated, stale, and
  invalid peer hellos.
