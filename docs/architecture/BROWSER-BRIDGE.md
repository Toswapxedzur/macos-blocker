# Shared local browser bridge

Vault Classifier, Mac Vault, and the Vault extension share one local
WebSocket hub at `ws://127.0.0.1:8787` using protocol version 3. This is a
local coordination channel, not a public network service or a Native Messaging
host.

## Host election and connection

Vault Classifier first attempts to host the fixed loopback address. If the
address is already owned, it joins only after the peer's protocol-v3 `welcome`
frame identifies Mac Vault or Vault Classifier as the hub. If that host
disconnects, the remaining desktop app tries to host again instead of blindly
reconnecting.

The listener rejects non-loopback peers before the WebSocket handshake. A
connecting peer must send a bounded protocol-versioned `hello` identifying its
program before it can issue requests. This is protocol identity validation;
the current bridge does not use the retired 64-character pairing-key setup.

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

- `SharedHubBrokerTests`: local hub ownership, protocol identity, routing, and
  failure behavior.
- `NativeProtocol` and `SharedBrowserBridge`: bounded request/response schema
  and compatibility rules.
