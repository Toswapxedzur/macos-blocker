# Vault Classifier — Latency Refinement (single 7B, feed-fast)

> **Status: Phases 1–2 BUILT (2026-09-17) — see §6a/§6b for what the measurements
> changed; §1's prefill claims are superseded.** Owner decision: keep a SINGLE
> model (the 7B quality model) — no 1B+7B pipeline. This plans the engine changes
> that make one 7B usable for a live feed. Design-doc-first (like
> `RESEARCH-REDESIGN.md`); do not build until settled.

## 1. The measured reality (M1 Pro, 16 GB, Qwen2.5-7B Q4_K_M, this session)

All layers offload to Metal (`MTL0`); the model is on the GPU.

- **Generation is memory-bandwidth-bound.** Every token re-reads the whole 4.36 GB
  of weights. `llama-bench`: **~25 tok/s = ~40 ms/token**, even at 512-token
  context. M1 Pro is ~200 GB/s → ~110 GB/s effective → 4.36 GB ÷ 110 = ~40 ms.
  **This floor cannot be coded away for a single stream.** (16 GB is plenty of
  *capacity*; the wall is *bandwidth*, and it is shared by the one GPU.)
- **Prefill is cached and ~free.** Static prefix (taxonomy+rules) is KV-reused
  across videos; per-video re-prefill measured **~3 ms**. Grammar build **0 ms**.
- **A first-token cost dominates short decodes.** Measured: a 1-token decline
  costs **~230 ms**, while each *additional* token in a long decode costs
  **~65 ms** (≈40 ms floor + ~25 ms debug/grammar overhead). So every decode
  carries a **~165 ms one-time cost** (the prefill→generation Metal transition),
  then streams.
- **Per-video totals today (debug eval, cap 1, model-confidence Decode 1):**
  decline ≈ 230 ms; **tagged ≈ 585 ms** (`Name","confidence":N` ≈ 6–7 tokens).
  Old name-only (softmax) would be ≈ 325 ms.
- **Serial engine.** The engine is one actor / one llama context. The extension
  already sends **16 concurrent / 32 per batch**, but they funnel into the single
  serial decoder, so its concurrency is wasted and a screenful drains one-by-one
  at ~1–2 tagged videos/s on the 7B.
- Reference: the 1B does ~130 tok/s (244 ms/classify) — not chosen, but it shows
  the bandwidth math (5.6× fewer bytes/token → ~5× faster).

## 2. The constraint, stated plainly

One GPU, one ~200 GB/s memory bus, one 7B. Single-stream latency is floored by
bandwidth. **Throughput therefore has to come from amortizing the shared
weight-read across many videos at once — batched decoding — not from a faster
single stream, a second model, or more RAM.**

## 3. Target

- **A screenful of ~16 fresh cards fully resolved in < ~500 ms** (the number that
  kills the visible flash), via batched decoding.
- Single-video, when it can't be batched: **~350–425 ms** for a tagged 7B video
  (forced-token batching + release build), down from ~585 ms.
- No accuracy or calibration regression (`score`, `calib` re-run and unchanged).

## 4. The changes (ordered by impact)

### Phase 0 — Honest baseline in a release build
The shipping app is `-c release`; the eval was debug (~25 ms/token overhead).
Re-run the `latency` eval (added this session, `VAULT_DECODE_TIMING=1` splits
prefill/gen/first-token) in release to get the true single-stream floor before
optimizing. Cheap; sets the bar the batch must beat.

### Phase 1 — Batched (multi-sequence) decoding  ← the core change
Decode the extension's existing 32-item batch as **one multi-sequence llama
pass** instead of N serial calls. One weight-read then advances *all* sequences.

Engine work (`VaultLocalLLMEngine`):
- New `classifyBatch([LLMClassificationRequest]) -> [LLMClassificationResult]`
  grouped by classifier type (one shared static prefix per group).
- **Share the static prefix once:** prefill it into seq 0, then
  `llama_kv_cache_seq_cp` to seqs 1..N-1; prefill each seq's dynamic suffix at
  `prefixLen`. The expensive prefix compute + weight-read is paid once per batch.
- **N independent grammar samplers** (same grammar, separate state), one per seq.
- **Batched generation loop:** each step builds a `llama_batch` of the still-going
  sequences' next tokens, one `llama_decode` advances them together, sample each
  with its grammar; drop sequences that hit EOG / the tag cap; stop when empty.
- Collect per-seq output; parse exactly as today (name + model confidence +
  softmax cross-check per seq).
- Context sizing: `n_ctx ≥ N × (prefix+suffix+gen)` and `n_seq_max = N`; KV for
  N=16 × ~950 tok ≈ ~0.9 GB — fits the spare RAM.

