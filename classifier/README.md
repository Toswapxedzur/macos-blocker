# Vault Classifier

The Classifier is the cloud tagging component of Mac Vault. Four connection choices:
ChatGPT subscription, OpenAI API, Gemini API and Grok API. Each group selects one
provider/model and supported reasoning effort. Search is enabled on every uncached
request; the selected model chooses whether to invoke it. Failures preserve valid
caches and offer Retry, with no automatic provider fallback.

Local models, official dictionaries, personal Knowledge and separate Knowledge
research are dormant. They expose no UI, worker/MCP actions or background services.
See [dormancy and recovery](../docs/DORMANT-KNOWLEDGE.md). Historical architecture and
benchmark documents in this directory describe archived implementations.

Current code: Core owns taxonomy, cloud-tag cache and storage; Research contains
provider HTTP/auth/structured generation; App owns UI, coalescing and cloud dispatch;
Bridge owns native/browser transport. Tests inject engines/transports and isolated
storage rather than reading real credentials or calling billed providers.
