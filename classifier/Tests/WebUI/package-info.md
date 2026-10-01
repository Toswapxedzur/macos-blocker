# Classifier Web UI regressions

`autosave.html` renders the production Classifier assets with synthetic local
state and an in-memory native-action receiver. `autosave.mjs` serves that
fixture and drives Chrome for Testing through CDP on mini1. It checks real
input/change/focus/composition handlers, delayed snapshots and explicit actions;
it never connects to the owner's Classifier state or any provider.

Run on mini1 from the Mac Vault repository:
`~/.local/node/bin/node classifier/Tests/WebUI/autosave.mjs`.
Chrome for Testing must already expose loopback CDP at port 9222.
An optional first argument saves a screenshot to that path.
