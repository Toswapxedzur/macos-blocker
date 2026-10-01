# Classifier Web UI regressions

`autosave.html` renders the production Classifier assets with synthetic local
state and an in-memory native-action receiver. `autosave.mjs` serves that
fixture and drives Chrome for Testing through CDP on mini1. It checks real
input/change/focus/composition handlers, delayed snapshots, dialog Escape/Tab
focus restoration, creation drafts and related selector widths;
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
