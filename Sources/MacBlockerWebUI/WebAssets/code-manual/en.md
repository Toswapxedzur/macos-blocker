# Mac Vault code manual

[Back to the user manual](../manual/en.md)

## Write and activate a rule

A custom rule is one JavaScript function expression: `(on, v) => { ... }`. The editor colors JavaScript syntax; coloring does not establish that a rule is valid or safe to run. Editing saves the source. **Run** loads it and replaces the previous handlers. Check Run status for loading errors.

**Copy code docs** copies this platform's code manual. It does not include your group's source, send a request to an AI service, or run a rule. You can use these docs in your own editor or AI tool.

Disabling the group suspends its handlers and lifts its effects. Enabling resumes the loaded rule. Deleting the group removes its handlers and persistent state. Built-in schedules and snooze settings are replaced by the behavior your custom rule implements.

## Events, state, and logs

Register synchronous handlers with `on(type, handler)`. The function runs once on Run; handlers respond to later events. Use `v.state` for the group's persistent JSON state. Run preserves that state.

Only `v.log(...)` adds entries to this group's **Log**. Each group has its own log; clearing one does not clear another. Loading and runtime failures appear in status rather than adding log entries. The Snooze button sends a `"snooze"` event; its handler decides the effect.

Rules have no direct network, DOM, or timer access. Browser page operations must use the browser API below. File access uses the folder selected under **Custom-rule folder** in Settings. Only `.txt`, `.csv`, and `.json` paths relative to that folder are supported. A file request returns an ID immediately and reports its result in a later `"file"` event.

## Example

Block Steam overnight on this Mac. This example’s Snooze handler lifts the block only until the next tick; implement your own duration in persistent state if needed.

```javascript
(on, v) => {
  on("tick", () => {
    const hour = new Date().getHours();
    v.block("com.valvesoftware.steam", hour >= 22 || hour < 7);
  });
  on("snooze", () => {
    v.block("com.valvesoftware.steam", false);
    v.log("Block lifted until the next tick.");
  });
}
```

## Supported API

These actions control native apps. They cannot navigate browser tabs or hide page elements. Safari’s native transport still uses the browser API for Safari rules.


- CUSTOM RULE API — use only what is listed; there are no other helpers.

- A rule is ONE JavaScript function expression: (on, v) => { … }. It runs once when the user presses Run: register handlers there. Run replaces the old handlers; deleting the group removes them. While the group is disabled no handler runs and what the rule did is lifted (its panels, style sheets, covers, blocks); enabling it resumes the rule as it was.

- on(type, handler) adds a handler; several per type are fine. handler(ev) gets ev = { type, now (ms since 1970), data }. Handlers are synchronous and must finish within 1 s: no loops that wait, no network, no timers, no DOM of your own (you run in a sandbox).

- v.state is the group's memory: one JSON object (≤ 64 KB), kept across restarts and across Run (a new version of the rule finds what the old one saved), deleted with the group. Change it freely inside handlers.

- v.log(...values) writes to the group's log in the editor.

- v.emit(type, data) delivers a "type" event with that data to this group, right after the current one.

- v.panel(id, spec, tabId?) shows a panel (spec = { title, description, position: top-left|top-right|bottom-left|bottom-right|center, layout, width: small|medium|large, controls: [...] }); calling again replaces it; v.panel(id, null) removes it. Controls: { id, type, label, value, ... } with type text (text), html (html, sanitized; inherits Vault colors/font and discards CSS), button (action submit|cancel|close), checkbox, toggle, select / radio (options), textInput / textarea (placeholder), numberInput / range (min, max, step), date, time, color, pin (length, masked), section (controls). Interactions arrive as "panel" events: data = { panelId, controlId, eventName, value, values }.

- v.file(op, path, payload?) uses the folder the user chose in Settings (.txt, .csv, .json; paths relative to it): op read | write | append | list | exists. It returns a request id; the answer arrives as a "file" event: data = { requestId, ok, op, path, text, entries, exists, error }.

- Other events: "snooze" (the user pressed the group's Snooze), plus every type you v.emit.

- Limits per event: 256 actions, 200 log entries, 64 emits; 24 panels of 32 controls per group.

- ENGINE: Mac Vault. It controls apps only (never websites).

- "tick" every second: data = { frontmost: { appId, name } | null, running: [{ appId, name }] } — every running app, menu-bar and background ones included.

- "app" when an app launches, quits, comes to the front or leaves it, hides or unhides: data = { kind: launch | quit | focus | blur | hide | unhide, appId, name, previousAppId (focus only) }.

- v.block(appId, on) blocks an app (asked to quit, again after Settings' retry interval) until v.block(appId, false), Run, or the group is disabled; v.quit(appId) asks it to quit once; v.open(appId) opens it. appId is a bundle identifier. Apple's own apps (com.apple.*), browsers (their extension controls them) and Mac Vault are never blocked or quit.

- EXAMPLE: (on, v) => { on("tick", () => { const h = new Date().getHours(); v.block("com.valvesoftware.steam", h >= 22 || h < 7); }); }
