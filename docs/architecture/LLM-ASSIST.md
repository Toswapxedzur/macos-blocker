# LLM Assist and provider connections

This document describes the current code contract for optional provider work.
It is not a claim that a provider feature runs automatically.

## Supported profiles

Every profile exposed in the LLM Assist provider picker is ready for its
declared, explicit operation once the user supplies a valid account credential
and any shown connection fields. "Ready" here means the app has a Keychain-only
credential path, a bounded connection test, a model/classification request
grammar (for language models) or platform health/tool route (for platform
data), and regression coverage. It does not guarantee that a provider account,
model, regional availability, quota, or OAuth grant is available to a
particular user.

- **Language models:** OpenAI, DeepSeek, Gemini, Anthropic, Mistral, Cohere,
  Groq, OpenRouter, and local Ollama. **OpenAI-compatible** and **Custom** are
  both explicit HTTPS OpenAI Chat-Completions connections; their owner supplies
  the endpoint and model.
- **Platform data:** YouTube Data, Twitch, Reddit, X, TikTok Display,
  Instagram Graph, and Facebook Graph. They support only explicit connection
  tests and bounded native tool/creator-avatar reads; they are never language
  models and never dispatch automatically.

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

A language-model test succeeds only after a 2xx response matches that
provider's response grammar and contains generated text. An empty or unrelated
JSON envelope is an error, not a green "provider is ready" result. Cohere test,
classification, and tool requests explicitly set `stream: false` because the
native transport accepts one bounded JSON response rather than an SSE stream.

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
