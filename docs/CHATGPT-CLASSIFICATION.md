# ChatGPT connection and tagging

Current behavior (2026-10-28): tagging groups choose exactly one explicit
connection and model from ChatGPT subscription, OpenAI API, Gemini API, or Grok
API. Search is enabled for every request. A group's confidence cutoff defaults
to 4; there is no tag-count target. The correction-example prompt path can
include up to three related, current human-corrected titles and their final tag
names from the same group and platform, but remains dormant after a mixed
100-title comparison. Correction notes are excluded. The correction itself
remains authoritative and existing cached results are kept. The
tagging request has no fixed app deadline. Each of the four AI connections has
its own retry interval and total attempt count (defaults: 60 seconds and three
attempts). Only temporary network errors and HTTP 408/5xx are retried
automatically; quota/authentication errors, malformed replies and exhausted
attempts leave new items unresolved for manual Retry. Every dispatched attempt
counts against applicable usage limits. These controls do not change the
separate model-list, sign-in or custom-rule request limits. The
historical implementation notes below describe the initial ChatGPT rollout;
retired Local, search-switch, strictness and count controls are not current UI.

## Historical initial rollout

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
The live plan route has been observed omitting Content-Type on valid SSE.
Absent media type still requires bounded SSE framing and response.completed;
an explicit conflicting media type is rejected. Redirects, malformed output,
refusals, incomplete streams and late usage errors
do not create model decisions. Stream buffers and request duration are bounded.

The coalescer deduplicates in-flight cards. Active cloud-only platforms drain
up to 32 waiting items, split into provider batches of at most 16 with at most
two inference requests in flight per account client. Other platforms retain
16-item queue chunks. Cloud requests use low reasoning effort. Token renewal
remains serialized; usage is reserved atomically after renewal and before each
dispatch. Cancellation drains both active requests and prevents waiting callers
from dispatching. A sibling's cancellation or success cannot clear a failure
hold; explicit Retry is still required. Existing valid cached tags remain valid.
Each cloud batch shares taxonomy and house rules; out-of-order results are mapped
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