Wiring: the hub/`LocalClassifierHub` already receives batch requests; route a
whole batch to `classifyBatch` instead of awaiting the actor per item. Keep a
serial fallback for singletons.

**Payoff:** the ~40 ms/token weight-read and the ~165 ms first-token cost are paid
**once per batch**, not per video. A 16-card screen (~96 tokens total) ≈
**~300–400 ms** vs ~9 s serial.

Effort: **high** (single-seq → multi-seq rewrite + KV-prefix sharing + N samplers).
Risk: multi-seq KV/grammar correctness. Validation: a batched-vs-serial
equivalence test (identical tags), then `score` + `calib` unchanged.

### Phase 2 — Forced-token batching (fewer decode steps per sequence)
Within a sequence, once the grammar allows only a forced continuation
(`","confidence":`, the tail of a committed name, `},{"name":"`), **append that
span and decode it in one step** instead of sampling it token-by-token. Only the
name's first token and the confidence digit are real choices. Cuts a tagged
sequence from ~6–7 steps to ~3, so the batched loop finishes in fewer rounds.
Validation: `score` + `calib` unchanged (it touches the decode); the softmax
cross-check still captured at each name-start.

### Phase 3 — OCR pipelining (free parallelism, off-GPU)
Thumbnail OCR runs on the Neural Engine / CPU, not the GPU. Schedule the next
batch's OCR **while the GPU decodes the current batch**, so OCR never serializes
in front of classification. App-side scheduling only.

### Phase 4 — Flash policy (owner product decision, complements the above)
Extension is **show-until-blocked**: a new card shows its real thumbnail until a
verdict lands, so any residual latency = a visible flash. With batching a screen
resolves in ~300–400 ms, which may be acceptable; if not, add **hide/blur-until-
known** (neutral card until its first verdict) to remove the flash entirely at the
cost of a brief placeholder on new cards. This is a policy call, not engine work.

## 5. Explicitly NOT doing
- **No 1B fast-path / no second model** (owner). Single 7B.
- **No smaller quant / no speculative decoding** for now (quality/complexity).
- Per-stream latency below the ~40 ms/token × tokens floor is impossible on this
  hardware; batching is the only real lever.

## 6. Open questions
- Batch size vs latency: wait a few ms to fill a batch (higher throughput) vs
  decode immediately (lower latency for a lone card)? A short coalescing window.
- Mixed-type batches: group by classifier type (shared prefix) — confirm the
  extension's per-scroll batch is usually single-type per platform.
- Whether Phase 2's forced-token batching is worth its decode-path risk once
  Phase 1 already amortizes the first-token cost across the batch.

## 6a. CORRECTION after building Phase 1 (2026-09-17) — §1's premise was wrong

Phase 1's engine (`classifyBatch`: shared prefix on seq 0 → `seq_cp` → lock-step
generation with per-sequence grammar samplers, KV-budget packing) is built and
**exactly equivalent to serial: 16/16 identical tags + confidence** (`eval batch`).
But it measured only **×1.2**, because two §1 claims were artifacts:

- **"Prefill ≈ 3 ms, cached" was FALSE.** Metal is asynchronous: `llama_decode`
  returned immediately and the GPU work was paid at the first sample. With
  `llama_synchronize`, prefill is the DOMINANT cost: 16 videos = 1,318 suffix
  tokens = **5.4 s ≈ 245 tok/s, compute-bound — and prefill does NOT amortize in a
  batch** (N× the tokens = N× the work).
- **The "~165 ms first-token cost" does not exist** — it was that suffix prefill.

**Real cost model (7B, M1 Pro):
`time ≈ 4.1 ms × per-video suffix tokens  +  generation (batchable)`.**
Per video: ~82 suffix tokens ≈ **336 ms prefill** vs ~156 ms batched generation.
Batching shrank generation (56 tokens in 9 lock-step rounds) but generation was
never the big half.

