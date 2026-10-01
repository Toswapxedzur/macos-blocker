# Mac Vault manual

Mac Vault combines native app blocking, local content tagging, and Activity. Its browser editor shares blocking-group controls with the Vault browser extension. The extension enforces browser pages and feeds; Mac Vault enforces native app targets. Mac Vault's custom-rule runtime controls apps rather than browser tabs or page elements.

## Blocking groups

A **blocking group** applies one blocking policy to its selected targets. It is distinct from a **Classifier group**, which assigns tags to content.

- Add a group, give it a unique name, and choose its targets under **Applies to**. Targets in the same group share its schedule and time allowance.
- Routine field edits save automatically. Custom-rule source takes effect when you press **Run**.
- Disable a group to stop its policy while keeping its settings. Use **Delete group** to remove it. Import replaces the selected group's configuration after confirmation; Export copies its configuration as a group string.
- Drag groups to reorder them. Multiple blocking groups can apply to the same target; snoozing one does not remove another group's block.

### Time allowance and schedule

**Block immediately** applies whenever the enabled group matches and its schedule is active. **Block when the time allowance is used** allows matching use until the allowance runs out.

Set the allowance in minutes and its reset interval in hours. The rolling-limit option counts use within the preceding window rather than resetting the whole allowance periodically. The midnight option resets the period at local midnight.

Choose active weekdays and optional local-time windows, one per line, such as `09:00-12:00`. An empty window list applies throughout the selected days. A window's end must be later than its start on the same day; split an overnight schedule into separate days. Custom rules make their own scheduling decisions.

### Snooze

Configure snooze separately in each blocking group. New groups start with 30 minutes; there is no global duration setting.

- **Pause blocking** makes that group temporarily inactive for the configured pause duration.
- **Add to the time allowance**, available for time-limited groups, adds usable minutes instead of pausing blocking. Only consumed extra allowance counts as snoozed time. Unused extra time expires at the next allowance reset; for a rolling limit, it expires after one rolling window, or sooner at midnight if enabled.
- **Activation delay** postpones the effect; the group still applies while the request is pending.
- **Cooldown** controls how long you must wait after snooze ends before requesting another one.
- **Required confirmations** sets how many confirmation steps are needed.

The Snooze button on a custom-rule group sends its rule a `"snooze"` event. The rule decides what to do; normal-group snooze settings do not apply.

### Freeze and PIN

**Freeze** prevents routine edits. A frozen group has combined conditions for unfreezing rather than separate freeze modes:

- **Wait before unfreezing**: 0 means no wait; the maximum is 72 hours.
- **PIN**: when set, the group's six-digit PIN is required.
- **Confirmations**: every unfreeze requires ten confirmations, five seconds apart.

While frozen, the wait can be extended and a PIN can be added where none was set. These conditions cannot be weakened until the group is unfrozen. Snooze remains available only if it was allowed before freezing.

### Linked groups

Link explicitly selected groups through the local Vault bridge. Linked groups share supported policy and usage fields while the participating programs are connected. Browser-only and native-only actions still depend on the program enforcing them. An offline member can prevent coordinated edits; open the linked program to restore synchronization. Unlinking keeps the local group.

## Custom rules

A rule is one JavaScript function expression, `(on, v) => { ... }`. It registers event handlers rather than returning a decision on every tick. **Run** replaces its previous handlers. Disabling the group suspends its handlers and lifts its effects; enabling it resumes the loaded rule.

`v.state` holds the group's persistent JSON state. `v.log(...)` is the only source of entries in that group's **Log** panel. Logs are segregated by group. A run failure is shown by the Run status, not injected into Log.

Use **Write with AI**, describe the desired behavior, and **Copy AI prompt** to copy your request, current source, and the supported API reference. Paste the prompt into your AI tool, then paste its generated rule back into Vault and press Run.

Rules run in a sandbox. They have no direct network, DOM, or timer access. Use only the actions and events listed below. Select a **Custom-rule folder** in Settings for `v.file` access to `.txt`, `.csv`, and `.json` files. Paths stay inside that selected folder.

## Native app targets

Under **Applies to**, add an Apps target and use the + picker to select installed apps. **Block every app except these** makes the list an allowlist. System apps, browsers, and Vault itself are excluded from app blocking. App identity uses its bundle identifier.

A blocked app is asked to quit. **Ask a blocked app to quit again every (minutes)** controls retries. A custom rule can ask an app to quit once or maintain a block with the API below.

Website and platform targets are enforced by the linked browser extension. Browser-only redirect, pause, and feed controls do not become native app actions.

## Classifier groups

A **Classifier group** tags content from its assigned platforms with its own tag tree and model settings. Each platform belongs to one Classifier group; choose platforms when creating the group.

Enable tagging in **Classifier Settings**. Each group also has **Pause tagging / Resume tagging**. Blocking-group filters and schedules do not control tagging. Turning off Activity recording for a platform also stops its content from being tagged.

- **Tag tree**: create and edit tags, describe their meaning, and set or remove a parent. Drag a tag to move its branch.
- **Speed ↔ Quality**: choose a local model tier. Larger models require more memory; performance depends on the Mac and workload. Downloads are shared between groups.
- **Strict ↔ Broad**: choose confidence requirements and default tag counts. Custom minimum and maximum counts in More replace the default counts while this setting still governs confidence for additional tags.
- **Tagging instructions**: optional additional instructions for this group.

Routine edits save automatically. Selecting a model tier may require a model download before tagging can run.

## Web research and Knowledge

**Knowledge** stores short descriptions of content sources and terms for the local tagging model. Content sources include creators, accounts, channels, and communities. Source descriptions accompany their content; term descriptions apply when the term appears in a title.

Add a source or term manually, or let repeated tagging difficulties trigger web research. An empty description requests research where research is enabled. Editing a description affects future tagging; deleting it does not prevent later research from recreating it.

Configure **API keys & providers** in Classifier Settings. **Add provider** creates a configuration; it does not issue a new API key. Obtain credentials from that provider and enter them here. Keys are stored in this app's support folder on this Mac, not the system Keychain. They authenticate requests to the configured provider; Vault does not upload them to its own server.

For web research, choose a provider with built-in web search, fetch its model list, and select a model. A successful **Test connection** confirms that test request succeeded, not that every model supports research. Give research consent in Classifier Settings; per-group research choices cannot bypass it. **Set up web research…** opens the required settings when configuration is missing.

Research requests contain sanitized public subjects, not private content bodies or summaries. See the research consent disclosure for the exact fields. Research usage shows the token allowance and the status of queued requests and retries. Provider usage elsewhere also includes connection and model-list requests.

## Activity

Activity records enabled apps, websites, and supported platform content locally. **Content viewed** includes more than videos. The **Timeline** shows use at its time of day; **Totals** groups durations. The configurable **Time interval** aggregates adjacent time into vertical blocks. **Colors** chooses how sources are distinguished. Select a day to see use since that day.

## Supported custom-rule API

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
