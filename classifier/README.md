# Vault Classifier

Local state currently uses alpha document schema 2. Compatible unversioned and
schema-1 forms reconcile to that structure. A newer or invalid schema is refused
before decoding or saving, leaving its file untouched and showing an issue.
These document numbers are separate from the planned Beta 1 major-version
migration policy; the complete beta migration system is still pending.

Vault Classifier is a local-first portable Swift package that tags collected public
content (video titles, YouTube-first) on-device with a local language model. It
is a pure tagging service: it returns tags with a 1–5 confidence and makes no
blocking decision — the Vault browser extension owns all content-block policy.
Mac Vault embeds its Classifier scene; Windows Vault hosts the same service
in a bundled headless Swift worker behind a private JSON-lines pipe. Both use
the same local state, model engine, research execution and bounded scene actions.

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

## Windows worker

`VaultClassifierWorker` accepts UTF-8 JSON lines with `{id, operation, data}`
through stdin and returns `{id, ok, value}` or `{id, ok, error}` on stdout.
State, Activity and browser-tag broadcasts are events on the same bounded pipe.
Operations cover `snapshot`, `action`, `mcp`, `hub`, `activity`, `tagNames`,
`resource` and `hostEvent`. The .NET host owns browser authentication, focused
app sampling, normal-quit enforcement, the WebView2 resource route and MCP HTTP.
The worker never exposes another listening port. `VAULT_DATA_ROOT` is the
host-selected Classifier support directory; `VAULT_ENVIRONMENT` follows the
existing production/development split. All builds and tests run on mini1.

`windowsBlocker/scripts/classifier-worker/` contains the reproducible native
build, dependency bundle and protocol smoke test. `--testing-directory` is a
hermetic test mode, with the existing stub engine and no hub/provider requests.
Normal launches omit it and install the full production research/LLM stack.

## Package layout

Dependencies point one way, and the compiler enforces it: `Core` imports none
of the others.

| Target | Holds |
| --- | --- |
| `VaultActivityCore` | Canonical Activity store, dashboard geometry, groups, wire validation and native sample accumulator. |
| `VaultClassifierWorker` | Private JSON-lines host of the production Classifier and Activity services. |
| `CVaultWindows` | Windows ACL/DPAPI/randomness/image and safe file-cleanup boundary. |
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

Official dictionary downloads, creator cache/full-download mode, contribution choice and personal JSON import/export live in Classifier Settings. Knowledge shows the dictionary status and a Configure dictionaries link, alongside the Research provider panel. Personal term and creator editing remains in Knowledge.
