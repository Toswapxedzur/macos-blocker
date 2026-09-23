# Vault Classifier — Research & Classification Redesign

> **Note 2026-09-23:** presets, per-type research profiles and every research budget/trigger knob mentioned below are gone — research is on/off + provider (per type: follow/on/off) and the numbers are constants. See `package-info.md` ("Settings shape"). Kept as history.

> **Status: APPROVED — build in progress (owner said "proceed with plan", 2026-09-16).**
> Phases 0–4 are done (see §13 for what changed vs. this text — notably urgency is
> DERIVED from confidence, not model-emitted). All planned phases, incl. Cut A, are done.

> **SUPERSEDED IN PART — 2026-09-21 (owner decision, measured).** Automatic term
> research is deleted: Decode 2 (`researchNeeds`), the legacy single-subject decode,
> the per-video `urgencyFloor` trigger (§7) and the research backfill no longer
> exist. Measured on the 450-video library (`eval-library.json`): the low-confidence
> trigger fired on the wrong videos (0 of 82 unknown-term videos got their term
> researched) and 43% of picked terms were ordinary words — net effect on tagging
> was zero (5 fixed / 7 broke). What remains: the §8 creator accumulator is the ONLY
> automatic trigger (default 5 videos, mean urgency ≥ 3.5 — `level` is now a half-step
> number), and terms are added by the USER in Knowledge (written, or looked up through
> the same grounded lane via `researchTerm`). Hand-picked correct terms measured
> +18 pts exact-tag accuracy on the videos that hold one, which is why the term
> store, title matching and the "Known context" prompt section stay.
>
> **§8 REPLACED — 2026-09-21 (owner design).** The windowed sample list (count / level / window) is gone.
> Each creator carries ONE score (`CreatorResearchAccumulator.score` + its date): a video that could not be
> tagged adds 1, a shaky tag (derived urgency 4 / 3) adds ⅔ / ⅓, a sure tag adds nothing and never
> subtracts; the score halves every `halfLifeDays` (default 14); at `score` (default 3, with a 0.05 tolerance so
> three untaggable videos in one sitting fire) the creator is researched once and the score resets. A creator
> who already has a description is never scored. Why: the reply no longer carries a confidence digit, so a
> video is mostly "tagged and sure" or "no tag" — a score that rises on "no tag" fits that signal, needs one
> number per creator instead of a sample list, and its threshold is the single research-frequency setting.
> Simulated on 4,999 real videos / 1,464 creators (old-format history, 41% untagged — the new format leaves
> fewer untagged, so real counts will be lower): threshold 2 → 219 creators, 3 → 70, 4 → 43, 5 → 37
> (without the tolerance: 93 / 53 / 38 / 36).

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

> **Phase-0 Experiment 1 result (2026-09-16, dev Qwen2.5-7B, 65 labeled items,
> 150 emitted tags — off-ramp NOT taken).** Head-to-head from a single structured
> decode (`VaultClassifierEval calib`): model-emitted confidence beat first-token
> softmax on every axis — **ECE 0.287 vs 0.353, strictly monotone vs non-monotone
> (softmax c3 0.12 < c2 0.14), separation Δ 0.54 vs 0.30.** Decisive tell: tags the
> model rates ≤2 (31 of 150) are **0% correct** — a clean suppression gate; softmax
> instead crams 99/125 tags into c4–c5 (its overconfidence). This held with only the
> *basic* "give a confidence 1–5" instruction — before §6's rubric/few-shot. **We
> adopt structured model-emitted confidence for Decode 1**; softmax stays as the
> cheap cross-check.

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

1. **Model-confidence vs softmax calibration.** ✅ DONE 2026-09-16 (`calib` mode,
   dev 7B): model confidence wins — ECE 0.287 vs 0.353, monotone, Δ0.54 vs 0.30;
   conf≤2 is 0% correct. Off-ramp not taken → structured Decode 1 with model
   confidence. See §6 result box.
2. **Urgency form.** Compare urgency as a 1–5 number vs a named scale — which
   correlates better with "actually needed research" (proxy: decline/correction/
   later-corrected). Settles §2.4/§11.
3. **Latency guardrail.** Confirm Decode 1 (structured) + empty Decode 2 stays
   under 500 ms on Apple Silicon; record mini1 as the weak-hardware reference.

## 11. Open questions (to close before/with the eval)

