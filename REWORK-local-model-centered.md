# Vault Classifier — Rework: local-model-centered, per-video, grounded-search

> **Status:** DESIGN CLOSED (2026-08-06) — implementing. Target for the unattended run: "max real progress, kept green" (Phase 0 → Phase 1 → Phase 2 core; every checkpoint builds + passes tests; remainder scaffolded + documented here).
> Last updated: 2026-08-06.

## 1. Vision

| Axis | From (today) | To (target) |
|---|---|---|
| Primary classifier | Creator decisions; local model is a fallback | **Local neural model**, per individual video |
| Classification target | The **creator/source** | The **individual video/entry** |
| Pill shows | The creator's approved tags | **That video's own tags** (per-video only) |
| LLM's job | Classify creators; web-search optional | **Grounded web-search research**, on-demand, to fill gaps |
| Ungrounded LLM (`.off`) | Supported | **Removed** |
| Creator classification | The backbone | **Eliminated** — a creator's tags are *derived* by aggregating its videos' tags; supplied to the model only as a partial (view-history) prior |

## 2. Current architecture (as-is, from code)

- **Unit:** `ClassifierTypeAsset` owns a tag tree (1:1) + optional local model, targets one platform; multiple types per platform union tags.
- **Target = creator.** `CreatorClassificationRecord` (approved manual/LLM) stores a creator's tags; pills call `LocalStore.sourceTags(platformID:sourceID:)`.
- **Local model** (`EmbeddedNeuralTextClassifier`): trained on approved creator decisions → per-entry text; used as per-entry blend + pill **fallback** only.
- **LLM assist:** `classifyCreatorBatchWithLLM`; `webSearchMode ∈ {.off, .attached, .providerNative}` (`.off` = ungrounded). Approved decisions train the local model.
- **Collected data:** per-platform `CollectedPlatformEntry`, shared dataset, cap 5,000, deduped.

## 3. Target architecture — resolved pipeline

The local model is no longer a plain title classifier; it becomes a **context-aware per-video classifier** wrapped in a small pipeline.

**Local model INPUT (per video):**
- The current video's own evidence (title / summary / text).
- **Creator prior (derived):** the creator's **tag-frequency histogram**, aggregated from *its own already-classified videos* — there is no separate creator classification. **Prompt caveat (required):** this histogram is built only from videos in **the user's view history**, so it is a **partial, possibly-biased sample** — it does NOT define the creator's full range and must be treated as a weak prior, not ground truth.
- **Knowledge-store resolutions** for salient terms seen in the title (from prior research).

**Local model OUTPUT (per video):**
- Predicted tags + confidence → **the pill** (per-video only; shown immediately, provisional if low-confidence).
- **"What it doesn't know":** the salient terms/entities it could not resolve.
- Dynamic weak-title handling: the model decides per video whether the current title is informative; if not, it leans on the creator's derived tag-frequency prior (weighted as the partial, view-biased sample it is). Realized inside the model's input, not a hard-coded branch.

**Gap handling — background-queued (never blocks the pill):**
1. Terms the model flags as unknown → queue **grounded research** on each term.
2. _(Under review — see §7.6)_ Creator research now has a narrower role, since a creator's tags are derived from its videos. Remaining candidate case: a creator ALL of whose seen videos have weak titles (so the derived histogram is empty) → grounded research on the creator's identity to bootstrap. Otherwise creator research is dropped.
3. Research = LLM **with web search only** (grounded). It returns grounded **knowledge only** (the model still assigns tags — Q11).
4. Result is written **both** to a persistent **knowledge store** (term/creator → meaning + tags), consulted instantly at classify time, **and** emitted as **training examples** so the model durably learns.
5. The pill upgrades when research returns; a gap is filled once, not re-researched.

**Removed:** ungrounded `.off` / prompt-only LLM classification. **Reset:** greenfield, dev only.

## 4. Open questions

**Resolved:**
- ✅ **Q1 Pill target** — per-video only.
- ✅ **Q2 Grounded search** — on-demand research to fill gaps (unknown terms; uninformative-title creators); not a bulk labeler.
- ✅ **Q3 Creator role** — weak-evidence context fed into the model (not a separate fallback branch).
- ✅ **Q4 Migration** — greenfield reset, dev only.
- ✅ **Q5 Weak-evidence trigger** — dynamic; the model, given the creator's prior tags/titles, decides if the current title is weak and leans on prior titles / creator research.
- ✅ **Q6 Research timing** — background-queued; pill upgrades on return.
- ✅ **Q7 Unknown-term detection** — the model **outputs what it doesn't know** (surfaced as unresolved salient terms). _Mechanism to implement: OOV / low-confidence salient tokens — see Q13._
- ✅ **Q8 Learning loop** — both a knowledge store (instant reuse) and training examples (durable learning).

