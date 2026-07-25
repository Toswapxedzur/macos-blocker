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

- Local tag trees, datasets, classifier types, creator decisions, local models,
  policy evaluation (`allow`, `dim`, `block`), bounded cache, and decision
  ledger.
- A reusable **LLM Assist** connection library. Provider profiles contain
  non-secret connection configuration plus a visible local credential field.
  A classifier type explicitly selects one provider/model and owns its budget,
  request pace, tag constraints, and explicit web-search mode. Each
  creator LLM classification composes independent evidence layers: bounded
  matching official-platform API evidence when an adapter exists, plus
  optional web search on every platform. OpenAI, Gemini, and Anthropic can use
  their native hosted-search tool when unsure. Standard tool-capable models can
  instead call one app-defined `web_search` function backed by an independent
  Serper or You.com Search profile. The app returns bounded transient results
  to that same model conversation before requiring final label JSON. There is
  no unconditional search prefetch, static creator-page fallback, or second
  research model.
- Twitch, Reddit, and Discord classification is intentionally manual-only.
  Their collected sources and human tags remain available, but Local Model and
  LLM Assist are not offered for those classifier types.
- An authenticated v4 local browser hub at `ws://127.0.0.1:8787`. Mac Vault
  or Vault Classifier hosts it; unavailable peers, invalid frames, and
  timeouts fail open.
- Local backups and signed-package lifecycle foundations. They are explicit,
  local operations; no scheduler or automatic package activation is attached.

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