- **Urgency scale:** 1–5 number vs named options (→ experiment 2).
- ~~**Confidence off-ramp:** if model-confidence loses to softmax, keep softmax and
  drop structured Decode 1 (→ experiment 1).~~ **CLOSED 2026-09-16:** model
  confidence won decisively; structured Decode 1 adopted.
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
- 2026-09-16 — **Phase-0 Experiment 1 RUN & CLOSED.** Built `classifyWithModelConfidence`
  + `namesWithConfidenceGrammar` (engine) and the `calib` eval mode; refactored the
  pipeline (`gatherEvidence` + `primaryPromptParts`, behavior-preserving, 12/12 tests).
  Result (dev 7B, 65 items): model-emitted confidence beats softmax (ECE 0.287<0.353,
  monotone, Δ0.54>0.30, conf≤2 = 0% correct). Structured Decode 1 with model
  confidence adopted; softmax retained as cross-check.
- 2026-09-16 — **Urgency form (Experiment 2) — data gap surfaced.** `eval-set.json`
  has no urgency ground truth, so the specified urgency eval can't run yet without a
  weak proxy. Experiment 1 already shows the model emits a well-calibrated 1–5
  self-assessment; PROPOSED default is urgency = **Int 1–5** (symmetry with
  confidence, reuses the rubric), with a dedicated urgency eval deferred until real
  urgency-labeled data exists. Owner to confirm.
- 2026-09-17 — **Owner confirmed: Urgency = Int 1–5**, proceed to Phase 1 now.
  Dedicated urgency eval deferred until real urgency-labeled data exists.
- 2026-09-17 — **Phase 1 sequencing note.** `trigger`/`confidenceTriggerLevel`
  removal is load-bearing (the research gate + the pipeline's creator-grounding
  floor consume it), so it is done *with* its urgency-driven replacement rather
  than ahead of it — the genuinely-dead parts (`unknownTerms`, raw-search Cut A,
  `maxSubjectsPerVideo`) come out first, each green-checkpointed.
- 2026-09-17 — **Phase 1a done:** dead `unknownTerms` removed from the classification
  contract + persisted model (decode-and-drop). 152/152 core tests.
- 2026-09-17 — **Phase 2 Decode-1 wired to production** (owner-chosen next step).
  `classify` now uses the structured decode (model-emitted confidence); `classify`
  + `classifyWithModelConfidence` share one `structuredDecode`; softmax retained
  per-tag as `LLMTagScore.softmaxConfidence` (cross-check, not persisted). Added
  `NamesWithConfidenceGrammarTests`. Measured on `score` (dev 7B):
  **cap 1 → micro-P 0.56 / R 0.52 / exact 57% — identical to the softmax cap-1
  baseline (P 0.56 / exact 57%): zero accuracy regression** (same top tag chosen;
  only the confidence value changed to the calibrated one). cap 3 → P 0.36 /
  exact 42% (up from softmax's 0.27 / 33%). conf≤2 = 0% correct holds end-to-end
  → trustworthy gate for blocking. `namesGrammar` (name-only) is now unused in
  production but kept (tested; possible fallback).
- 2026-09-17 — **§6 rubric added to the static prefix** (explicit 1–5 anchors:
  5 = certain named subject … 1 = little basis; reserve 4–5). Measured on `score`
  (dev 7B): **within noise** — cap 1 P0.56→0.58 / exact 57→58 / decline 36→38,
  cap 3 flat (P0.36, exact 42→41); conf≤2 = 0% still holds. Kept (non-harmful,
  explicit contract, cached prefix so ~free). **Few-shot calibration from the
  user's corrections is the remaining §6 lever** (not yet done) if a bigger
  calibration move is wanted.
- 2026-09-17 — **Decode 2 built + live-smoked → KEY FINDING: model-emitted
  research-needs/author-urgency are UNRELIABLE with the 7B.** Contracts
  (`ResearchNeed`, `ResearchNeedsResult`, `LLMResearchNeedsRequest`, protocol),
  the GBNF (`researchNeedsGrammar`), the parser (`parseResearchNeeds`), the engine
  decode (`researchNeeds`, KV-reuse over Decode 1), and a `needs` eval mode all
  work — GBNF compiles in llama.cpp, output is valid, 8/8 unit tests. BUT the live
  `needs` smoke (12 items, dev 7B) is degenerate: **`needs` empty on every video**
  (greedy → `]` is the safe completion; a knowledgeable 7B recognizes most
  subjects) and **`author-urgency` just echoes the prompt's stated default**
  (all-5, then all-1 when told "default to 1") — the self-report failure mode
  again, worsened by Decode 1 withholding the creator description. **Implication:
  the reliable uncertainty signal is Decode 1's (now model-emitted, calibrated)
  confidence — a decline / low-conf tag IS "needs research" — matching the owner's
  "confidence shows how urgent" framing.** Proposed pivot (owner to decide):
  (A) demote Decode 2 to a CONDITIONAL subject-extraction that runs only when
  Decode 1 declines or is low-confidence, with urgency = f(Decode-1 confidence)
  not a separate ask; (B) DERIVE author-urgency (creator has no knowledge entry +
  low Decode-1 confidence) instead of asking the model. This revisits §2.2.
- 2026-09-17 — **Owner reframe (decisive): author/video-urgency = an AGGREGATION
  of the Decode-1 tag confidences, not a model ask.** "How confident are you about
  the entire title" = aggregate the per-tag confidences; low aggregate (or a
  decline) = high urgency. So model-emitted urgency/author-urgency are DROPPED.
  Revised design:
  • **Video research-urgency = f(Decode-1 confidences)** — mean of the kept tags'
    confidences (at cap 1 = the top tag), a decline = max urgency 5; inverse map
    (conf 5 → urgency 1 … conf 1 → urgency 5).
  • **Author accumulation (§8)** sums that derived per-video urgency per creator →
    research a creator whose videos are consistently low-confidence.
  • **Decode 2 shrinks to TERM EXTRACTION ONLY** ("which subject to look up"),
    gated to run only when the video is uncertain (decline / low aggregate conf);
    the term inherits the video's derived urgency. `ResearchNeed` loses its
    model-emitted `urgency`. Keeps only what the model does well (copy a span),
    all urgency flowing from the calibrated confidence. Supersedes §2.2/§2.4's
    "urgency graded by the model."
