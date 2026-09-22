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

## 6d. Is there a balance point between JSON and bare? — No (2026-09-17)

Owner question: keep the brackets but drop the key names? The reply shape is now
four strings (`ClassificationReplyFormat`: rule line, prompt runway, name→digit
text, item separator; `VAULT_REPLY_FORMAT=json|pairs|object`, production = json).
Dev 7B, cap 1, forced-span feeding on, batched speed on 16 videos:

| format | ms/video | 120 items: P/R/F1, exact | 65 LABELED only: P/R/F1, exact | predicted declines (of 120) |
|---|---|---|---|---|
| json `{"tags":[{"name":"Music","confidence":4}]}` | 295 | .59/.61/**.60**, 62% | **.82/.61/.70**, 60% | 52 |
| pairs `[["Music",4]]` | 284 | .46/.59/.52, 52% | .72/.59/.65, 58% | 36 |
| object `{"Music":4}` | 280 | .46/.53/.49, 54% | .67/.53/.59, 52% | 44 |
| bare `Music 4` (branch) | 278 | .50/.47/.48, 51% | not run | — |

- **Monotone: less scaffold → less accuracy**, and since forced-span feeding the
  whole speed range is only ~15 ms/video. There is no balance point worth taking;
  **production stays on full JSON.**
- **Why (what the data supports):** the "bare over-declines" hypothesis is WRONG —
  lighter formats decline LESS (36–44 vs 52). With the explicit `"name"` /
  `"confidence"` keys the model is more *deliberate*: it commits at conf 5 or
  declines (no tags below c4). Without keys it guesses more — pairs emits 21 tags
  at c2–c3 that are only ~48% right. At the blocking gate (conf ≥4) JSON yields 40
  correct / 9 wrong vs pairs 29 / 4: pairs is a touch more precise but misses
  ~a quarter of the blocks JSON gets. (Pairs does spread confidence more usefully:
  c2 .46, c3 .50, c4 .90, c5 .85 — worth remembering if calibration ever matters
  more than recall.)
- **Eval caveat found on the way:** 55 of the 120 eval items have no labels and
  `score` counts any tag on them as a false positive, which rewards whichever
  variant declines most. `score --labeled-only` removes that; the ranking above is
  the same both ways, but absolute precision is .82, not .59. Open: whether those
  55 are "judged no-tag" or "never labeled" (owner) — and the counts-only creator
  line's gain (F1 .54→.60) was measured on all 120 only.

## 6e. Bare tag names became production (2026-09-21) — §6c/§6d are SUPERSEDED

Owner's requirement: the ENTIRE processing of a video under 0.5 s. His idea: drop the scaffold AND the
confidence digit together. §6c/§6d rejected bare replies, but those experiments (and my first two attempts
on 2026-09-21) were flawed. What makes a bare reply work:

1. **No leftover instructions** — the "give a confidence 1–5" rule is omitted when no digit is asked for.
2. **Natural tokens** — runway `Tags:` (no trailing space); every name carries its leading space
   (`ClassificationReplyFormat.nameLead`), separator `,`.
3. **A newline terminator in the grammar** (`root ::= core lineend`). A bare line ends with `\n`, not
   end-of-text; without it the model's "done" is rejected and the separator is the only legal move, so it is
   FORCED to keep tagging (continue odds read exactly 1.000 on 782 of 782 extra tags).
4. **A stop rule for extra tags** — `LocalLLMSettings.extraTagMinimumOdds` (default 0.90): generation stops
   BEFORE a 2nd/3rd tag unless odds(continue) × odds(name) reach it. This replaces what the digit did (the
   model rated weak extras low and the pipeline dropped them). Extra tags right by joint odds: <0.5 28%,
   0.5–0.8 41%, 0.8–0.9 51%, 0.9–0.97 59%, ≥0.97 66%. The first tag is always kept (90% right).

450-video library (`eval-library.json`), dev 7B, release, ≤3 tags, research context off, every emitted tag
counted; time = engine, mean of four 16-video batches:

| setup | ms/video | correct | no tag | wrong tags | tagged videos with no wrong tag |
|---|---|---|---|---|---|
| JSON + digit (old production) | 385 | 65.6% | 17.1% | 13.7% | 80% |
| bare names, no stop rule | 271 | 72–78% | 13.1% | 32–42% | 16–42% |
| bare names, stop ≥ 0.85 | — | 67.1% | 13.1% | 16.9% | 79% |
| **bare names, stop ≥ 0.90 (production)** | **260** | 64.4% | 13.1% | 15.9% | 81% |
| bare names, 1 tag | 237 | 56.2% | 20.4% | 9.2% | 91% |

Where the time is now (16 videos): reading the prompts 3.0–3.4 s whatever the reply; generation 2,172 ms
(JSON+digit, 8 rounds, 384 tokens) → ~800 ms (bare, 3 tags) → 163 ms (bare, 1 tag). Output is finished as a
lever; the floor is ~49–62 suffix tokens per video at ~257 tok/s (M1 Pro hardware limit). Real tokenizer
means: creator counts line 29.7 tokens (p90 63), title 17.4, labels+runway 11.0; static prefix 612 (cached).

Confidence is now derived, not written: first tag = odds of its first token (94% right at 4–5 vs the
digit's 92%); extra tag = the joint odds. `VAULT_REPLY_FORMAT=json` keeps the old format for A/B;
`VAULT_NAMES_MIN_JOINT` overrides the setting for sweeps; `VAULT_NAMES_LOG=1` logs every tag's odds.
Did NOT help: keeping the JSON runway without the digit (slower, over-tags); token-odds alone without the
newline fix. The prompt line "Most videos need only one tag; add another only when the video is clearly also
about that topic" does NOT curb extra tags, but it lowers needless declines (no tag 15.3% → 13.1%) and lives
in the cached prefix, so it stays.

## 6f. Thumbnail OCR evidence DELETED (2026-09-22, owner decision, measured)

450-video library, production format, research context off, same Vision settings as the app:

| | correct | no tag | wrong tags | clean tagged videos |
|---|---|---|---|---|
| OCR off | 64.2% | 13.3% | 15.7% | 81% |
| OCR on | 63.3% | 14.4% | 14.7% | 82% |

OCR changed 73 predictions: 18 made fully right, 15 made wrong — a wash (an earlier 65-item test agreed:
P .81/R .59 with vs .82/.61 without). Wins came from clear captions ("CHESS SLOT MACHINE 8x8"), losses from
clickbait captions ("Level 100", "WORST GENERATION?") and garbled reads of Chinese thumbnails. Cost: text on
313/450 thumbnails, +11.2 prompt tokens per video on average (≈48 ms), 52 videos > 0.1 s, 10 > 0.25 s, worst
288 tokens (≈1.2 s) — plus a thumbnail download and a Vision pass per video. Removed: `ThumbnailOCR`,
`ThumbnailURLPolicy`, the per-type `thumbnailOcrEvidence` setting and toggle, `ocrPlatformIDs` and
`thumbnailURL` in the hub messages (old keys are ignored on decode), the extension's thumbnail hand-off,
eval `--ocr`. §4 Phase 3 (OCR pipelining) is moot. An entry's own body `text` (Reddit/Bilibili) still reaches
the prompt — that was never OCR.

## 6g. Reading the prompt is at the hardware limit; the creator line got shorter (2026-09-22)

`llama-bench` on this laptop/model: 261 tok/s prompt reading at any size; the engine: 257 tok/s, all 16
suffixes in one GPU batch. So only FEWER tokens help. Per-video suffix on the bare-name format ≈ 54 tokens:
creator counts line ~30 (p90 63), title ~17, labels + `Tags:` runway ~6; the 612-token static prefix is cached
and free. Measured on the 450-video library (research context off) and four 16-video batches:

| prompt | ms/video | correct | no tag | wrong tags | clean |
|---|---|---|---|---|---|
| `Creator: N videos classified. Tag counts: …` + `Video:` label | 250 | 64.4% | 13.3% | 15.8% | 81% |
| **`Creator (N videos): …`, no `Video:` label (production, p3)** | **224** | 64.2% | 14.4% | 15.0% | 81% |
| …and drop tags the creator got only once | ≈200 (est.) | 62.4% | 14.9% | 14.0% | 83% |

The compact wording is free (same information, −6 tokens); dropping single-count rows costs 2 pts of correct
answers, so it stays out. Also folded the separate last-token decode into the suffix batch (−1 GPU pass,
≈3 ms/video; batched vs serial still 16/16). Remaining floor ≈ 40–45 tokens: the title is the evidence and
the creator line is the only context; below that means removing the creator line. Untested lever: a Q4_0
quant reads faster than Q4_K_M on Metal in some setups (a model change → full quality re-check).

## 6h. Research text is one sentence, read in the single pass; the second decode is gone (2026-09-22)

Research knowledge was the last thing that could push a video past the 0.5 s budget: a looked-up term or
creator description was a ~130-token paragraph, and a weak video paid a whole SECOND decode over it.
Measured on the 450-video library (research on, release):

| creator knowledge | correct | no tag | wrong tags | clean | ms/video |
|---|---|---|---|---|---|
| none | 64.2% | 14.4% | 15.0% | 81% | 224 |
| second decode over the full description (old) | 66.2% | 8.7% | 15.7% | 80% | 224, weak videos ≈ 1 s |
| **one sentence (≤25 words, ~28 tokens) on the creator line, single pass** | **68.0%** | 11.1% | **14.6%** | 81% | 292, no video > ~0.4 s |
| ≤10-word topic list on the creator line | 64.4% | 12.4% | 17.2% | 76% | — |

The sentence beats the second decode overall (fixed 25 / broke 19) though it rescues fewer of the 28 videos
the second decode used to touch (9 vs 12 right). A bare topic list made the model over-tag — it reads like
a tag list — so the lookup asks for a SENTENCE. Shipped: `GroundedGenerationProtocol.systemPrompt` asks
for one sentence (creator: "what kind of videos the channel makes"; term: "what or who it is") and
"unknown" when nothing is found (refused, nothing stored); `ClassificationPromptAssembler` renders it as
`Creator makes: …`; the weak-video second decode and `creatorGroundingConfidenceFloor` are deleted; the
906 stored dev descriptions were condensed once with a Gemini batch (no web search, ~cents). Prompt p4.

## 7. Decisions log
- 2026-09-17 — Measured: 7B generation is bandwidth-bound at ~40 ms/token on M1
  Pro; prefill cached (~3 ms); ~165 ms first-token cost; tagged video ~585 ms
  (debug). 1B meets budget but is not chosen.
- 2026-09-17 — Owner: single 7B, no 1B+7B pipeline. Refinement = batched decoding
  first, then forced-token batching + OCR pipelining; flash policy separate.
