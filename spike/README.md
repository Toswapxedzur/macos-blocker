# Phase 0 — on-device LLM latency spike (isolated)

This is a **standalone** SwiftPM package, deliberately kept **out** of the main
`VaultClassifier` package. Pulling MLX (Metal kernels) is a heavy build; isolating
it means a slow or failing MLX compile can never red the main project.

## What it measures

Whether a small on-device LLM can classify a video **title → a few tags** within
the budget agreed in the rework:

- **< 500 ms/decision** — fine
- **500 ms – 1 s** — danger zone
- **> 1 s** — unacceptable

It loads a model once, then times a short generation per title (excluding the
first as warm-up) and prints the median with its band.

## Run it

```bash
cd vaultClassifier/spike
swift run -c release spike mlx-community/Llama-3.2-1B-Instruct-4bit
swift run -c release spike mlx-community/Llama-3.2-3B-Instruct-4bit
```

- First run downloads the model from Hugging Face (~0.7–1.8 GB) and builds MLX
  (can take several minutes the first time).
- Use `-c release` for representative numbers (debug is much slower).
- Compare 1B vs 3B and pick the most capable model that stays under 500 ms — that
  seeds `LocalModelCatalog.recommended(...)` in the main package.

## Status / caveats

- **The spike builds successfully** (`swift build` → executable) against the pinned
  `mlx-swift-examples` **2.29.1** + `mlx-swift` 0.29.1. (`main` is mid-refactor and
  stops exposing the `MLXLLM`/`MLXLMCommon` products — hence the exact pin.)
- It has **not been run** here — running downloads a model (~0.7–1.8 GB) and needs
  a release build for representative numbers; that's the one remaining manual step.
- `Sources/spike/main.swift` uses `MLXLMCommon.generate(...)` with a `[Int]`
  `didGenerate` closure (disambiguated from the `Int` overload). Verified to compile.
- This spike does **plain** short generation. The real pipeline adds
  **constrained decoding** (JSON schema / grammar to force valid tag-name output)
  and **prompt-prefix KV-cache reuse** for the static prefix; both reduce latency
  and are the next things to validate here before wiring the real
  `MLXOnDeviceLLM: OnDeviceLLM` into the main package.

## How it plugs into the main package

The main package defines the runtime-agnostic boundary:

- `OnDeviceLLM` protocol (`Sources/VaultClassifierCore/OnDeviceLLM.swift`)
- `ClassificationPromptAssembler` (cached prefix + dynamic suffix)
- `VideoClassificationPipeline` (assemble → run → map names→ids → `VideoClassification`)
- `LocalModelCatalog` (curated, capability-gated, hardware-aware default)

A real `MLXOnDeviceLLM` is just an `OnDeviceLLM` conformer that wraps the model
loaded here and returns `{tags, unknownTerms}` (ideally via constrained decode).
Everything downstream already works against the protocol and is unit-tested with a
`StubOnDeviceLLM`, so wiring MLX in is a localized change.
