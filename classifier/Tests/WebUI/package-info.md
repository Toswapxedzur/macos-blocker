# Classifier Web UI regressions

`language-manuals.js` checks the integrated Vault, Classifier and Activity
manual entry points, separate native code guide, clipboard output and focus
restoration after a Classifier snapshot replaces the opener. Run on mini1 with
`UI_TEST_PAGE=/Sources/MacBlockerWebUI/WebAssets/popup.html`,
`UI_READY_EXPRESSION='!!window.VaultClassifier && !!window.activityApply && !!window.VaultManual'`,
`UI_TEST_SCRIPT=classifier/Tests/WebUI/language-manuals.js` and
`UI_TEST_EXPRESSION='runLanguageManualTests()'` through `autosave.mjs`.
The page/readiness overrides let the same runner exercise the integrated shell.

`tagging-controls.js` checks the directly visible per-group Pause/Resume button,
the Classifier Settings enable switch, native autosave and independent pause
state. Run through `autosave.mjs` with `UI_TEST_SCRIPT=classifier/Tests/WebUI/tagging-controls.js`
and `UI_TEST_EXPRESSION='runTaggingControlTests()'` on mini1.

`autosave.html` renders the production Classifier assets with synthetic local
state and an in-memory native-action receiver. `autosave.mjs` serves that
fixture and drives Chrome for Testing through CDP on mini1. It checks real
input/change/focus/composition handlers, delayed snapshots, dialog Escape/Tab
focus restoration, creation drafts and complete group dial cards;
Knowledge access, permanent deletion confirmation, group More state, independent group edits and dial summaries;
it never connects to the owner's Classifier state or any provider.

`activity.html` exercises the production Activity renderer with synthetic state:
720px group layout, draft preservation and deletion confirmation across snapshots.
The same runner checks it after Classifier and saves a separate Activity capture.

Run on mini1 from the Mac Vault repository:
`~/.local/node/bin/node classifier/Tests/WebUI/autosave.mjs`.
Chrome for Testing must already expose loopback CDP at port 9222.
An optional first argument saves a screenshot to that path.

`bounded-lists.js` adds 763 creators, terms and API keys to that fixture.
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

`group-dials.js` checks independent tier selection and house rules, shared model
Downloads/Delete/RAM controls, confined tier-card geometry, snapshot preservation
and removal of global settings UI. Run at wide and narrow widths with
`UI_TEST_SCRIPT=classifier/Tests/WebUI/group-dials.js`
`UI_TEST_EXPRESSION='runGroupDialTests()'` and the same runner.

`tag-bounds.js` checks directly visible core settings, optional per-group min/max
fields under More, independent blank defaults, preservation across dial changes,
invalid/fractional input, snapshot drafts/focus and collapsed summaries. Run on
mini1 with `UI_TEST_SCRIPT=classifier/Tests/WebUI/tag-bounds.js` and
`UI_TEST_EXPRESSION='runTagBoundsTests()'` through `autosave.mjs`.

`info-popovers.js` verifies English helper confinement, no panel reflow, snapshot persistence, live status/consent visibility and unchanged non-English layout. Run with `UI_TEST_SCRIPT=classifier/Tests/WebUI/info-popovers.js` and `UI_TEST_EXPRESSION="runInfoPopoverTests()"`.

- Info checks cover hidden title labels, settings/Knowledge/create fields, shared size/color, and dismissal inside model/tag chooser menus without provider requests or edits.

`list-search.js` verifies provider filters, open dropdown rebinding during snapshots, query/caret preservation, and tag-tree Find/highlight/jump without mutations. Run on mini1 with `UI_TEST_SCRIPT=classifier/Tests/WebUI/list-search.js UI_TEST_EXPRESSION='runListSearchTests()'` through `autosave.mjs`.
