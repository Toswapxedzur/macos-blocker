# Optional ChatGPT classification

Groups default to Local. Connecting ChatGPT alone does not change a group or
start cloud tagging. Choose an account-specific model under Tagging model to
use the connected ChatGPT plan for that group. Local tiers are retained for
switching back; cloud groups do not warm or resolve a local GGUF engine. When
the last active local group stops using it, the local registry is retired, and
app shutdown waits for both current and retiring resources.

The connector implements the public local/open-source Sign in with ChatGPT
flow: stable opaque host ID, dynamic client registration, fresh PKCE/state/nonce,
loopback callback, RS256 signature validation against OpenAI JWKS, issuer,
audience, expiry and nonce checks, and verified identity matching on renewal.
Plan usage requires the granted `chatgpt.tokens.use.direct` scope. OAuth tokens
are private local credentials, separate from normal classifier state/backups.
Neither Codex nor another app's tokens or client identity are reused.

Models are fetched from the connected account's `/v1/models` catalog, preserving
visible server order. No model is selected automatically for a product group.
Inference uses `https://api.openai.com/v1/responses`, array input, `store:false`
and `stream:true`. A response is accepted only after `response.completed`.
Redirects, malformed output, refusals, incomplete streams and late usage errors
do not create model decisions. Stream buffers and request duration are bounded.

The existing coalescer deduplicates in-flight cards and drains batches of up to
16. Each cloud batch shares taxonomy and house rules; indexed results are mapped
back to their original items. Content, creator context and retrieved pages are
untrusted evidence, not instructions authorizing arbitrary tools. Structured
replies must contain only known, distinct tag names, valid indices, the selected
tag-count bounds, and integer confidence estimates from 1 to 5. These estimates
are not local token probabilities. Additional-tag confidence floors are 5 for
Strict, 4 for Balanced and 3 for Broad/Broadest; Strictest permits at most one
tag by default. User minimum/maximum overrides remain authoritative.

Search is off by default and is an independent group choice. Enabling it offers
only the native web-search tool, subject to model/account support, with an
instruction to search unfamiliar subjects selectively. The SIWC preview does
not accept `max_tool_calls`, so this is not a hard per-query search-count cap.
The request deadline and optional device daily request cap still apply. The
cap resets at midnight UTC, counts each dispatched batch (including failures),
is persisted across restarts, and is independent of provider plan limits.

Caches retain human corrections. Cloud rows use a distinct self-reported-score
contract and stable account/model/rule/strictness/search version, tag bounds and
input fingerprint. Existing taxonomy projections still update without asking
the provider to reclassify cached content. Changing content or model settings
invalidates automatic cache currency. Browser requests compare their incoming
evidence even when collection has not updated yet. Content changes during an
in-flight cloud batch queue one latest replacement and suppress the obsolete
broadcast. A completed obsolete request cannot
overwrite newer settings or human corrections.

On cloud failure, valid cached results remain available and new items resolve
transiently without saving fabricated tags. Cloud failures never cause local
inference or a different account/provider fallback. The account holds failed
requests until explicit Retry; the UI retains a bounded retry queue. The local
batch-to-individual retry path is not used for cloud failures. First plan use
has a dismissible explanation, and the model selector and usage summary expose
ChatGPT's Manage usage destination.

Testing uses synthetic HTTP seams plus real native RSA and loopback sockets;
these do not establish live account eligibility or accuracy. The opt-in
`ChatGPTLiveAcceptanceTests` writes a private sign-in request on the selected
test host, then makes one three-item diagnostic batch after real consent. It
must not be reported as a production accuracy benchmark. Paid/hosted product
distribution eligibility and public publication are separate gates. Claude and
Gemini account integration are deferred.

Official contracts:

- [Sign-in](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)
- [Models and inference](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)
- [Preview limits](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations)
- [UX guidance](https://developers.openai.com/siwc/ui-ux-guidelines)
