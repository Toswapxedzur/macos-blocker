# Vault Classifier — Independence & Simplification

> **Status: ALL SEVEN PHASES BUILT (2026-09-18).** Owner ask:
> "make the classifier more independent, clearer and simpler logic, more concise
> and better" — all tiers, balanced. Each phase landed as its own verified
> commit (build + full suite green) so the program is reviewable step by step.
> Design-doc-first like `RESEARCH-REDESIGN.md` / `LATENCY-REFINEMENT.md`.

## 0. What the four words mean here

| Word | Concrete meaning |
|---|---|
| **independent** | The tagging service must not drag the hub server, browser bridge, cloud-research stack or content-block policy with it. Boundary: `(title, evidence) → (tags, confidence)`. |
| **clearer** | One responsibility per type. `VaultClassifierViewModel` (3,136 lines, ~51 web-op handlers) mixes routing, settings, dispatch, provider tests, research and downloads. |
| **simpler** | Fewer moving parts on the classify path; remove decision branches that dead features leave behind. |
| **concise** | Delete vestigial code and collapse duplication. |
| **better** | One documented tagging contract (§6). |

## 1. Diagnosis (measured 2026-09-18, before any change)

- 23.9k lines of Swift, 236 tests. The **tagging core was already clean**
  (`VideoClassificationPipeline` is a pure transform); the mess was *around* it.
- **Three subsystems fused into one package:** (1) on-device tagging, (2) cloud
  grounded-research (`Provider*Protocol` + `GroundedResearch`, ~2k lines,
  Gemini-backed enrichment), (3) suite-integration glue (local hub server/client,
  HMAC auth, browser-bridge DTOs, OCR, icon cache).
- **Core was not independent:** it carried `LocalHubAuthentication` (networking +
  secret storage) and the bridge DTOs; policy evaluation lived in Core although
  the owner had ruled policy belongs in the extension.
- **God-objects:** `VaultClassifierViewModel` (3,136), `WorkspaceAssets.swift`
  (1,631, ~20 unrelated persisted types), `LocalClassifierCoordinator` (~1,150).
- **Duplication:** the tag min/expected/max clamp derived in 3 places; the hub
  operation allowlist copied 3×; the serial and batch decode loops near-identical
  (~130 lines each); confidence gated 3× (engine → pipeline → policy).
- **Dead:** `generateFreeText` (self-labelled), the whole policy subsystem
  (verified inert: `resolveActions` had no caller, the App never set the
  per-video actions, the web policy editor was never rendered, nothing read
  `bridge-info.policies`), `namesGrammar` (only its own tests).
- **Risk map:** the God-object is the *least* unit-tested file and has no
  injection seam (its `init` prepares the real app-support dir, loads real
  `state.json`, connects the hub and mmaps the GGUF) — so it cannot be
  characterised hermetically as-is.

## 2. Phase 1 — one clamp, no dead engine code (BUILT, `80f0d6e`)

- `TagBounds` (Core) is now the single owner of the tag-count invariants
  (`0 ≤ min ≤ max ≤ 16`, `expected ∈ [max(1,min), max]`). `LocalLLMSettings`,
  `LocalModelOverrides.effectiveTagBounds`, `VideoClassificationPipeline.init`
  and `LocalStore.classifyVideos` all resolve through it. Behaviour-preserving.
- Deleted `VaultLocalLLMEngine.generateFreeText` (~55 lines, no callers).
- **Kept on purpose:** the three startup migrations and the `RetiredCodingKeys`
  decode blocks — they still guard existing on-disk state; deleting them saves
  ~150 lines but risks stranding local data. Revisit with fixtures (§7).

## 3. Phase 2 — allowlist single source (BUILT, `a4893f5`)

`LocalClassifierHub` derived its request/broadcast guards from literal string
arrays — a third copy of `SharedBrowserBridgeOperation` that could drift (the
"add an op in 3 places or it is silently dropped" hazard). Both guards now come
from the enum (`relayableRequestOperations` = `allCases`;
`relayableBroadcastOperations` = `[videoTagsUpdatedBroadcast]`). Adding an op is
one enum case. The extension's `runner-hub-op-parity.js` was repointed to parse
the enum, so cross-repo parity is *stronger* (it checks the real vocabulary).

## 4. Phase 3 — Tier A: `VaultClassifierBridge` (BUILT, `1126a2e`)

`SharedBrowserBridge.swift`, `SharedBrowserBridgeMessages.swift` and
`LocalHubAuthentication.swift` moved out of Core into a new library target that
depends on Core. Nothing in Core referenced them (verified), so the move was a
pure relocation. **Independence is now compiler-enforced:** Core cannot import
the bridge. App, the native host and the two test targets gained the dependency.

## 5. Phase 4 — Tier C: policy retired (BUILT, `7459c03` + customBlocker `d6696c9`)

