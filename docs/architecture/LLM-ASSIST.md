# LLM Assist and provider connections

This document describes the current code contract for optional provider work.
It is not a claim that a provider feature runs automatically.

## Supported profiles

Every profile exposed in the LLM Assist provider picker is ready for its
declared, explicit operation once the user supplies a valid account credential
and any shown connection fields. "Ready" here means the app has an ordinary
saved credential field, a bounded connection test, a model/classification request
grammar (for language models) or platform health/evidence route (for platform
data), and regression coverage. It does not guarantee that a provider account,
model, regional availability, quota, or OAuth grant is available to a
particular user.

- **Language models:** OpenAI, DeepSeek, Gemini, Anthropic, Mistral, Cohere,
  Groq, OpenRouter, and local Ollama. **OpenAI-compatible** and **Custom** are
  both explicit HTTPS OpenAI Chat-Completions connections; their owner supplies
  the endpoint and model.
- **Platform data:** YouTube Data, Twitch, Reddit, X, TikTok Display,
  Instagram Graph, and Facebook Graph. They support explicit connection tests
  and bounded official evidence where their access scope can read the
  collected creator; they are never language models.

## Ownership boundary

A **provider profile** is a reusable connection. It contains a provider type,
endpoint/protocol configuration, and an optional non-secret test-model
identifier. It does not select a classifier type, platform, policy, model for
classification, or decision weight.

A **classifier type** owns one optional LLM Assist attachment. The attachment
selects exactly one provider profile and one fetched model identifier, plus its
daily output-token allowance, **per-request max-token** cap (default 4,096),
optional **extra direction**, classification pace, batch size, returned-tag
limit, leaf-only constraint, and optional provider-native web search. A ready
matching official platform API connection is required for platforms with that
evidence path. TikTok, Instagram, and Bilibili deliberately make no
app-fetched platform-evidence request; they require the selected provider's
native web-search mode instead. Changing the provider or model deactivates the
attachment; it never causes background classification.

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

Each attachment persists a **classification pace** of 1–120 provider requests
started per minute (default 6). It is enforced for both manual and activated
classification paths. The app's one serial classification lane waits between
request starts, so a lower value deliberately slows provider traffic. This is
not a completion-rate promise: provider latency, errors, and token limits can
always make completed classifications slower.

The per-request max-token cap is sent in the selected provider's native output
limit field. The effective cap is the smaller of that value and the remaining
daily allowance. If a provider response omits usage, the app conservatively
charges that requested cap. The optional extra direction is included in the
classification prompt before the fixed JSON-only response contract; it cannot
change the response parser, which still accepts only bounded eligible tag IDs.

Each tag may have an optional local description. An explicit LLM request sends
the eligible tag ID and its description together. Tags excluded by the
leaf-only setting are not sent, so neither are their descriptions. Descriptions
remain local tree metadata and are not part of provider diagnostics or request
history.

A language-model test succeeds only after a 2xx response matches that
provider's response grammar and contains generated text. An empty or unrelated
JSON envelope is an error, not a green "provider is ready" result. Cohere test,
classification requests explicitly set `stream: false` because the native
transport accepts one bounded JSON response rather than an SSE stream.

When a 2xx provider response cannot be parsed, its local request record retains
the HTTP status and a bounded **response shape** only: JSON kind, safe field
names, selected array counts, and whether the expected text field was empty.
It never retains a response value, generated text, reasoning, credential,
header, or request body. The provider panel exposes the latest such diagnostic
so a later failure can be diagnosed without replaying or logging private model
output.

## Creator evidence

For YouTube, Facebook, and X, native code deterministically selects the newest
ready matching official-platform API profile and fetches one bounded record:
the creator where the API supports it, otherwise the representative collected
entry. The model cannot choose credentials, URLs, identifiers, API profiles, or
whether to perform the fetch. If the profile is missing, the API request fails,
or the response is unreadable, the classification does not run.

TikTok Display and Instagram Graph only expose data for their authorized
creator. Bilibili has no arbitrary-creator public evidence adapter here. For
those three collected platforms, Vault Classifier makes **no** app-owned
platform-evidence request. Classification requires a selected language-model
provider whose native search request grammar is implemented in the app and
whose web-search setting is enabled. That provider retrieves public evidence;
the app does not store its results. Without native search, classification is
disabled rather than falling back to scraping. Currently, the implemented
native search grammar is OpenAI Responses `web_search`; a provider is not
advertised as searchable merely because a separate agent product can browse.

The creator's local prompt evidence is a random sample of up to 25 observed
titles, bounded before dispatch. It is creator evidence, never individual video
classification.

The prior static public-creator-page scraper and its avatar/API-fallback
controls are obsolete and removed. Browser-collected, verified avatar URLs may
still be cached for display; classification evidence comes only from collected
entries and the official API response.

## Tests that define the boundary

- `WorkspaceAssetsTests`: catalog reconciliation, plain provider-credential
  persistence, profile validation, and legacy-state cleanup.
- `ProviderTestProtocolTests`: provider test/classification request grammar,
  configurable output limits, tag descriptions/extra direction, native-search
  capability guards, and direct provider model-list routing.
- `ProviderModelCatalogStoreTests`: restart persistence and profile-removal
  cleanup for the bounded model-identifier cache.
