# Vault Classifier component

Mac Vault owns this component's Classifier page and shared classifier/Activity worker. `Package.swift` builds Core contracts/state/pipeline, Research, Bridge, App, Activity, the worker, native hub helper and the grounding diagnostic. `Tests/` contains Swift regression suites and owned headless web fixtures; `scripts/` contains supporting tools. Root Mac packaging bundles the shared resources.

Production tagging uses one explicitly selected connection/model per group: ChatGPT subscription, OpenAI API, Gemini API or Grok API. API keys use provider billing and share the existing saved-provider store. Local groups, model downloads, GGUF tiers, resident-engine registry and llama/Metal inference targets were retired on October26,2026. Dormant implementation is preserved on pushed branch `archive/local-tagging-20261026` at d80dc8a; historical model/evaluation documents and datasets describe that archived implementation. They are not active setup instructions.

Classifier state schema6 adds API-key selections and drops retired Local groups/Ollama profiles and their group-owned rows while preserving cloud groups, neutral tagging settings, datasets and collected content. Missing connection setup and failed requests leave new items unresolved, retain valid caches and expose Retry. Search is explicit and off by default. Group strictness, tag-count overrides and tagging instructions remain.

Tests run on owner-selected Mini2. No public installer or Store publication is authorized. Canonical state and next work: `~/Desktop/agentic/memory/vault-classifier.md`; project bootstrap: `../../misc/project-memory/PROJECT-MEMORY.md` in the group root.
