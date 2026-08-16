# Vault Classifier

Vault Classifier is a local-first macOS Swift package for building personal
classification policies from collected public content. It includes a native
macOS development shell, a bounded local WebView presentation layer, local
classification state, and optional explicitly invoked provider features.

The source is the current contract. Documentation explains the intentional
boundaries and points to the subsystems that enforce them; when it disagrees
with code and tests, update the documentation rather than preserving a legacy
description.

## Current capabilities

- Per-video classification through an in-process llama.cpp engine, with a
  bounded stub for tests and explicit debugging. Results are cached by video;
  creator histograms are derived only from those per-video rows.
- Local tag trees, collection datasets, classifier types, configuration-only
  local model assets, and Named Policies using allow/dim/block presentation.
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
