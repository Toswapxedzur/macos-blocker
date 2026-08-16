# LLM Assist and provider connections

LLM Assist is a configuration and connection-management workspace. Per-video
classification itself runs through the in-process `VaultLocalLLMEngine`; saved
cloud provider profiles do not classify collected creators or videos.

## Profiles and model catalogs

The workspace retains provider profiles for language-model APIs, official
platform APIs, and raw-search APIs. A profile contains its type, bounded
protocol configuration, optional endpoint override, explicit test model, and
the locally saved credential field.

Language-model profiles may run two explicit, content-free network actions:

- **Test** sends the provider's fixed `Return exactly OK.` health prompt.
- **Probe** reads the provider's bounded model catalog and capability metadata.

Official platform and raw-search profiles likewise expose fixed health checks.
Those checks use known public targets or the constant Example Domain query;
they never include browser-collected entries, source identities, taxonomy,
classification output, or local LLM prompts.

## Classifier-type configuration

A classifier type can retain one provider/model attachment and its authored
limits: token budget, output cap, extra direction, request pace, batch size,
tag limit, leaf-only constraint, and web-search selection. A pre-model draft is
also persisted so editing the form does not lose those choices.

These records are configuration only. There is no activation flag, background
creator sweep, manual creator-classification action, provider classification
request grammar, or provider decision store. Editing an attachment never
dispatches provider work.

## Credential and diagnostics boundary

Provider credentials are visible local workspace fields. They do not enter the
browser hub, collection diagnostics, dev log, or model-catalog cache. Startup
migration copies any valid retired Keychain value into the profile once and
removes the retired item.

Connection tests retain only safe request metadata: operation, sanitized
endpoint, status, duration, token count, and a bounded response-shape summary.
No request body, response value, generated text, credential, or header is
stored in provider request history.
