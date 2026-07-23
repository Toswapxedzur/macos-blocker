# LLM Assist and provider connections

This document describes the current code contract for optional provider work.
It is not a claim that a provider feature runs automatically.

## Ownership boundary

A **provider profile** is a reusable connection. It contains a provider type,
endpoint/protocol configuration, and an optional non-secret test-model
identifier. It does not select a classifier type, platform, policy, model for
classification, decision weight, or tool priority.

A **classifier type** owns one optional LLM Assist attachment. The attachment
selects exactly one provider profile and one fetched model identifier, plus its
daily output-token allowance, batch size, returned-tag limit, leaf-only
constraint, and explicit tool/API-fallback choices. Changing the provider or
model deactivates the attachment; it never causes background classification.

## Credential and state boundary

Provider credentials are stored by profile ID in the macOS Keychain. The
workspace catalog, WebView snapshot, browser bridge, diagnostics, and
provider-request ledger contain no credential value, headers, prompt, or
response text.

At startup, the app performs bounded cleanup of the two retired secret
representations: an embedded workspace credential and the prior provider
Keychain service. A valid old credential is moved to the current per-profile
Keychain record; malformed, obsolete, and orphaned records are discarded. The
old representation is not re-encoded into local state.

Clearing a credential or deleting its profile removes its current Keychain
record. A credential edit is committed on the password field's normal change
event or when the user explicitly tests the connection; it is never persisted
per keystroke and the WebView does not retain a secret draft.

## Models and network requests

Every classifier attachment must use a fetched model identifier, never a free
text model name.

- Fixed providers fetch their curated model list from the credential-free Vault
  service at launch. The service receives no provider credential.
- Custom, OpenAI-compatible, and Ollama profiles fetch their own list only on
  the explicit user action because the operator controls that endpoint and
  inventory.
- A saved selected model remains editable if a transient catalog request fails.
  Changing a direct provider credential or endpoint clears its transient
  catalog and detaches affected classifier attachments before another request
  can use the changed connection.

An explicit **Test request** uses a bounded provider-specific health/test
request. It does not send collected browser content. Provider classification
is opt-in: an inactive attachment may be run manually, while activation
processes only eligible creators sequentially and stops before the next request
when disabled or the daily allowance is exhausted.

## Tools and external platform data

An LLM attachment may opt into a matching platform-data tool. Native code
chooses at most one ready matching profile deterministically; the model cannot
choose credentials, arbitrary URLs, arbitrary identifiers, or a different
platform profile. Tool calls and results are bounded and retained only for the
one in-memory exchange. When no ready matching tool exists, classification
continues without one.

## Tests that define the boundary

- `WorkspaceAssetsTests`: catalog reconciliation, provider profile validation,
  Keychain-only credential persistence, and legacy-state cleanup.
- `ProviderTestProtocolTests`: provider test/classification request grammar,
  bounded tools, and fixed-versus-direct model-catalog routing.
- `VaultServiceEndpointTests`: validated loopback development and HTTPS public
  catalog endpoints.
