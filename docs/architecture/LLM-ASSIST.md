# LLM Assist and provider connections

This document describes the current code contract for optional provider work.
It is not a claim that a provider feature runs automatically.

## Supported profiles

Every profile exposed in the LLM Assist provider picker is ready for its
declared, explicit operation once the user supplies a valid account credential
and any shown connection fields. "Ready" here means the app has an ordinary
saved credential field, a bounded connection test, a model/classification request
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

The type also retains its selected provider while no model has been attached
yet. This is only an editor choice: it cannot activate a provider, dispatch a
request, or change an existing provider/model attachment.

## Credential and state boundary

Provider credentials are ordinary visible text fields saved in each local
workspace profile. They are included in the local WebView state so the field
can display and edit its current value. They do not enter the browser bridge,
diagnostics, or provider-request ledger.

At startup, the app copies any valid value from the retired provider-Keychain
services into its profile field and deletes the old Keychain item. An old
embedded credential record is decoded directly into the same field. This is a
one-way cleanup: provider credentials no longer use Keychain storage.

An edit saves on the field's normal change event or when the user explicitly
tests the connection. Clearing the normal text field and committing the edit
clears the saved value; deleting a profile removes the value with the profile.

## Models and network requests

Every classifier attachment must use a probed model identifier, never a free
text model name.

- Every LLM provider starts with an empty model list. Its explicit **Probe**
  sends the saved local credential to that selected provider's documented
  model-list endpoint. There is no Vault-service model catalog. Provider-specific
  paths, authentication, pagination limits, and response envelopes are handled
  by the native request protocol.
- The list is a bounded local cache of model identifiers only. A successful
  later Probe replaces it; a failed Probe leaves the previous successful list
  in place. It survives an app relaunch but is not written into the workspace
  catalog and never contains credentials, endpoints, or request/response data.
- A saved selected model remains visible if the process has no cached list.
  Editing provider fields does not invalidate the cached list or detach an
  affected classifier attachment.

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

- `WorkspaceAssetsTests`: catalog reconciliation, plain provider-credential
  persistence, profile validation, and legacy-state cleanup.
- `ProviderTestProtocolTests`: provider test/classification request grammar,
  bounded tools, and direct provider model-list routing.
- `ProviderModelCatalogStoreTests`: restart persistence and profile-removal
  cleanup for the bounded model-identifier cache.
