# Vault Classifier — Research & Classification Redesign

> **Status: DRAFT for owner review (2026-09-16).** Do not build until the text is
> settled (project convention: design doc first, like `REWORK-local-model-centered.md`
> and `PHASE3-BUILD-PLAN.md`). This supersedes the current research trigger/queue
> design once approved.

## 1. Why

The research system grew into a tangle: **4 trigger modes**, a
`confidenceTriggerLevel` cutoff, **2 search-execution modes**, and a **15-field
`ResearchSettings`** where *every* field is per-type overridable. The signal it
triggers on (classification softmax confidence) is regime-dependent and the
field that was meant to be the real research input (`unknownTerms`) is **dead —
the engine hardcodes `unknownTerms: []`**.

Owner's target (2026-09-16): the model looks at all of a video's evidence and
emits two things — **what it is (tags + confidence)** and **what it's unsure of
and how badly (terms + urgency)** — and research simply spends a budget on the
most urgent unknowns. Everything below makes that concrete.

## 2. Locked decisions (owner, 2026-09-16)

1. **One consolidated input** per video: title + OCR thumbnail text + summary +
   creator context + matched knowledge + the user's related corrections.
2. **Two model outputs:**
   - **Classification** — `[{tag, confidence}]`.
   - **Research needs** — `[{term, urgency}]` plus a per-video **author-urgency**.
