# Shared local browser bridge

Mac Vault, its Classifier component, and the Chromium Vault extension share one
local WebSocket hub at `ws://127.0.0.1:8787` (development builds:
`ws://127.0.0.1:18787`) using protocol version 4. The hub is a loopback
coordination channel, not a public network service. There is no user-facing
connection switch.

## Authentication and connection

Mac Vault's `ConnectionHub` is the only host. The Classifier never hosts: it
joins Mac Vault's hub as a client peer (program `classifier`, `SharedHubClient`)
and retries after a rejection. The extension joins as program `chrome` / `edge`.

For every WebSocket connection, the listener sends a fresh random `challenge`.
The peer must send a v4 `hello` containing a HMAC-SHA-256 proof bound to both
its declared program and that challenge. Old v3 peers and unauthenticated
peers are rejected before they can issue a request.

The 32-byte per-device proof secret is a file readable only by the user (mode
0600, `local-hub-secret-v4` in the Classifier's application-support folder), so
unsigned development builds start without a Keychain prompt. The Chromium
extension never receives that secret: it asks the registered
`com.adamancia.vault.local_hub` Native Messaging host to answer the challenge.
The native host accepts only its exact extension origin and a code-signed
Chromium-family parent process. Until a matching native host is registered for
the current extension ID, the extension fails closed as disconnected rather
than using an unauthenticated fallback.

The secret is recreated when it is missing or malformed; the extension holds no
copy, so the next native proof uses the replacement.

This boundary stops an unrelated local process that merely knows the port. It
does not contain a compromised Chromium extension, browser, native host, or
same-user malware that can read the user's files.

## Bounded routing

The browser→classifier path is limited to `bridge-info`, `collection-info`,
`diagnostic`, `collect`, `video-tags`, `video-tags-batch`, `classifier-taxonomy`,
`submit-correction` and development-only `dev-log`; `activity-record` and
`activity-settings` go to Mac Vault (the extension's `operations` list and the
hub's allowlists must agree).
The hub owns request correlation, destination routing, a bounded global route
count, and route expiry. A classifier response cannot select a different
browser peer.

The classifier returns only policy identifiers/names and bounded per-video tag
projections. It never sends its full tree, local model prompt, collected corpus,
provider credentials, or secrets over the bridge.

## Collection and enforcement

Collection is separately enabled per supported platform. The extension sends
bounded rendered public evidence only when collection is enabled; ads are not
retained. Classifier routes are available whenever the Classifier peer is present.

The Classifier only tags. What happens to tagged content is the extension's
decision alone — its groups' tag-filter lines (hide or black out a card's
thumbnail, cover the watch page) and custom rules (the "items" event carries each
item's tags and whether the Classifier answered yet).

Untagged content stays visible: a disconnected peer, invalid message,
unavailable Classifier, or timeout hides nothing, unless a group opted into
covering a watch page until it is tagged.

## Tests that define the boundary

- `SharedHubBrokerTests`: fixed hub contract, ownership, routing, and failure
  behavior.
- `LocalHubAuthentication` tests: a proof is bound to both program and fresh
  challenge.
- `ConnectionHubProtocolTests`: Mac Vault rejects unauthenticated, stale, and
  invalid peer hellos.
