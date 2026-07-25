# LLM Assist and provider connections

This document describes the current code contract for optional provider work.
It is not a claim that a provider feature runs automatically.

## Supported profiles

Every profile exposed in the LLM Assist provider picker is ready for its
declared, explicit operation once the user supplies a valid account credential
and any shown connection fields. "Ready" here means the app has an ordinary
saved credential field, a bounded connection test, a model/classification request
grammar (for language models) or platform health/evidence route (for platform
data) or raw-results route (for search), and regression coverage. It does not
guarantee that a provider account, model, regional availability, quota, or
OAuth grant is available to a particular user.

- **Language models:** OpenAI, DeepSeek, Gemini, Anthropic, Mistral, Cohere,
  Groq, OpenRouter, and local Ollama. **OpenAI-compatible** and **Custom** are
  both explicit HTTPS OpenAI Chat-Completions connections; their owner supplies
  the endpoint and model.
- **Platform data:** YouTube Data, Twitch, Reddit, X, TikTok Display,
  Instagram Graph, and Facebook Graph. They support explicit connection tests
  and bounded official evidence where their access scope can read the
  collected creator; they are never language models.
- **Raw web search:** Serper and You.com Search. They return a bounded list of
  titles, public URLs, and snippets; they are never language models and do not
  use a provider's answer, research, summarization, or live-crawl product.

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
daily aggregate-token allowance, **per-request output-token** cap (default 4,096),
optional **extra direction**, classification pace, batch size, returned-tag
limit, leaf-only constraint, and one explicit web-search mode: **Off**,
**Model provider search**, or **Attached search API**. Official platform
evidence and search are independent connection types. OpenAI, Gemini, and
Anthropic expose their implemented hosted-search grammar in the provider mode.
Attached mode exposes one app-defined `web_search(query)` function to a
tool-capable standard model and binds it to one independent Serper or You.com
Search profile. The same classifier model decides whether it is unsure, emits
the tool call, receives the bounded results in the same conversation, and then
returns the tags. Search is neither unconditional prefetch nor a second model.
Changing the selected classifier provider/model, search mode, or attached
search connection deactivates the attachment; it never causes background
classification.

An attachment can classify a creator only when at least one evidence capability
is ready: a matching official platform API connection, or its configured
web-search mode. The UI disables activation and explicit classification and
explains the missing requirement when neither is ready. This is an availability
gate, not a rule that the model must search.

The type also retains its selected provider while no model has been attached
yet. Its complete non-executable form is saved as a per-provider draft, so a
rerender or relaunch cannot discard the token limit, pace, prompt direction,
tag limit, or search choices made before the fetched model is selected. A
draft cannot activate a provider, dispatch a request, or change an existing
provider/model attachment.

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
- The list is a bounded local cache of model identifiers plus nullable
  model-specific search/tool capability signals. A successful later Probe
  replaces it; a failed Probe leaves the previous successful list in place. It
  survives an app relaunch but is not written into the workspace catalog and
  never contains credentials, endpoints, or request/response data.
- Probe keeps every returned model identifier unless provider metadata
  explicitly marks it as non-generation/non-chat. It does not discard a plain
  generation model merely because that model lacks tools. OpenRouter reads
  `supported_parameters`,
  Mistral reads `capabilities`, Cohere requests chat models, and Ollama checks
  each installed model's `/api/show` capabilities. A missing model-specific
  signal remains unknown; an explicit false disables only the unsupported
  search mode for that model. No capability is inferred from a model's name.
- A saved selected model remains visible if the process has no cached list.
  Editing provider fields does not invalidate the cached list or detach an
  affected classifier attachment.

An explicit **Test request** uses a bounded provider-specific health/test
request. It does not send collected browser content. Provider classification
is opt-in: an inactive attachment may be run manually, while activation
processes only eligible creators sequentially and stops before the next request
when disabled or the daily allowance is exhausted. A running batch captures
the attachment and provider profile it started with; if either is saved with a
change, the batch stops before its next provider request and asks the user to
start a new batch. It never quietly mixes an old request with newly saved
settings.

Each attachment persists a **classification pace** of 1–120 provider requests
started per minute (default 6). It is enforced for both manual and activated
classification paths, including the initial classifier turn, an attached
search request, and the final classifier turn. The app's one serial
classification lane waits between request starts, so a lower value deliberately
slows provider traffic. This is not a completion-rate promise: provider
latency, errors, and token limits can always make completed classifications
slower.

The per-request cap is sent in the selected provider's native output-limit
field. The effective cap is the smaller of that value and the remaining daily
allowance. Daily accounting uses each provider's aggregate usage: prompt,
generated output, reasoning, and tool-related tokens where the provider
reports them. In Attached mode, the successful tool-calling turn is written to
the token ledger before raw search or the final continuation begins, so its
usage remains charged even if either later step fails. The final model turn is
recorded separately; both records count toward the daily budget. A 2xx model
response without usable accounting consumes a conservative estimate of its
input body plus the full requested output allowance. Malformed generated label
JSON is charged too. Raw-search requests do not consume model tokens. The
request ledger never retains request or response bodies. The optional extra
direction is included in the classification prompt before the fixed label
response contract. The parser accepts either
the exact label JSON object or one complete `json`/plain Markdown fence around
that object, never JSON embedded in explanatory prose. An empty `labelIDs`
array is a valid explicit LLM no-tag decision, distinct from a human decision
that has not selected a tag.

