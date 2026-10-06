# Mac Vault Activity UI regressions

`activity-lists.js` loads the production Activity renderer into the existing
isolated Classifier Web UI fixture with synthetic groups, usage and content.
It verifies growing lists remain reachable inside bounded viewports.
Run on mini1 from the repository root:
`UI_TEST_SCRIPT=Tests/WebUI/activity-lists.js ~/.local/node/bin/node classifier/Tests/WebUI/autosave.mjs`.

`activity-search.js` verifies group/member/usage/tag/source/viewed-content search, identifier matching, query/caret preservation through snapshots and inventory updates, and unchanged recording/grouping state. Run on mini1 with `UI_TEST_SCRIPT=Tests/WebUI/activity-search.js UI_TEST_EXPRESSION='runActivitySearchTests()'` through the same fixture runner.

`activity-performance.js`: 10,000-entry bounded lists, dense chart/strip canvases, full search and original hover identities. Run with the Activity fixture through the Classifier autosave runner on mini1.

`activity-scroll.js`: background snapshots defer hidden-scene rendering/history requests, preserve the newest-day and manually chosen timeline positions, render current data on return, and retain the outer viewport across recording-setting snapshots. Run with `UI_TEST_SCRIPT=Tests/WebUI/activity-scroll.js UI_TEST_EXPRESSION="runActivityScrollTests()"` through the same fixture runner.