**Resolved (cont.):**
- ✅ **Q11 Grounded research output** — knowledge only. Research gathers grounded facts into the knowledge store; the **local model always assigns the tags**. The LLM never labels.
- ✅ **Q9 Unit** — keep `ClassifierTypeAsset` (tree + model + platform, multi-type-per-platform).

**Resolved (pivotal):**
- ✅ **Q14 — The "local model" is an on-device LLM** doing **zero-shot** classification against the tag tree. Replaces `EmbeddedNeuralTextClassifier` entirely. It already has general world knowledge (cold start works); grounded web-search only for genuinely niche terms.

**✅ Q15 SCOPE — "learning" = (i) + (ii) only:**
Because the model is now a capable LLM, learning is **not** about teaching it the world. It is exactly two things:
- **(i) Niche knowledge** it lacks (HermitCraft, a tiny creator) → the **knowledge store** (RAG). _Settled (Q8/Q11)._
- **(ii) YOUR taxonomy & corrections** — how *this user* wants borderline items tagged, and disagreements with the LLM → **few-shot example store (RAG)** vs **on-device fine-tuning (LoRA)**. ← the remaining sub-fork.

**Not "learning" — but still required (serving layer):**
- **Decision memory + batching** — classify a video/creator once and reuse; batch titles per LLM call; optional cheap pre-filter. This is a *performance* concern (a local LLM per card on a scrolling feed is expensive), designed into the core, not part of "learning."

**Resolved:**
- ✅ **Q15b — (ii) mechanism = RAG, no fine-tuning in v1.** Refined via the "train vs map" question:
  - **Facts (researched creators, special nouns) → the retrieval map, ALWAYS. Never fine-tune** them in — small LLMs don't reliably memorize rare facts from few examples (lossy/hallucinated). Retrieval is the correct, reliable tool.
  - **Preferences (user-corrected tags) → cached house-rules (C1)** in the prefix (a distilled form). Behavior, not facts — the one thing fine-tuning is good at, but cached rules capture it cheaper, resettable, inspectable.
  - **Periodic on-device fine-tuning is feasible** (MLX LoRA on Apple Silicon; adapters, minutes) but is a **deferred/optional optimization** — only payoff is shortening the preference prompt once corrections grow large, and **never** used for facts. Not needed for v1. (In-app Swift training is heavier than Python `mlx-lm` — weigh before adopting.)
  - **The map scales for free:** keyed store; only entries matched to the current video (creator entry + term-keys in the title) are injected, so a huge map doesn't affect per-video latency.
- ✅ **Q16 — Runtime = MLX-Swift; the model is USER-SELECTABLE, not fixed.** A curated catalog of on-device models (e.g. ~0.5B / 1B / 3B / 7–8B, 4-bit), **downloaded on demand** (not bundled). The app recommends a default from detected hardware (RAM/chip) and shows the **measured decision latency** for the chosen model on *this* Mac (green < 500 ms / danger 500 ms–1 s / reject > 1 s), so a user on weaker hardware or wanting faster pills picks smaller, a user on a powerful Mac picks smarter. One model is active app-wide (shared inference engine); all classifier types share it, prompts vary per type. llama.cpp fallback. Apple Foundation Models deprioritized (no prefix-cache / constrained-decode control).

**Serving constraints (from Q16) — first-class in the design:**
- **Latency budget (revised 2026-08-06):** **< 500 ms/decision = fine**; **500 ms–1 s = danger zone**; **> 1 s = unacceptable**. This relaxes the earlier 100 ms and lets us run a **more capable ~3B model**, meaning fewer unknown-term misses and better structured output.
- **Prompt-prefix KV caching:** the static prefix (task instructions + tag-tree definitions + house-rules) is cached once; only the per-video suffix (title + creator context + retrieved knowledge/examples) is processed per call.
- **Constrained decoding** to tag names (short, schema-valid output).
- **Batching** across a viewport of cards; **decision cache** so a video/creator is classified once.
- **De-risk with a latency spike (Phase 0)** — now comfortably achievable, but still validate 1B vs 3B against the <500 ms line on the actual Mac before committing.

**Still open:**
- **Q13 — Unknown-term surfacing** — a structured LLM output field listing unfamiliar entities is natural here (the model returns `{tags, unknownTerms}`). → _pending, low-risk_
- Prompt/schema contract; per-video decision-record shape; knowledge-store & corrections-store schema. → _design during Phase 1._

## 5. Phasing