**What the suffix is:** ~16 tokens of fixed boilerplate (`Video:/Title:/Output
JSON…` — positioned after variable text so it can't be KV-shared), the title
(~20, CJK titles tokenise long), and the **creator tag history: up to 10 rows at
~19 tokens each ≈ 200 tokens ≈ 800 ms for a prolific creator** — including 1%
noise rows. That is the p90 tail. Capping history to the top 3 rows
(`creatorPriorRowLimit`, switchable, default off) cut suffix tokens 1,318 → 1,102
with identical tags on the sample; accuracy impact NOT yet scored.

**Revised lever order:** (1) shrink the per-video evidence — fewer/compact history
rows, maybe trim exemplars — validated by `score`; (2) batched decode (built) for
the generation half, whose share GROWS as the suffix shrinks; (3) forced-token
batching. Wiring `classifyBatch` into pipeline/store/app is not done yet.

## 6b. Phase 1 wired end-to-end + the creator line fixed to owner spec (2026-09-17)

- **Owner correction:** the prompt's "Creator's tag history" block
  (`27/70 (39%), confidence 3.9±0.9` per row) was never asked for. Spec = **the
  creator's total classified videos + a count per tag, nothing else.** Now one line:
  `Creator: 70 videos classified. Tag counts: News & Politics 27, Comedy & Memes 18, …`
  (all tags kept). Effect on the same 16 videos: suffix **1,318 → 751 tokens**, and
  accuracy IMPROVED on `score` (dev 7B, cap 1): **P 0.58→0.59, R 0.50→0.61,
  F1 0.54→0.60, exact 58%→62%** (declines 36/55 vs 38). Watch: confidence now
  concentrates at 5 (c5 0.64 precision ×56, c4 0.33 ×12) — monotone, but more
  assertive; re-run `calib` before relying on c4 as a gate.
- **Wiring done, batch-first everywhere (single = batch of one, one code path):**
  `VideoClassificationPipeline.classifyBatch` (primary batch, then a second
  creator-grounded batch for the weak ones) → `LocalClassifierCoordinator.
  classifyVideos` (one save, per-video research scheduling) → the app's drain loop
  now hands the engine 16-video chunks instead of awaiting per item (whole-batch
  failure falls back to per-video). OCR prewarm was ALREADY concurrent with the
  LLM, so §4 Phase 3 needed no work.
- **Measured (same 16 videos, 7B): 581 ms/video serial originally → 361 ms/video
  batched with the owner-spec creator line** (suffix prefill 3.1 s + generation
  2.7 s for the screen). Batched == serial on 16/16. 221 tests; live full-loop
  smoke passes through the new path.
- **Remaining levers, in order:** (1) the ~16-token fixed boilerplate + title are
  now most of the suffix — little left to trim; (2) forced-token batching
  (generation is now ~half the time: 64 tokens in 9 rounds); (3) the flash policy
  (owner). A caveat of batching: videos in one batch don't see each other in the
  creator counts (they reflect the catalog before the batch).

## 6c. Phase 2 — two ways to stop generating scaffold, measured (2026-09-17)

**(i) Owner-requested BARE reply (`Music 4 Sports 2`, runway `Tags:`, no JSON at
all) — REJECTED on accuracy, kept on branch `experiment/bare-reply-format`.**
Dev 7B, 120-video eval, cap 1, vs the JSON-scaffold contract:

| | JSON scaffold | bare `Name D` |
|---|---|---|
| batched speed | 361 ms/video | **278 ms/video** |
| P / R / F1 | 0.59 / 0.61 / **0.60** | 0.50 / 0.47 / **0.48** |
| exact match | 62% | 51% |
| declines correct | 36/55 | 31/55 |
| calibration (ECE) | ~0.30 | 0.239, separation 0.60 (better) |

This confirms, on the 7B and a real eval set, the 2026-08-15 note that the
`{"tags":[{"name":"` runway carries accuracy: without it the model declines more
and picks worse. Do not remove the JSON runway from the PROMPT.

**(ii) Forced-span feeding — SHIPPED.** Keep the prompt exactly as is, but never
*sample* what the grammar forces (`forcedContinuation`): once the name is
unambiguous (no longer tag name could still be forming), `","confidence":` is fed
in the SAME decode step as the name token; a started `},{"name":"` is completed;
and at the tag cap (or on an unambiguous `none`) the decode stops right after the
digit instead of spending a round sampling end-of-text. Every real choice — each
name token, each digit, "another tag or stop" — is still the model's.
Result (dev 7B, 32 videos): **answers identical to sample-everything on 32/32
(tags + confidence)**; generation **9 → 5 lock-step rounds (2.7 s → 1.5 s per
16)**; **batched 379 → 303 ms/video, serial 516 → 405 ms/video.** A/B switch:
`VAULT_NO_FORCED_SPANS=1`.

**Where the time is now (16 videos ≈ 4.8 s):** ~3.2 s is suffix prefill (~47
tokens/video at ~245 tok/s: title + ~16 tokens of fixed `Video:/Title:/Output
JSON…` boilerplate + the creator counts line) and ~1.5 s is generation. Prefill
is compute-bound and unbatchable, so the remaining lever is fewer suffix tokens
(or the flash policy, §4 Phase 4), not the decoder.

## 7. Decisions log
- 2026-09-17 — Measured: 7B generation is bandwidth-bound at ~40 ms/token on M1
  Pro; prefill cached (~3 ms); ~165 ms first-token cost; tagged video ~585 ms
  (debug). 1B meets budget but is not chosen.
- 2026-09-17 — Owner: single 7B, no 1B+7B pipeline. Refinement = batched decoding
  first, then forced-token batching + OCR pipelining; flash policy separate.
