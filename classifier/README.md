# Vault Classifier

Vault Classifier is a local-first macOS Swift package that tags collected public
content (video titles, YouTube-first) on-device with a local language model. It
is a pure tagging service: it returns tags with a 1–5 confidence and makes no
blocking decision — the Vault browser extension owns all content-block policy.
It includes a native macOS development shell, a bounded local WebView
presentation layer, local classification state, and optional explicitly invoked
provider features.

The source is the current contract. Documentation explains the intentional
boundaries and points to the subsystems that enforce them; when it disagrees
with code and tests, update the documentation rather than preserving a legacy
description.

## Current capabilities

- Per-video classification through an in-process llama.cpp engine, with a
  bounded stub for tests and explicit debugging. Results are cached by video;
  creator histograms are derived only from those per-video rows.
- Local tag trees, collection datasets, classifier types and configuration-only
  local model assets. Per-type overrides include the maximum and minimum tags
  per video (a minimum of 1 forbids declining).
- Your corrections are authoritative for that video, update that creator's tag
  history, and are retrieved as examples for similar titles. No model writes
  rules from them.
- A reusable **LLM Assist** connection library. Provider profiles retain their
  connection settings and visible local credential field; explicit Tests and
  model Probes never receive collected content. Classifier types may retain
  provider/model configuration, but no cloud creator-classification runner or
  provider decision store remains.
- An authenticated v4 local browser hub at `ws://127.0.0.1:8787`. Mac Vault
  or Vault Classifier hosts it; unavailable peers, invalid frames, and
  timeouts fail open.
- Local backups and signed-package lifecycle foundations. They are explicit,
  local operations.

## Package layout

Dependencies point one way, and the compiler enforces it: `Core` imports none
of the others.

| Target | Holds |
| --- | --- |
| `VaultClassifierCore` | The tagging pipeline, prompt, contracts, persisted state and the store. No networking. |
| `VaultClassifierBridge` | Local-hub authentication and the browser-bridge operation vocabulary + messages. |
| `VaultClassifierResearch` | Cloud grounded-research execution: provider request plans, the HTTP seam, the research executor. |
| `VaultClassifierLLM` | The in-process llama.cpp engine (batched multi-sequence decode). |
| `VaultClassifierApp` | The classifier page and tagging service as a library — one file per concern (web shell, hub bridge, providers, tree editor, settings, …). Its only public type is `VaultClassifierPage`; Mac Vault hosts it as the Classifier page. |
| `VaultClassifierEval` | A command-line accuracy/latency harness that runs the real pipeline on your labelled videos. Not shipped. |

See [CLASSIFIER-INDEPENDENCE.md](CLASSIFIER-INDEPENDENCE.md) for how it got this
shape and the tagging contract.

## Architecture contracts

- [LLM Assist and provider connections](docs/architecture/LLM-ASSIST.md)
- [Shared local browser bridge](docs/architecture/BROWSER-BRIDGE.md)
- [Local backups and package lifecycle](docs/architecture/LOCAL-FOUNDATIONS.md)

## Development

Run the development shell:

```sh
./run-vault-classifier.sh
```

Run verification from this directory:

```sh
swift test
swift build
```

No provider credential, raw provider request/response body, or production
signing private key belongs in the repository.
