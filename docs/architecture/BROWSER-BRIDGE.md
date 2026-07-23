# Shared local browser bridge

Vault Classifier, Mac Vault, and the Chromium Vault extension share one local
WebSocket hub at `ws://127.0.0.1:8787` using protocol version 4. The hub is a
loopback coordination channel, not a public network service.

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

The browser path is limited to `bridge-info`, `collection-info`, `collect`,
`classify`, and `correct`. The hub owns request correlation, destination
routing, a bounded global route count, and route expiry. A classifier response
cannot select a different browser peer.

The classifier returns only the local policy identifiers/names, decisions, and
correction acknowledgements needed by the extension. It never sends its tree,
model, raw evidence, decision ledger, provider credentials, or Keychain data
over the bridge.

## Collection and enforcement

Collection is separately enabled per supported platform. The extension sends
bounded rendered public evidence only when collection is enabled; ads are not
retained. The extension remains inert until its own Classifier target is
enabled.

Feed decisions use `dim` by default, with local reveal/why affordances. Hard
feed blocking requires the explicit hard-block setting. A disconnected peer,
invalid message, unavailable classifier, or timeout leaves content visible:
the browser path fails open.

## Tests that define the boundary

- `SharedHubBrokerTests`: fixed hub contract, ownership, routing, and failure
  behavior.
- `LocalHubAuthentication` tests: a proof is bound to both program and fresh
  challenge.
- `ConnectionHubProtocolTests`: Mac Vault rejects unauthenticated, stale, and
  invalid peer hellos.
