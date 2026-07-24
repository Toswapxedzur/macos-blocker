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

Twitch, Reddit, and Discord classification is intentionally **manual-only**.
Their collected sources and human tags remain available, but classifier types
for those platforms cannot attach a Local Model or LLM Assist configuration.
Twitch and Reddit API connections remain in the platform-data library; that
does not make their classifier types model-eligible. Discord has no platform
API connection here.

## Ownership boundary

A **provider profile** is a reusable connection. It contains a provider type,
endpoint/protocol configuration, and an optional non-secret test-model
identifier. It does not select a classifier type, platform, policy, model for
classification, or decision weight.

A **classifier type** owns one optional LLM Assist attachment. The attachment
selects exactly one provider profile and one fetched model identifier, plus its
daily output-token allowance, **per-request max-token** cap (default 4,096),
optional **extra direction**, classification pace, batch size, returned-tag
limit, leaf-only constraint, and optional hosted web search. Official platform
evidence and hosted research are independent layers: a ready matching official
API connection is required where an adapter exists, and search may be enabled
for every platform. Search can use the classifier provider's direct hosted
grammar or any separately selected hosted-search provider plus one of its
fetched models. The separate provider produces a transient research memo; the
classifier model still returns the tags. Changing either selected
provider/model deactivates the attachment; it never causes background
classification.

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
classification paths, including a separate web-research request followed by a
classifier request. The app's one serial classification lane waits between
request starts, so a lower value deliberately slows provider traffic. This is
not a completion-rate promise: provider latency, errors, and token limits can
always make completed classifications slower.

The per-request max-token cap is sent in the selected provider's native output
limit field. The effective classifier cap is the smaller of that value and the
remaining daily allowance. A separate web-research response also consumes the
same daily output allowance; it is capped at 1,024 output tokens and a missing
usage value consumes that cap conservatively. The request ledger records the
two requests separately, but never their bodies. The optional extra direction
is included in the classification prompt before the fixed JSON-only response
contract; it cannot change the response parser, which still accepts only
bounded eligible tag IDs.

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

Official API evidence does not decide whether hosted search is available.
OpenAI Responses (`web_search`), Gemini GenerateContent (`google_search`
grounding), and Anthropic Messages (`web_search_20250305`) can search directly
when the selected model supports the provider feature. Any classifier provider,
including one of those three, may instead use one separately selected profile
and one fetched model from a search-capable provider. This makes combinations
such as DeepSeek classification + YouTube official evidence + Gemini search
valid. The research model is instructed to use its hosted search tool only
when the already provided collected and official evidence is insufficient.
Its memo is added only to the in-flight classifier prompt, then discarded; the
ledger retains request metadata and token accounting only. When search is
enabled without either direct search or a ready separate research connection,
classification is disabled rather than falling back to scraping. A provider is
not advertised as searchable merely because a separate agent product can
browse.

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