- 2026-09-17 — **Reworked Decode 2 to the reframe + re-smoked (validated).**
  `ResearchNeed` keeps a derived urgency; added `ResearchUrgency.fromTagConfidences`
  (inverse mean, decline = 5); `researchNeeds` now returns `[String]` terms only,
  grammar is a quoted-term list, `parseResearchTerms` extracts spans; `needs` eval
  mode prints the derived urgency; 9/9 unit tests + core suite green. Live smoke
  (dev 7B, 12 items): **derived-urgency varies correctly** — declines → 5, high-conf
  (Clash Royale/Ludwig/Strength SMP) → 2, mixed → 3–4. Term extraction fires rarely
  on mainstream content (expected — the 7B recognizes it) with one minor leading-
  punctuation artifact (`:皇室戰爭`); terms are the secondary signal now, urgency the
  primary. Decode-2 mechanism + the derived-urgency signal are done for Phase 2;
  gating term-extraction on uncertainty + author accumulation are Phase 3.
- 2026-09-17 — **Phase 3 landed (a/b/c).** (3a) `ResearchTask.urgency` + the queue
  drains highest-urgency first (was FIFO); ordering test. (3b) research fires on a
  video's DERIVED urgency (`ResearchUrgency.fromTagConfidences`) reaching a new
  `ResearchSettings.urgencyFloor` (default 3) — replaces the `trigger` modes +
  `confidenceTriggerLevel` at the trigger point; derived urgency threaded to the
  queue at all enqueue sites. (3c) **author accumulation** — new persisted
  `WorkspaceCatalog.creatorResearchAccumulators` + `AuthorResearchThreshold{level,
  count,windowDays}` (owner-confirmed default **L3/N5/W30**): every model classify
  adds its derived urgency to the creator's windowed accumulator; ≥N samples
  averaging ≥L → one author research task (urgency = the mean), then reset. Replaces
  the old "append the creator handle when the histogram is weak" heuristic
  (main-path `includeCreator` now false). 157 core tests green (incl. urgency-trigger,
  queue-ordering, and 4 accumulator tests). Still open: wire Decode 2
  (`researchNeeds`) in place of `extractResearchSubject` (parts plumbing); settings
  collapse (§9) + removing `trigger`/`confidenceTriggerLevel`/`maxSubjectsPerVideo`
  + raw-search (Cut A, needs file-deletion consent).
- 2026-09-17 — **Decode 2 wired into the live research path.** The classify loop
  captures `primaryPromptParts` (strings only) for videos that will trigger
  research; the detached scheduler runs `researchNeeds` over that SAME
  classification prompt and researches the copied terms (capped by
  `maxSubjectsPerVideo`). Falls back to the legacy single-subject
  `extractResearchSubject` when the engine lacks Decode 2, no parts were captured
  (correction path), or Decode 2 returns nothing (it is conservative on
  recognized content). Test covers both the Decode-2 path and the fallback.
  Note: the decode runs detached, so the KV prefix is usually cold by then —
  correct, but the §5 KV-reuse saving only materializes if it is moved inline.