**Phase 0 — Latency spike (de-risk FIRST).** Add MLX-Swift; load **1B and 3B** 4-bit models; benchmark on-device: static-prefix-cached classify of a title → a few tag names (constrained decode). Target **< 500 ms/decision** (danger 500 ms–1 s; reject > 1 s); confirm prefix-cache + batching behavior. Deliverable is a **model-load + benchmark harness** (the seed of the catalog/loader in §7.5), plus real numbers per model — not a single hardcoded pick. _Evidence before commitment._

**Phase 1 — Data model (runtime-agnostic).** Per-video **decision record** as the primary label store (replaces creator-centric primary); **knowledge store** (term/creator → grounded meaning); **corrections/examples store** (user preference few-shot); **creator-context provider** (prior tags/titles); keep `ClassifierTypeAsset` unit (tree + LLM/research config + stores + platform). Greenfield reset. Build + tests.

**Phase 2 — Classification pipeline + model management.** Model catalog + on-demand downloader + hardware-aware default + self-benchmark (§7.5). Prompt assembler (cached static prefix = task + tree + house-rules; dynamic suffix = title + creator context + retrieved knowledge) → active local LLM → `{tags, confidence, unknownTerms}` via constrained decoding. Decision cache + batching. Pills = per-video tags, shown immediately.

**Phase 3 — Grounded research + learning loop.** Delete `.off`/ungrounded; grounded web-search only. Background queue: `unknownTerms` → research term; weak-title creators → research creator. Research (knowledge only) → knowledge store; user corrections → corrections store. Pill upgrades on return.

**Phase 4 — UI.** **Model picker** (catalog, download progress, per-model latency readout + green/danger/reject band, hardware-recommended default) in Settings; classifier-type config → grounded-research settings; knowledge/corrections review; remove ungrounded controls; creator UI reduced to context.

**Phase 5 — Cleanup/style.** Remove `EmbeddedNeuralTextClassifier`, creator-first `sourceTags`, dead LLM-creator batch paths; flat-style pass.

## 7. Design details (paper — nailing before the spike)

### 7.1 Classification I/O contract
- **Prompt = cached static prefix + dynamic suffix.**
  - **Static (KV-cached):** task rules + the tag tree rendered with **readable tag names/slugs + descriptions + hierarchy** (not UUIDs — so the model reasons over meaning). Same for every video → cache its KV once.
  - **Dynamic (per video):** matched **knowledge** for terms/creator; a few retrieved **correction examples**; **creator context** (recent tags/titles); the **video title** (+ summary/text when available).
- **Output (constrained JSON):** `{ tags: [{ name, confidence }], unknownTerms: [string…] }`; map name→ID; constrain names to the allowed set. **Confidence is a discrete 1–5** (coarse = more reliable for a small LLM). **Prefer logprob-derived confidence** — the model's actual probability mass on each chosen tag under constrained decode, bucketed to 1–5 — over self-reported, because self-reported LLM confidence is poorly calibrated (the user's stated doubt). Fall back to self-reported 1–5 only if the runtime doesn't expose logprobs.
- **Unknown-term surfacing (Q13):** the prompt instructs the model to list salient named entities it can't confidently interpret. No OOV heuristic — the LLM does it natively. _(supersedes earlier OOV idea)_
- **Weak-title handling:** creator context is in the input; the model leans on it when the title is thin; low `confidence` = still weak after that → creator/term research.

