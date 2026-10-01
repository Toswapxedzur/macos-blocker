# Classifier Web UI regressions

`autosave.html` renders the production Classifier assets with synthetic local
state and an in-memory native-action receiver. `autosave.mjs` serves that
fixture and drives Chrome for Testing through CDP on mini1. It checks real
input/change/focus/composition handlers, delayed snapshots, dialog Escape/Tab
focus restoration, creation drafts and related selector widths;
Knowledge access, separate Trash disclosure, group More state and override summaries;
it never connects to the owner's Classifier state or any provider.

`activity.html` exercises the production Activity renderer with synthetic state:
720px group layout, draft preservation and deletion confirmation across snapshots.
The same runner checks it after Classifier and saves a separate Activity capture.

Run on mini1 from the Mac Vault repository:
`~/.local/node/bin/node classifier/Tests/WebUI/autosave.mjs`.
Chrome for Testing must already expose loopback CDP at port 9222.
An optional first argument saves a screenshot to that path.

`bounded-lists.js` adds 763 creators, terms, trash and API keys to that fixture.
Use `UI_TEST_SCRIPT=classifier/Tests/WebUI/bounded-lists.js` with the same runner;
`UI_WIDTH` and `UI_HEIGHT` choose the viewport. It verifies last-entry access,
search, natural sizing of short lists, and snapshot/focus preservation.

`research-setup.js` checks missing/deleted providers, credentials, models and
consent; navigation without a group mutation; normal autosave after setup;
Knowledge status; and provider creation in Settings. Run with
`UI_TEST_SCRIPT=classifier/Tests/WebUI/research-setup.js`
`UI_TEST_EXPRESSION='runResearchSetupTests()'` and the same runner.

`model-picker.js` covers explicit Fetch/Fetching/Refresh/Retry states, missing
provider/key guidance, a bounded 256-model list, searching and snapshot/caret
preservation, immediate autosave, provider-specific lists and unavailable saved
choices. The fixture simulates model-list responses without provider traffic.
Run with `UI_TEST_SCRIPT=classifier/Tests/WebUI/model-picker.js`
`UI_TEST_EXPRESSION='runModelPickerTests()'` and the same runner.

`dropdown-layout.js` extends those checks with floating-menu geometry,
viewport containment, keyboard navigation, outside dismissal, full-width
API fields with a usage footer, and creator suggestion/caret preservation.
Run with `UI_TEST_SCRIPT=classifier/Tests/WebUI/dropdown-layout.js`
`UI_TEST_EXPRESSION='runDropdownLayoutTests()'`, at wide and narrow widths.