Owner ruling 2026-09-13: content-block policy lives in the extension; the
classifier is a pure tagging service. Removed from the classifier: `Policy.swift`
/ `PolicyManagement.swift` (`NamedPolicy`, `PolicyCatalog`, `StarterPolicies`),
`PresentationAction`, `EntryEvidence.policyIDs`, `state.policies` + its
load/activate validation + backup field, `NativeBridgePolicy` and the
`bridge-info` body (the op stays as a bare ping for hub parity and the
extension's latency probe), `feedAction`/`pageAction` on video-tags/batch/
broadcast, the App editor state/methods/web actions, the dead `policyWorkspace()`
and 33 strings. 225 tests (236 − 11 policy tests).

Compatibility: old `state.json`/backups carrying `policies` decode fine (key
ignored); the extension already coerces a missing action to `allow`.

Extension side: `policyIDs` (never populated) and 4 policy-semantic i18n keys
removed across 20 locales. **Deliberately kept there:** the `feedAction`/
`pageAction` plumbing and the `cbApplyTagPolicy`/`cbApplyTagPagePolicy`
executors — they back the correct-a-tag instant lift/re-block flow, not only
classifier verdicts. **Gap surfaced (pre-existing, not a regression):** the
extension's native tag filter has no page-level action; a follow-up task adds
`platformTagPageEffect` reusing the page executor, then strips the classifier-
verdict plumbing.

## 6. The tagging contract (the "better")

What the classifier promises, after Phases 1–4:

- **Input:** title (+ optional summary/text/OCR text), creator id, platform,
  classifier type. Evidence added by the pipeline: the creator's counts-only
  prior (total videos + count per tag — nothing else, see memory), matched term
  knowledge, the most similar past corrections.
- **Output:** up to `maximumTags` `{tagID, confidence 1…5}`; **no block/dim
  decisions** — those are the extension's.
- **Tag-count bounds** (`TagBounds`): `minimumTags` (default 0; ≥1 forbids
  declining and forces the best guesses), `expectedTags` (soft prompt target,
  never enforced), `maximumTags` (hard cap). Per-type overrides resolve through
  the same type.
- **Confidence is model-emitted** (structured `{"name","confidence"}` — beat the
  first-token softmax in Exp 1; softmax retained as a cross-check). Two gates
  remain, both documented: the pipeline's `secondaryConfidenceFloor` (extra tags
  beyond the top one must clear it; the top `max(1,minimumTags)` are kept
  unconditionally) and the *extension's* own floor in its tag filter. The old
  third gate (`NamedPolicy.confidenceFloor`) is gone with policy.
- **Decline** (`none`) is an active choice, allowed only when `minimumTags == 0`.
- **Why min-1 exists:** the 7B's real weakness is over-declining knowable titles
  (P0.82 R0.61 at min-0 vs P0.72 R0.71, exact 60→71 %, declines 16→0 at min-1),
  and emitted confidence cleanly separates good (conf5 P0.85) from bad
  (conf≤3 P0.11) forced guesses — so a downstream floor recovers precision.

## 7. Phases 5–7 (BUILT)

### Phase 5 — God-object split (BUILT, `3ad4756` `5d85e22` `a490ec3` `ac99485` `1df8882`)
1. `init(headlessVaultDirectory:)` — hermetic construction (temp dir, stub
   LLM, no hub/engine/Keychain/migrations/network).
2. `ViewModelCharacterizationTests` (8) pin the web RPC: exact snapshot shape,
   the return-value contract (`true` = re-send, incl. after an error surfaced
   via `issue`; `false` only on a workspace switch), a settings round-trip,
   and all **45 actions** probed as routed. The discovery pass corrected two
   assumptions — that is what the net is for.
3. `VaultClassifierViewModel` 3,252 → 388 lines + nine extension files
   (WebShell 782, Providers 468, HubBridge 326, Workspace 311, Settings 292,
   TreeEditor 291, Research 203, ModelLibrary 100, Backup 76). `private`
   members a moved method needed became `internal`.
4. `WorkspaceAssets.swift` 1,632 → six type-family files; `LocalStore.swift`
   1,337 → 305 + five coordinator extensions (Classify 355, Collection 284,
   Research 254, Settings 72, Packages 70). Also dropped the Tier C leftover
   `PlatformBinding.policyID`.

### Phase 6 — Tier B: research data/execution partition (BUILT, `44d4e4a`)
Not a file move. Core's `LocalStore`/`WorkspaceAssets` persist 10 research/
provider types (queue snapshot/mutation/actor, `ResearchSubject`/`Task`/
`AttemptRecord`, provider descriptor/registry/credential field, `ProviderTestProtocol`).
Only 5 of 8 files are clean-movable; `GroundedResearch.swift`, `ProviderProtocols.swift`
and `ProviderTestProtocol.swift` interleave persisted data with execution, and
`GroundedResearchQueue` is an actor that both holds queue state *and* calls the
network executor. Done as: data→Core / execution→`VaultClassifierResearch` (depends on Core).
The queue already abstracted the executor behind its `Researcher` closure, so
only `init(executor:)` moved (as an extension). Two shared values were hoisted
into Core (`GroundedResearchProviderConfiguration.maximumOutputTokens`,
`ProviderRequestRecord.maximumResponseShapeCharacters`) and
`ProviderTestHTTPError` moved to Core because the persisted failure-kind
classifier matches it — which also exposed and removed an identical shadowing
copy of that enum in the App. A symbol scan confirms Core references nothing in
the Research target. Tagging builds with no network-facing code.

### Phase 7 — engine decode-loop dedup (BUILT, `b3663a7` `337d8bd`)
`structuredDecode` (serial) and `decodeParallel` (batch) re-implemented the same
generation loop. Serial is now a batch of one (`makeParallelItem` is the one
place a request becomes decodable; no single-item special cases). No unit tests exist for the engine
(needs a real GGUF); verification was an exact-output A/B through
`VaultClassifierEval batch --limit=64 --max=3 -v`: all 64 per-item results
byte-identical before/after, serial ≡ batched 64/64, batched throughput
unchanged (503 ms/video). Engine 1,052 → 872 lines. `namesGrammar` deleted
(its live sibling's invariants keep their 5 tests).

### Deferred (needs fixtures or owner call)
- Startup migrations + `RetiredCodingKeys` blocks: delete once a fixture-backed
  decode test proves no live state depends on them.
- The untyped `webSnapshot`/`performWebAction` string-keyed RPC (~630 lines) is
  the second, parallel surface next to the typed browser bridge; collapsing to
  one is a Phase-5 follow-on once the split makes it tractable.