- 2026-09-17 — **Phase 4: settings collapse + UI.** Removed `ResearchTrigger` and
  the `trigger` / `confidenceTriggerLevel` / `maxSubjectsPerVideo` settings (the cap
  is now the fixed `ResearchTask.maximumSubjects`; the pipeline's creator-grounding
  floor is its own constant, 2). **Legacy states migrate on decode**: `declineOnly`/
  `correctionsOnly` → floor 5; `declineAndLowConfidence`/`all` → `6 − level`; retired
  keys never re-encode. **`urgencyFloor` default is now 5 (declines only)** — the
  pre-redesign default — because 3b's interim default of 3 would have silently
  widened research spend; presets map gentle/localOnly → 5, balanced/strict → 4
  (exactly their old triggers). **Correction-triggered research is gone** (it was
  the `correctionsOnly`/`all` modes, off by default; a human-corrected video has no
  uncertainty left) and the scheduler helper lost its correction-only parameters.
  Web shell: the Trigger group is one "Research when" select (5 plain-language
  levels) plus a new "Creator research" group (videos / level / window days), in
  both the global and per-type forms; bridge keys `urgencyFloor`, `authorLevel`,
  `authorCount`, `authorWindowDays`. 221/221 tests. Remaining: raw-search removal
  (Cut A — `searchMode`, `webSearchProviderProfileID`, `searchResultCount`,
  `snippetContextChars`, `RawWebSearchProtocol.swift`; needs file-deletion consent).
- 2026-09-17 — **Cut A done: raw search removed (owner consented to deleting
  `RawWebSearchProtocol.swift`).** Research is provider-grounding only: one call to
  a grounding-capable provider (OpenAI / Gemini / Anthropic) that searches natively.
  Removed `ResearchSearchMode`, `searchMode`, `webSearchProviderProfileID`,
  `searchResultCount`, `snippetContextChars`, the executor's raw-search leg, and the
  search-provider half of `GroundedResearchProviderConfiguration`; legacy keys are
  ignored on decode and never re-encoded. **Serper / You.com provider TYPES stay
  decodable** (a saved profile + key is never silently dropped) but are retired:
  not offered in "add provider", untestable, flagged with an inactive notice. Web
  shell: no search-mode / web-search-provider / search-tuning fields; the research
  provider pickers list only grounding-capable profiles; the "Search specifics"
  group is now "Knowledge"; the data-flow disclosure was rewritten to match (up to
  three copied terms, creator handle only via accumulation, single provider).
  **Behavior change to know:** a user who had research enabled in raw-search mode
  with a non-grounding LLM (DeepSeek, Ollama, …) now gets no research until they
  pick a grounding-capable provider — `searchMode` previously DEFAULTED to raw.
  219/219 tests. **The redesign's planned phases are complete.**
- 2026-09-17 — **Comprehensive stage test (dev M1 Pro, Qwen2.5-7B unless noted).**
  PASS: clean build + 220/220; real prod + dev `state.json` decode under the new
  code (legacy trigger/raw-search keys, and 5,000 dev rows still carrying
  `unknownTerms`); `score` cap 1 = P0.58/R0.50/exact 58%, decline 38/55 — identical
  to the pre-Phase-3 baseline (no regression); `calib` still favours model
  confidence (ECE 0.299 vs softmax 0.367, conf≤2 = 0% correct); web shell rendered
  in a real browser from a mock payload — research form, grounding-only provider
  picker, retired-Serper notice all correct, no console errors; live
  `VaultFullLoopSmoke` (real engine → accumulator → real Gemini grounding → creator
  keyed with 7 sources → re-classify) completes. Fixed during the test: the smoke
  still assumed single-video creator research (now sets author count 1); Decode-2
  terms could keep stray edge punctuation (`:皇室戰爭`) — now trimmed.
  **FAIL — §10 Experiment 3 latency guardrail (<500 ms) is NOT met on the 7B:**
  new `latency` eval mode → Decode 1 median 458 ms / **p90 1,242 ms**; Decode 2
  (warm KV) median 549 ms. 3B: 405 / 268 ms. Cause (llama-bench: prefill 263 tok/s,
  generation 26 tok/s = 38 ms/token): the structured decode GENERATES ~8 tokens per
  tag (`Name","confidence":N`) vs ~2–3 for name-only, so model confidence costs
  ≈ +200 ms/video — double §3's estimate — and Decode 2's ~110-token ask is ~420 ms
  of prefill even when it returns `[]` (so it must stay detached, never inline).
  The p90 tail is long evidence suffixes (creator prior + correction exemplars).
  **Proposed fix (not done — needs calib+score re-validation):** the
  `","confidence":` boilerplate is grammar-forced, so PREFILL it as one batch after
  the name instead of sampling it token by token (~190 ms → ~20 ms); and shorten
  the Decode-2 ask. **Also still open:** §9's "per-type overrides shrink to on/off"
  was never done (types can still override every research field); few-shot
  calibration; each knowledge write re-classifies the video (the smoke showed 4–5
  redundant re-classifies of one video).
