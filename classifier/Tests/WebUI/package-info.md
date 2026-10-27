# Classifier UI regressions

`autosave.mjs` serves the production assets in owned, isolated headless Playwright
sessions and closes its browser/context in a guaranteed cleanup path. Run on the
owner-selected Mini2 account for the current campaign; no laptop execution.
`UI_PLAYWRIGHT_MODULE`, `UI_BROWSER_EXECUTABLE`, `UI_WIDTH`, `UI_HEIGHT`, optional
`UI_TEST_SCRIPT` and `UI_TEST_EXPRESSION` select the existing runtime and case.

- `autosave.html`: group names/rules/strictness, key drafts, snapshots, IME,
  creation/deletion, focus, Settings and permanent-deletion semantics.
- `dropdown-layout.js`: supported reasoning choices, menu geometry/hit testing,
  four connections and absent dormant controls.
- `api-connections.js`, `chatgpt.js`: saved key/account controls, catalogs,
  model/effort autosave, always-available search, usage and Retry using synthetic state.
- `connection-settings-preview.js`, `reasoning-group-preview.js`: the actual
  desktop shell's four connections, masked key, model/effort controls and geometry.
- `integrated-settings.js`: shared Settings, language/direction, scene/focus,
  native-key drafts and independent application preferences.
- `tagging-controls.js`, `group-dials.js`, `tag-bounds.js`, `tag-create-drafts.js`:
  current group activation, rules, optional bounds and explicit tag creation.
- `info-popovers.js`, `language-manuals.js`, `native-notice-language.mjs`: contextual
  help, current user/code guides and native notice localization.
- `activity.html`: independent Activity renderer, retention/group drafts and paging.

Feature-only Knowledge, dictionary, research-model-picker and definition-list tests
are archived in the prior source history and hashed dormancy archive. Current tests
must not navigate to or mutate those retired surfaces. Fixtures never connect to
real accounts or billed providers.
