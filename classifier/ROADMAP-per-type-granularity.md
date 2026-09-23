# Roadmap B — per-type granularity (research + models + vastly more control)

> **SUPERSEDED 2026-09-23.** The "vastly more granular control" direction was reversed: the classifier now exposes exactly two dials (Speed↔Quality, Strict↔Broad), globally with per-type follow/own, plus house rules, per-type tag trees and research on/off + provider — see `package-info.md` ("Settings shape"). Kept as history.

User direction (2026-08-23): grounded research should be **per classifier type**, not one global switch; expose **much more granular control** — research frequency, research specifics, and **per-type local model types**; chosen model-residency strategy = **(b) multiple resident models** (instant switch, N× memory).

Builds on the A cleanup (dead `LLMAssistConfiguration`/`LocalModelAsset` removed). Everything additive + back-compat (decodeIfPresent); research stays **off by default**; the live pill path unchanged when nothing is overridden.

## B1 — Per-type grounded-research override
- Add `ClassifierTypeAsset.researchOverrides: ResearchSettings?` (nil ⇒ inherit global `ClassifierSettings.research`). Mirror the existing `localModelOverrides` pattern exactly (codable: memberwise init default + CodingKeys case + decodeIfPresent; carry it in the `configureClassifierType` reconstruction so saves don't wipe it; reconcile preserves it).
- `LocalStore.classifyVideo` already reads a global `researchSettings`; resolve **effective = type.researchOverrides ?? global** per type before the trigger/enqueue.
- Web: a per-type "Grounded research" section in the type panel, mirroring the per-type "Local model overrides" (override-enabled toggle + advanced disclosure). Lenient parsing → `ResearchSettings.init` clamps. Global Settings keeps the defaults + consent (consent stays a global gate — per-type overrides never bypass the global consent toggle; if global research consent is off, no type researches).

## B2 — Expanded granular controls (on ResearchSettings, all clamped)
Keep existing (enabled, requestsPerMinute, dailyTokenLimit, maxSubjectsPerVideo, provider IDs). Add:
- `cooldownHours` (failed-subject re-attempt gate; persisted negative-cache already exists).
- `trigger` enum: `declineOnly` (default) | `declineAndLowConfidence` | `correctionsOnly` | `all`; plus `confidenceTriggerLevel` (1–5, used only when low-confidence is in the trigger).
- `searchResultCount` (1–maximumResults), `snippetContextChars` (grounding prompt budget), `knowledgeTTLDays` (0 = never expire), `maxKnowledgePerVideo` (cap injected entries; today hardcoded 8).
Each becomes a per-type-overridable field. UI groups them under the per-type research advanced disclosure (Frequency/Budget, Trigger, Search specifics).

## B3 — Per-type model types, resident registry (option b)
- Add `ClassifierTypeAsset.modelFileName: String?` (nil ⇒ global `LocalLLMSettings.modelFileName` / default).
- New `LocalLLMEngineRegistry` actor (VaultClassifierLLM): `func engine(forModel fileName: String?, configuration: LocalLLMSettings) async throws -> VaultLocalLLMEngine`. Lazily loads + **keeps resident** one engine per distinct model file; instant reuse on switch. Bound memory with an LRU cap = `LocalLLMSettings.maxResidentModels` (new global; default 2, range 1–4) — evict least-recently-used engine (its `deinit` frees the llama model/context) when the cap is exceeded. Log load/evict to VaultDevLog.
- `LocalStore.classifyVideo` resolves the type's model file (`type.modelFileName ?? global`), asks the registry for that engine, classifies. Replace the single `setOnDeviceLLM(_:)` injection with a registry the coordinator holds (or keep `setOnDeviceLLM` as the default-engine fast path and add the registry for non-default types). Confidence/decline/subject-extraction all go through the resolved engine.
- App: build the registry at launch (default model preloaded), pass user's `maxResidentModels`. Per-type model dropdown = `VaultLocalLLMEngine.availableModelFiles()` in the per-type local-model-overrides section.
- Memory note to surface in UI: "N models resident ≈ N× model RAM."

## Order (green at each step)
1. B1 data model + resolution + UI (smallest, mirrors localModelOverrides).
2. B2 ResearchSettings knob expansion + per-type override + UI grouping.
3. B3 engine registry + per-type model selection + LRU + UI + memory note.
Tests: per-type research resolution (override vs inherit); registry load/cache/LRU-evict; per-type model resolution; trigger-mode selection; back-compat decode of types without the new fields. Verify: swift build (app + smoke), swift test, node --check app.js, research still off-by-default = live path unchanged.