Classification requests also use the strongest documented provider-native
output constraint that does not remove the selected search/tool capability.
The common schema requires exactly one `labelIDs` array of strings and rejects
extra top-level properties; the local parser remains authoritative for the
eligible-ID vocabulary, duplicates, and configured maximum count. OpenAI,
Anthropic, Mistral, Gemini, Cohere, OpenRouter, and Ollama receive their native
JSON-schema grammar where compatible. DeepSeek receives JSON Object Mode, and
Groq receives its roster-wide JSON Object Mode unless attached tools are
selected. OpenRouter additionally requires a route that accepts the requested
parameters. Arbitrary OpenAI-compatible and Custom endpoints retain the prompt
contract plus local validation because their model-list response cannot verify
a structured-output request field.

Provider incompatibilities never silently disable search. Google currently
documents combined structured output and tools for `gemini-3.1-pro-preview`
and `gemini-3.6-flash`, so those exact models receive both the selected search
grammar and native response schema. Other Gemini models retain search without
the unverified response field.
Anthropic hosted search keeps its citation-bearing grammar rather than adding
the incompatible JSON-output constraint, while Anthropic attached tools can
retain JSON output. Cohere, Groq, and Ollama attached-tool requests likewise
keep their documented tool grammar instead of sending an incompatible or
unverified response-format field. If one of these searched/tool-assisted
answers violates the local label contract, Vault makes one charged
same-provider, same-model repair request with search disabled and the native
output constraint enabled. That repair receives the original classification
prompt and malformed candidate as transient quoted context, never repeats
research, and must still pass the eligible-ID and maximum-count validator. The
malformed source turn is recorded independently so its usage cannot disappear
when repair succeeds. A failed or unaffordable repair remains a closed failure.

Each tag has a human-readable local name and may have an optional local
description. An explicit LLM request sends the eligible tag ID, name, and
description as separate fields; a request with an eligible ID but no readable
name fails locally instead of asking the model to infer meaning from an opaque
identifier. Tags excluded by the leaf-only setting are not sent, so neither are
their names or descriptions. This tree metadata is not part of provider
diagnostics or request history.

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

Every creator prompt begins with the same typed browser-observation contract:
a random sample of up to 25 retained entries, with each entry's platform
content kind, title, public identifiers/URL, bounded attributes, and
observation metadata. The prompt also states the platform source kind
(creator, account, subreddit, or server). Whole records are removed from the
tail when necessary; JSON is never truncated mid-record.

When a ready official adapter is available, native code deterministically
selects the newest matching platform API profile and attempts the platform's
bounded evidence route. The shared **Official content records** setting
persists a request count from 1–50 (default 25) for every adapter. YouTube keeps
its validated richer channel → uploads playlist → full video-record flow.
Twitch, Reddit, X, Instagram, and Facebook add a recent creator-content request
after their public creator record. TikTok queries up to 20 identifiers from the
typed browser-observed sample because its reviewed public API does not expose
the same creator-history lookup.

All adapters emit the same `recentContentItems` prompt field while retaining
their platform-native public fields and metrics. YouTube still preserves its
upload order and keeps every returned video's core ID, title, publication time,
duration, and primary metrics before reducing descriptions or extended fields
to satisfy the prompt bound. Other platforms retain their available public
profile, content, metric, and response-context fields within the same bound.
Each HTTP response is counted as a platform API call, but no request or
response body is written to provider history.

Successful official evidence is sanitized and exists only in the in-flight
classification prompt. It never backfills the browser-collected dataset. The
model cannot choose credentials, URLs, identifiers, request parts, or API
profiles. Official evidence is preferred context, not an unconditional
prerequisite: if the required route is absent or fails, classification may
continue only when a ready web-search capability is configured.

OpenAI Responses (`web_search`), Gemini GenerateContent (`google_search`
grounding), and Anthropic Messages (`web_search_20250305`) receive their native
search tool only in Model provider search mode. The prompt tells the model to
search only when the supplied collected and official evidence is insufficient.

In Attached search API mode, one function schema is included with the unchanged
classification prompt. The model may answer directly when evidence is enough,
or make exactly one `web_search` call. Multiple calls, unknown tools, malformed
arguments, or a second tool call are rejected. The model-generated query is
sent to the selected Serper or You.com connection, which returns at most five
titles, public URLs, and snippets. Those untrusted results exist only in the
in-flight continuation and are then discarded. The ledger retains request
metadata but no query or result body. If the attached connection is not ready,
classification stops rather than scraping or chaining into a second LLM.

An official API returning fewer fields or records is treated as missing
evidence, not negative evidence. Configured provider-native or attached search
remains available even after a successful official response, and the model is
directed to use it when the typed collected and official records are
insufficient. A platform without a reviewed adapter, such as Bilibili, uses
typed collected evidence plus configured search rather than an undocumented
endpoint. These are creator-evidence records, never independent content-item
classifications.

The prior static public-creator-page scraper and its avatar/API-fallback
controls are obsolete and removed. Browser-collected, verified avatar URLs may
still be cached for display; classification evidence comes from collected
entries, any successful official API response, and any bounded search result
the model elects to request.

## Tests that define the boundary

- `WorkspaceAssetsTests`: catalog reconciliation, plain provider-credential
  persistence, profile validation, and legacy-state cleanup.
- `ProviderTestProtocolTests`: provider test/classification request grammar,
  explicit creator/sample association, readable tag definitions, configurable
  output limits, the bounded YouTube channel/uploads/video chain (including
  all 50 configured video cores), extra direction, native-search and same-model
  external-tool continuation grammars, bounded Serper/You.com routing,
  capability annotation without tool-only filtering, and direct provider
  model-list routing.
- `ProviderModelCatalogStoreTests`: restart persistence and profile-removal
  cleanup for the bounded model-identifier cache.