3. **Confidence is model-emitted**, not softmax-derived. Reliability comes from
   *better prompting* — an explicit rubric, evidence-first ordering, and few-shot
   calibration examples (sourced from the user's own corrections) — **not** from
   falling back to self-report's failure. Softmax is retained as a cheap
   cross-check; **the eval decides** whether model-confidence actually beats it.
4. **Urgency is graded, not a flag** — a number (1–5) *or* a small named scale
   (low/med/high/critical). Which one is settled by the eval. Same for
   author-urgency.
5. **Two decodes** (not one combined grammar): a lean classify decode, then a
   separate research-needs decode. Keeps the hot path fast; the second decode is
   near-empty in steady state (see §7).
6. **Research is driven by urgency + user setting** (budget + an urgency floor).
   **No classification-confidence trigger** — drop `ResearchTrigger`'s 4 modes and
   `confidenceTriggerLevel` entirely.
7. **Queue is urgency-ordered** — highest urgency first, spend the daily budget
   down; replaces the current serial FIFO.
8. **Author research = accumulation** — sum per-video author-urgency per creator;
   when it crosses a **user-set threshold** (level × count over a window),
   research the author. Replaces the "append the creator handle when the
   histogram is weak" heuristic.
9. **Search execution: native provider-grounding only** (Cut A). Drop the
   `rawSearchProvider` two-provider mode, `RawWebSearchProtocol`, and its settings.

## 3. Measured latency (de-risks the design)

Raw `llama-bench`, mini1 (Intel i5-8500B, **CPU/BLAS, no Metal**, Qwen2.5-1.5B Q4):
**prefill 93 tok/s (~10.7 ms/tok), generation 8.2 tok/s (~122 ms/tok).**

With the static prefix KV-cached, per-video cost ≈ `suffix_tokens × 10.7 ms +
generated_tokens × 122 ms`:

- Model confidence adds ~4 generated tokens → **~+0.5 s on mini1's CPU, ~+0.1 s
  on Apple Silicon.**
- Research decode, empty case (~3 tokens) → +0.37 s mini1 / ~50 ms Apple Silicon.
- **Dominant cost is evidence prefill**, unchanged by this design: mini1 is
  prefill-bound at ~2–3 s/video regardless; Apple Silicon lands the full new path
  ~250 ms, under the 500 ms budget.

**Conclusion:** model-emitted confidence + the research decode are affordable. The
latency levers are evidence size, KV-caching, and hardware — target Apple Silicon
for the budget; adding confidence/urgency does not change that verdict.
(mini1's Swift 5.10 is too old to build the full engine — bench is the proxy;
end-to-end mini1 testing needs an Xcode upgrade there, owner-gated.)

## 4. Data model / contracts

**Classification output** (Decode 1):
```
LLMTagScore { name: String, confidence: Int (1–5) }   // confidence now MODEL-emitted
LLMClassificationResult { tags: [LLMTagScore] }        // unknownTerms REMOVED from here
```

**Research-needs output** (Decode 2), the revival of the dead `unknownTerms`:
```
ResearchNeed { term: String, urgency: Urgency }        // Urgency = Int 1–5 or enum (TBD §11)
ResearchNeedsResult { terms: [ResearchNeed], authorUrgency: Urgency? }
```

**Stored on the video** (`VideoClassification`): tags (unchanged shape), plus the
emitted research needs are enqueued, not stored long-term; author-urgency feeds
the per-creator accumulator (below). `unknownTerms: [String]` on
`VideoClassification` is removed (decode-and-drop old values, crash-safe, per the
product-evolution rule).

**Per-creator accumulator** (new, in the catalog): `creatorID → { urgencySum,
count, windowStart }`; crosses the user-set threshold → enqueue an author research
task; reset/decay on a successful author research or window roll-off.

## 5. Decode strategy (two decodes)

- **Decode 1 — Classification (hot path).** One consolidated evidence prompt →
  grammar-constrained tags. Confidence is **generated** (structured
  `{"name":"…","confidence":N}` per tag), made reliable by §6. Keep the A1
  multi-tag grammar shape (bounded list, JSON-scaffold separator). Softmax of the
  name's first token is still computed and stored alongside for the cross-check.
- **Decode 2 — Research needs.** Runs after Decode 1, reusing the same KV-cached
  prefix. Emits `[{term, urgency}]` + `authorUrgency`. **In steady state this is
  near-empty** (a known creator with settled knowledge yields no terms), so it
  costs a few tokens. Grammar: a bounded list of `{term, urgency}` where `term`
  is a copied span (like today's `extractResearchSubject`) and `urgency` is the
  chosen scale; `authorUrgency` a single trailing value.

Both grammars are GBNF, name/term-only where possible so generation stays short.

## 6. Making model-emitted confidence & urgency reliable

Self-report failed before (4/5 self-reported on a 37%-true case) — but that was
*naive* self-report. This design earns it back with prompt engineering, then
**proves it with the eval** (§10) before shipping:

- **Explicit rubric** in the static prefix: "5 = a named subject you are certain
  of; 3 = a plausible inference; 1 = a guess," and for urgency "5 = you cannot
  place the video without knowing this term."
- **Evidence-first** ordering (all evidence before the ask) so the model commits
  after reading, not before.
- **Few-shot calibration examples** — real `title → {tag, confidence}` pairs from
  the user's own corrections (the `CorrectionRetriever` already fetches related
  ones), plus a small curated set spanning the confidence range.
- **Softmax kept as a cross-check / fallback.** If the eval shows model-confidence
  is not better-calibrated than softmax, Decode 1 stays name-only + softmax and we
  don't pay the extra generation. This is an explicit off-ramp, not a commitment.

## 7. Research trigger & queue

- **Candidates** = every emitted `term` with `urgency ≥ user floor`. No decline
  cutoff needed (a genuine "I don't know" surfaces as a high-urgency term), though
  a plain decline with no term can still enqueue a fallback subject.
- **Urgency-ordered queue** (replaces FIFO): a priority queue keyed by urgency;
  the drain loop pulls highest-first and spends the **daily token budget** down;
  drop lowest when full. Keep the existing transient-retry + failed-subject
  cooldown + negative cache (they're reliability infra, not complexity to cut).
- **Knowledge → reclassify** unchanged: a result writes a `KnowledgeEntry` (facts
  only), which re-classifies the triggering video + matching weak rows → pill push.

## 8. Author research (accumulation, user-set)

- Each classify adds `authorUrgency` to the creator's accumulator.
- When `accumulator ≥ userThreshold` (a user setting: e.g. "research an author
  after N videos average urgency ≥ L, within a W-day window"), enqueue an author
  research task; on success, write the `creator:` knowledge and decay/reset the
  accumulator.
- Removes the current implicit "append the creator handle when the histogram is
  weak" path.

## 9. Settings collapse

**Before (15, all per-type-overridable):** enabled, searchMode, llmProvider,
llmModel, webSearchProvider, requestsPerMinute, dailyTokenLimit, maxSubjectsPerVideo,
cooldownHours, trigger, confidenceTriggerLevel, searchResultCount,
snippetContextChars, knowledgeTTLDays, maxKnowledgePerVideo.

**After (global core):** `enabled`, `llmProvider` + `llmModel` (grounding-capable),
`dailyTokenLimit`, `requestsPerMinute`, `cooldownHours`, `maxKnowledgePerVideo`,
`urgencyFloor`, `authorThreshold` (level/count/window). **Removed:** `searchMode`,
`webSearchProvider`, `searchResultCount`, `snippetContextChars` (Cut A);
`trigger`, `confidenceTriggerLevel`, `maxSubjectsPerVideo` (urgency replaces them).
Per-type overrides shrink to **on/off (+ optional provider)**.

## 10. Eval experiments (run BEFORE committing — like A1)

Extend `VaultClassifierEval` and run on the real engine (laptop 7B for quality,
mini1 for weak-hardware latency):

1. **Model-confidence vs softmax calibration.** Add model-emitted confidence to
   Decode 1; on `eval-set.json` compare reliability (precision-by-confidence,
   ECE) of model-confidence vs softmax. Winner drives §6's off-ramp.
2. **Urgency form.** Compare urgency as a 1–5 number vs a named scale — which
   correlates better with "actually needed research" (proxy: decline/correction/
   later-corrected). Settles §2.4/§11.
3. **Latency guardrail.** Confirm Decode 1 (structured) + empty Decode 2 stays
   under 500 ms on Apple Silicon; record mini1 as the weak-hardware reference.

## 11. Open questions (to close before/with the eval)

- **Urgency scale:** 1–5 number vs named options (→ experiment 2).
- **Confidence off-ramp:** if model-confidence loses to softmax, keep softmax and
  drop structured Decode 1 (→ experiment 1).
- **Author-accumulation defaults:** the shipped default threshold (N, L, W).
- **Decline-with-no-term:** does a bare decline still enqueue a fallback subject,
  or only explicit terms drive research?

## 12. Phasing (green at each step)

- **Phase 0 — Eval experiments (§10).** Decide confidence source + urgency form on
  measured data. *Evidence before commitment.*
- **Phase 1 — Contracts + dead removal.** New `ResearchNeed`/`ResearchNeedsResult`;
  remove `unknownTerms` from results, `ResearchTrigger`, `confidenceTriggerLevel`,
  raw-search settings (decode-and-drop). Build + tests.
- **Phase 2 — Decodes.** Decode 1 model-confidence (per Phase-0 result) + Decode 2
  terms/urgency grammars + §6 prompting. Eval-scored.
- **Phase 3 — Queue + author accumulation.** Urgency-ordered queue, budget spend,
  per-creator accumulator + user-set threshold.
- **Phase 4 — Settings collapse + UI.** Trim `ResearchSettings` to §9; update the
  web-shell controls; per-type on/off only.
- **Phase 5 — Remove raw-search execution + dead code + cleanup pass.**

## 13. Decisions log

- 2026-09-16 — Owner mental model adopted: two model outputs (tags+confidence,
  terms+urgency+author-urgency); research driven by urgency+budget; author research
  by accumulation.
- 2026-09-16 — Confidence model-emitted (not softmax), reliability via prompting +
  few-shot; softmax kept as cross-check with an eval-gated off-ramp.
- 2026-09-16 — Two decodes (not one combined grammar). Urgency graded, not a flag.
- 2026-09-16 — Queue urgency-ordered; author threshold user-set.
- 2026-09-16 — Cut A confirmed: native provider-grounding only; drop rawSearch.
- 2026-09-16 — Latency measured (mini1 bench): confidence/urgency generation is
  cheap; prefill dominates; design targets Apple Silicon for <500 ms.