### 7.2 Stores
- **VideoClassification** (per-video primary label + decision cache): platform, entryID, creatorID, tags, confidence, source (`model` / `model+knowledge` / `human-corrected`), knowledgeRefs, version, ts.
- **KnowledgeEntry** (term/creator → grounded meaning): key (`term:…` / `creator:…`), meaning, optional non-authoritative context-tag hints, source URLs, ts/staleness. Injected at classify time by **creator-key lookup + substring match of known term-keys against the title** (breaks the chicken-egg: first sight → model flags unknown → research → stored; later sights → matched in).
- **CorrectionExample** (preference few-shot): title+context, correctTags, optional note, retrieval key (→ fork D), ts.
- **Creator prior = derived, no creator-classification record.** A materialized **CreatorTagHistogram** (creatorID → tag → **average confidence 1–5** across that creator's videos). **Count all** classified videos (no confidence gate); each tag's histogram value is the *mean* of its per-video confidences, so weakly-tagged videos naturally contribute little weight. Incrementally maintained (running mean per tag), O(1) lookup at classify time. Explicitly scoped to seen (view-history) videos; fed to the model with the "partial/biased sample" caveat.

### 7.3 Research triggering (cost control)
- Sources: `unknownTerms` (term research) + consistently-weak-title creators (creator research).
- Background queue; grounded web-search only; **knowledge-only** result → KnowledgeEntry; pill upgrades. Dedup + rate-limit. (→ fork on first-sight vs recurrence-gated.)

### 7.4 Forks
- ✅ **Fork A — Tag policy = user-configurable per classifier type** (max tags; leaves-only vs any-level; single vs multi). Sensible default (a few leaves + ancestors), overridable in the type's config.
- ✅ **Fork B — Research trigger = first sight.** The first time the model flags an unknown term, research it (dedup so a term is researched once; light rate-limit as a safety valve).
- **🔬 Fork C — how corrections shape the model (deliberating).** Earlier options were all "retrieve examples." A better fit given prefix caching may be **distilling corrections into cached house-rules**:
  - **C1 — Distilled house-rules in the cached prefix (+ recent raw corrections).** Periodically summarize corrections into a short "house rules" block (e.g. "tag gaming-news as news, not gaming"); it lives in the *cached* static prefix, so it's ~free per video and always applied. Append the last few raw corrections for recency. No embedding model, no per-video retrieval.
  - **C2 — Keyword/creator retrieval** of raw corrections into the dynamic suffix.
  - **C3 — Semantic (embedding) retrieval.** Best case-matching, adds an embedding model + vector store.
  - **C4 — Hybrid** (keyword prefilter → semantic rerank; or rules + retrieval).
  - _Leaning C1:_ corrections mostly encode *general taxonomy preferences* (rules), not title-specific facts; rules-in-prefix is cacheable, cheap, always-on, and needs no new model. Trade-off: coarser than examples for one-off edge cases, and needs an occasional LLM distillation pass.

### 7.5 Model management (user-selectable local model)
- **Curated catalog:** a small list of vetted on-device models (id, display name, params, quantization, download size, min-RAM hint, source URL/repo). Not arbitrary user URLs in v1.
- **Required capability flags — models lacking these are excluded/deprioritized:**
  - **Reliable fixed-output** — follows a constrained schema / structured-output well (some models are trained for JSON/tool schemas and hold up far better under grammar-constrained decode; those are inherently preferred).
  - **Prefix-cache friendly** — plays well with prompt-prefix KV-cache reuse for the static prefix.
  - Catalog entries carry these flags; the picker hides/marks models that don't qualify.
- **On-demand download** with progress + integrity check; stored outside the app bundle; removable to reclaim space.
- **Hardware-aware default:** recommend a model from detected RAM/chip; user can override up or down.
- **On-device latency readout:** after selecting/loading, run a quick self-benchmark and show median decision ms with the green/danger/reject band, so the trade-off is concrete on *their* machine.
- **One active model app-wide** (shared MLX engine); switching reloads the engine. Classifier types share it; only prompts differ.
- **Graceful states:** no model downloaded yet → prompt to pick one (pills paused with a clear reason); model too slow → surface the danger-band warning.

### 7.6 Creator research — proposal: unify into term research
Creator *classification* is eliminated. For creator *research* (grounding a creator's identity), rather than a separate pipeline + heuristic trigger, **fold it into the existing unknown-term path**:
- The model may list an **unfamiliar/salient creator name in `unknownTerms`** (naturally the case when the title is weak and the creator is unknown).
- The **same term-research path** grounds it → stored in the knowledge map under the creator key → injected into future videos of that creator (creator-key lookup already planned).
- **No separate "all-weak-titles" heuristic, no second research trigger.** The model decides when a creator is worth grounding; it stays video-centric.
→ ✅ **RESOLVED — option A (unify into term research).** Unknown creators are surfaced in `unknownTerms`; the one research path grounds them under the creator key. No separate creator-research trigger.

## 6. Decisions log

- **2026-08-06 — Pill per-video only** (Q1).
- **2026-08-06 — Grounded search = on-demand research** for unknown terms + uninformative-title creators (Q2).
- **2026-08-06 — Creator = weak-evidence context fed to the model, dynamic** (Q3, Q5). The model, given the creator's prior tags/titles, decides if the current title is weak and leans on prior titles / creator research.
- **2026-08-06 — Greenfield reset, dev only** (Q4).
- **2026-08-06 — Research is background-queued; pill upgrades on return** (Q6).
- **2026-08-06 — Unknown terms are surfaced by the model itself** (Q7).
- **2026-08-06 — Feedback loop = knowledge store + training examples** (Q8).
- **2026-08-06 — Grounded research returns knowledge only; the local model assigns tags** (Q11). LLM never labels.
- **2026-08-06 — Keep the classifier-type unit** (Q9).
- **2026-08-06 — ⚠ Cold-start expectation ("capable pill at the start") is incompatible with the current from-scratch classifier** (Q12) → opened pivotal Q14 (what the local model actually is).
- **2026-08-06 — Local model = on-device LLM, zero-shot against the tree** (Q14). Replaces `EmbeddedNeuralTextClassifier`.
- **2026-08-06 — Cold start: show a capable pill immediately** (Q12), enabled by Q14.
- **2026-08-06 — "Learning" scope = (i) niche knowledge + (ii) user preferences** (Q15). Decision memory + batching is a serving/perf layer, not "learning".
- **2026-08-06 — (ii) preference learning = RAG few-shot, no fine-tuning in v1** (Q15b; user deferred, my recommendation). LoRA only if prompts grow too long.
- **2026-08-06 — Train vs map: facts→map always (never fine-tune facts); preferences→cached rules; periodic LoRA feasible but deferred/optional and never for facts.** The keyed map scales without hurting per-video latency (only matched entries injected).
- **2026-08-06 — C1 confirmed: corrections → distilled house-rules in the cached static prefix** (+ recent raw corrections). Cached prefix is definitely happening.
- **2026-08-06 — Runtime = MLX-Swift + small ~1B quantized model** (Q16; user deferred but set constraints: ~100 ms/decision, small, few tags out, cacheable static prefix). Prompt-prefix KV cache + constrained decode + batching + decision cache are first-class. Apple Foundation Models rejected (no cache/latency control). **100 ms live is aggressive → Phase 0 latency spike de-risks it first.**
- **2026-08-06 — Tag policy is user-configurable per classifier type** (Fork A); default a few leaves + ancestors.
- **2026-08-06 — Unknown-term research triggers on first sight** (Fork B), deduped + rate-limited.
- **2026-08-06 — Output = `{tags(readable names), confidence, unknownTerms}`, constrained decode; unknown terms asked of the LLM directly** (§7.1).
- **2026-08-15 — Phase-0 latency verdict (via llama.cpp fallback, M1 Pro 16 GB): 3B 4-bit + constrained decode = median 454 ms GREEN with 7/8 accuracy; 1B is no faster under constraint (423 ms) and much dumber. Grammar-constrained decode measured latency-free.** MLX numbers pending: Xcode 26.3's downloadable Metal Toolchain can't be fetched on this network (pallas catalog endpoint connection-reset; manual dmg import or VPN unblocks). llama.cpp promoted from "fallback" to proven candidate runtime — it ships grammar support and needs no Metal toolchain.
- **2026-08-16 — Runtime = llama.cpp IN-PROCESS; the stub is retired.** `VaultLocalLLMEngine` ships the final contract (name-only grammar + reserved `none` decline + scaffold-in-prompt + renormalized-logprob confidence + prefix-cache reuse): **120 ms median, 8/8**, live end-to-end behind pills. The `none` literal exists because a grammar with no decline FORCES a tag onto every video — made vivid by a one-tag test taxonomy tagging the whole feed. MLX demoted to optional future alternative.
- **2026-08-06 — Latency budget relaxed: < 500 ms fine, 500 ms–1 s danger, > 1 s unacceptable** (was 100 ms). Unlocks a ~3B model → more capable zero-shot + fewer research escalations. Spike benchmarks 1B vs 3B.
- **2026-08-06 — Model is USER-SELECTABLE, not fixed** (§7.5). Curated catalog (~0.5B–8B), on-demand download, hardware-aware default, on-device latency readout with green/danger/reject band. One model active app-wide. Weaker hardware / faster pills → smaller; powerful Mac → smarter.
- **2026-08-06 — Catalog gates on model capability** (§7.5): reliable fixed/structured output + prefix-cache friendliness are required flags; models without them are excluded/deprioritized.
- **2026-08-06 — Creator classification ELIMINATED** (supersedes Q3). A creator's tags are *derived* by aggregating its own videos' classifications into a materialized **CreatorTagHistogram**. Fed to the model as a **weak prior with a required caveat that it's from the user's view history** (a partial, biased sample — not the creator's full range).
- **2026-08-06 — Confidence = discrete 1–5 per tag; prefer logprob-derived over self-reported** (LLM self-confidence is poorly calibrated). Creator histogram = **average** per-tag confidence over **all** the creator's videos (no gate — the mean naturally down-weights weak tags).
- **2026-08-06 — ✅ Creator research = unified into the unknown-term path (option A).** Model lists an unfamiliar creator as an unknownTerm → same research → knowledge map under creator key. No separate trigger.
- **2026-08-06 — ✅ Confidence = logprob-derived, bucketed 1–5** (confirmed). Histogram averages per-tag.
- **2026-08-06 — DESIGN CLOSED. Autonomous run target: max real progress, kept green.**

## 8. Build log (unattended run, 2026-08-06)

- **Reorder rationale:** doing runtime-agnostic Phase 1/2 first (additive, guaranteed-green), with the MLX Phase-0 spike attempted isolated afterward so a heavy/failing MLX build can't red the main project. Env confirmed capable: macOS 15.6.1, Apple Silicon, Swift 6.2, network reaches GitHub + Hugging Face.
- **Phase 1 (data model) — DONE, green.** New file `Sources/VaultClassifierCore/LocalLLMModel.swift`: `ScoredTag` (clamped 1–5), `VideoClassification` (+ source, unknownTerms, knowledgeRefs), `KnowledgeEntry` (term/creator keyed, title-substring match), `CorrectionExample`, `CreatorTagStat`/`CreatorTagHistogram` (count-all averaged prior). Wired 4 additive arrays into `WorkspaceCatalog` (props/init/CodingKeys/decoder; old state still loads). Catalog helpers: `upsertVideoClassification` (+ histogram rebuild), `matchedKnowledge`, `upsertKnowledgeEntry`, `rebuild*Histograms`, `validateLocalLLMStores`. Tests: `LocalLLMModelTests` (12). **Full suite 184/184 green.**
- **Greenfield reset:** not performed — additive changes keep old `state.json` loading. Actual wipe deferred to cleanup (when old fields are removed); back up `state.json` then.
- **Phase 2 (core) — DONE, green.** Runtime-agnostic classification core, all behind an interface so no MLX dependency in the main package:
  - `OnDeviceLLM.swift` — inference protocol + request/result types + `StubOnDeviceLLM` (deterministic stand-in).
  - `ClassificationPromptAssembler.swift` — cached static prefix (task + readable taxonomy + house-rules) + per-video dynamic suffix (matched knowledge, creator prior WITH the view-history caveat, title). Deterministic for KV-cache stability.
  - `VideoClassificationPipeline.swift` — assemble → run LLM → map readable names→tag ids (drop unknowns, dedupe by max confidence) → `VideoClassification`; source = model/modelKnowledge.
  - `LocalModelCatalog.swift` — curated user-selectable models with required capability flags (fixed output + prefix cache), `recommended(systemRAMGB:)` hardware default, `LatencyBand` (green/danger/reject), `HardwareProfile.physicalRAMGB()`.
  - Tests: `VideoClassificationPipelineTests` (7), `LocalModelCatalogTests` (7). **Main suite 198/198 green** (26 new this run).
- **Phase 0 (MLX spike) — BLOCKED on Metal Toolchain; latency question ANSWERED via llama.cpp fallback (2026-08-15).** The `swift run` path can never work — mlx-swift's README: SwiftPM (command line) cannot build Metal shaders. The `xcodebuild` path compiles everything but Xcode 26.3 ships the Metal compiler as a downloadable component, and `xcodebuild -downloadComponent MetalToolchain` fails on this network: the pallas catalog POST (`gdmf.apple.com/v2/assets`) gets connection-reset while every other Apple host answers. Unblock = VPN for that one endpoint, or manual "Metal Toolchain" dmg from developer.apple.com (that host IS reachable) + `xcodebuild -importComponent MetalToolchain -importPath <dmg>`.
  **Fallback numbers** (llama.cpp b10360 via Homebrew, Metal, `llama-server` + `cache_prompt`, spike prompt/titles verbatim, temp 0, M1 Pro 16 GB):
  - **1B Q4_K_M, unconstrained:** median **442 ms → GREEN**, but output is garbage — invents off-taxonomy tags, tags lofi as Minecraft. Confirms constrained decode is load-bearing, as designed.
  - **1B Q4_K_M + GBNF grammar:** median **397–423 ms → GREEN**. Format perfect, accuracy still poor (defaults to Minecraft). Breakdown: prefill 122 ms/105 tok uncached → **42 ms cached**; generation **~333 ms for ~36 tok (~9.2 ms/tok)** — it pads out every tag slot the grammar allows, never stopping early.
  - **3B Q4_K_M + GBNF grammar:** median **454–485 ms → GREEN**, **7/8 correct** incl. HermitCraft→Minecraft inference. Breakdown: prefill 321 ms/105 tok uncached → **90 ms cached** (KV prefix cache works as designed); generation **~357 ms for ~17 tok (~21 ms/tok)** — commits to one tag and stops.
  - **Why 1B ≈ 3B wall-clock (verified, not an artifact):** 3B is 2.3× slower per token exactly as expected, but the 1B generates ~2× the tokens because it can't decide to stop — the products coincide. Lessons: **stop behavior is a latency feature**, and the **output contract sets the floor** — generation dominates (~70% of total).
  - **Latency levers, measured (3B Q4, M1 Pro, all GREEN):** (a) full-JSON grammar output: **485 ms**, 7/8 correct — baseline. (b) bare terse output (`<tag> <confidence>`): **197 ms** but accuracy collapses to 5/8 — the JSON scaffold was acting as a structural runway the model conditions on before committing. (c) scaffold-in-prompt hybrid — runway prefilled in the prompt (~free), grammar forces `name","confidence":N}]}` (~8 decode tok): **254 ms, accuracy preserved (~7/8)**. (d) speculative decoding (1B draft): **no effect** — llama.cpp's speculative path does not engage under grammar-constrained sampling; not a lever while the grammar stays. (e) **FINAL CONTRACT — name-only output + logprob confidence: 133 ms median, accuracy preserved (7/8), confidence signal *improved*.** Grammar emits the tag name alone (~2 decode tok); the prompt keeps the full format instruction AND ends with the JSON scaffold the model never writes (removing either regressed accuracy to 5/8 — the runway is load-bearing even unwritten). Confidence = `exp(logprob)` of the chosen token, zero output cost and finally calibrated: 98–99 % on clear cases, 74 % on the Gaming/Minecraft tension, **37 % on the no-good-answer case that self-reported confidence had called 4/5**. Low p is the natural `unknownTerms`/research trigger, moving that field off the hot path entirely. Remaining floor: ~75 ms cached prefill + ~30 ms request overhead → in-process engine + prefetch-at-collection are the next levers.
  **Verdict: 3B 4-bit + constrained decode is the recommendation seed for `LocalModelCatalog` on M1 Pro-class hardware** — GREEN latency and real accuracy. llama.cpp is a *proven* runtime (grammar support built-in, no toolchain friction); MLX-vs-llama.cpp is now a choice, not a bet. MLX numbers still pending the toolchain unblock.

### Remaining (next sessions)
- **Phase 0 — DONE (2026-08-16, llama.cpp in-process; MLX now optional).** `VaultLocalLLMEngine` (new `VaultClassifierLLM` target) is a real `OnDeviceLLM`: Homebrew libllama linked via pkg-config (`Cllama` system library; Metal kernels JIT at runtime — no Metal Toolchain needed), grammar-constrained name-only decode with the reserved `none` decline literal, scaffold-in-prompt runway (assembler updated), confidence = softmax renormalized over the legal first tokens (+`none`), static-prefix KV reuse via longest-common-prefix truncation, actor-serialized context. Model discovery: `ADAMANCIA_VAULT_LLM_MODEL` or `<support>/models/*.gguf`. The app installs it at launch (`engine-loaded` in dev log), replacing `StubOnDeviceLLM`. Benchmarked via `swift run -c release VaultLLMEngineSmoke`: **120 ms median, 8/8, calibrated 1–5 confidences** on M1 Pro. Live E2E confirmed (real classifications + push + pills). MLX remains a future alternative if its prefill/jump-forward control ever pays for the toolchain friction.
- **Stale-decision recompute:** `cachedVideoTags` ignores `modelVersion`, so stub-era (and any pre-model-change) classifications persist until manually cleared — add the planned recompute pass.
- **Phase 2 finish:** host wiring so pills call `VideoClassificationPipeline` (batched + decision cache) instead of creator `sourceTags`; model download manager + self-benchmark; web-snapshot projection of the new stores.
- **Phase 3:** grounded-research background queue (first-sight unknown terms incl. unfamiliar creators) → knowledge map; delete ungrounded `.off`; corrections → distilled house-rules pass.
- **Phase 4:** model picker UI + knowledge/corrections review; remove ungrounded controls.
- **Phase 5:** remove `EmbeddedNeuralTextClassifier` + creator-first `sourceTags` + the temp `[VaultPerf]` instrumentation; greenfield-reset (back up `state.json` first); flat-style pass.

## 9. Build log — continuation (per-video channel)

- **Native per-video path — DONE, green (201 Swift tests).** `LocalClassifierCoordinator` gained an injectable `OnDeviceLLM` (defaults to stub) + `classifyVideo(...)` (async; LLM runs outside the lock; upserts `VideoClassification`, refreshes creator histogram, persists) + `cachedVideoTags(...)` (decision cache) + union projection. New hub op `video-tags` (`NativeVideoTagsRequest`/`Response`, keyed by entryID + evidence, with a `pending` flag), app handler (cached → return; else queue background classify + report pending → pill upgrades on re-request), and the hub allowlist updated. Tests: `VideoClassificationCoordinatorTests` (3).
- **Extension per-video channel — DONE, green (jsc suite).** Contract `normalizeVideoTagsResponse` (entryID-keyed, `pending`) + export; bridge `videoTags(...)` function + `vault-classifier-video-tags` message listener (same sender-trust checks as source-tags). Tests: 4 new assertions in `runner-vault-classifier.js`, full extension suite green.

### Still NOT done (honest)
- **Pill rendering switch (extension `tag-ui`/`collector-core`):** the plumbing exists end-to-end, but the collector still requests creator `source-tags` for the visible pill. Switching `tag-ui` to key by video entryID + call `videoTags` is a browser-verification-dependent change (intricate cache/dedup/reattach logic) — deferred to do with a real browser, not blind + against a stub model.
- **Real model:** everything runs against `StubOnDeviceLLM`; wiring `MLXOnDeviceLLM` (Phase 0 finish: run the spike, add constrained decode + prefix cache) is what makes classification real.
- **Settings / API keys:** non-research provider keys still present (ungrounded LLM path not yet removed); pare to research/web-search providers only.
- **UI:** model picker, per-video display, knowledge/corrections review — not started.
- **Grounded research loop (Phase 3)** and **cleanup (Phase 5)** — not started.

## 10. Build log — per-video pill switch (#1)

- **Repo moved** to `/Users/fengyue.john.zhu/Desktop/programme/apps/blockerGroup` (old `Desktop/blockerGroup` link gone). Cleaned stale `.build`; all work intact.
- **Batch op:** `video-tags-batch` (native op + `NativeVideoTagsBatch*` types + app handler: cached items return, uncached report `pending:true` and get queued together; allowlist updated).
- **Extension:** `normalizeVideoTagsBatchResponse` (entryID-keyed, per-item `pending`) + export; bridge `videoTagsBatch()` + `vault-classifier-video-tags-batch` listener.
- **Pill switch (`tag-ui.js`):** rewritten per-video — identity = `entryID`; requests `video-tags(-batch)`; a `pending` reply renders a **"Tagging" placeholder pill** (muted, dashed, pulsing) cached with a short 2.5 s TTL so it upgrades quickly; `MAX_SOURCES` 128→512. `collector-core deliver()` now observes `{entryID, creatorID, title}` (creator pill retired; old `source-tags` native/bridge code left for Phase-5 cleanup).
- **Tests:** extension `jsc` suite green — updated `tag-ui`, `tag-ui-none` (+ new Tagging-placeholder phase), `reddit` collector; contract batch assertions. Swift 201/201 green.
- **Caveat:** still runs against `StubOnDeviceLLM`, so pills show **stub** tags (names literally present in the title). Real tags need the MLX wiring. Visual/browser confirmation on a real Reddit/Bilibili page is still worth a pass (the `jsc` suite proves the logic, not the live render).

## 11. Unified dev log (dev-only)

Cross-process debugging sink so the whole pill lifecycle lands in ONE grep-able file.
- **Sink:** `VaultDevLog` (Core), active only when `ADAMANCIA_VAULT_ENVIRONMENT=development`. File path from `ADAMANCIA_VAULT_DEV_LOG` (dev launch → `blockerGroup/misc/dev.log`), else the dev support dir. Size-rotated (5 MB, one backup). Line format: `<iso8601-ms> [layer] event k=v …` (fields sorted).
- **Native emitters:** `[app] launch`; `[native] video-tags` / `video-tags-batch` (outcome cached|empty-no-types|queued-pending, counts); `[classify] video` (types, tags); `[perf]` (routed from the old perfLog).
- **Extension forwarding:** new `dev-log` hub op + `NativeDevLogRequest`; bridge `forwardDevLog` + `vault-classifier-dev-log` listener; `tag-ui` emits `[tag-ui] observe` / `result` (gated on `globalSettings.debugMode`, cheap no-op otherwise). More layers (collector, adapters) can call the same `devLog`.
- **Correlate:** `grep 'entry=youtube:video:XYZ' misc/dev.log` → observe → hub → classify → result across all processes.
- **Launch:** `ADAMANCIA_VAULT_ENVIRONMENT=development ADAMANCIA_VAULT_DEV_LOG=<repo>/misc/dev.log .build/debug/VaultClassifierApp`. Extension forwarding needs the extension's debug mode ON.
- Dev-only; lines contain titles/creator ids; never active in production.
- **Auto-enable in dev:** the app reports `developmentMode` in its `collection-info` response; the bridge mirrors it to `chrome.storage.local.vaultDevMode`; `tag-ui` enables dev logging when `vaultDevMode` OR the manual `debugMode` is set. So dev logging is automatic when the extension talks to a dev-env app — no manual toggle.
