# Mac Vault code manual

[User manual](../manual/en.md)

## Rule contract

Source: one function expression `(on, v) => { ... }`. Only synchronous JavaScript and the API below are supported; no timers, network, native system APIs or browser-page access. Time-based rules use `ev.now` and events. Safari rules use the browser code manual and run in Safari Vault's own containing app.

- Editing saves a draft; **Run** activates it and enables the group. Frozen groups cannot Run. Empty source unloads the rule.
- Successful Run replaces handlers/panels and clears this group's app-block set, preserving `v.state`. Compilation/registration failure keeps the previous rule; a timeout can stop it. Restart registers the last activated source again; closure variables and app-block sets reset.
- Registration may initialize state, register handlers, show panels and log. App/file actions and emits belong in handlers; their registration-time queue is discarded.
- Disable suppresses handlers and lifts panels/app blocks. Enable resumes the loaded rule and its retained panels/blocks. Delete removes its handlers/state/effects. Previously quit apps are not reopened; file writes are not undone.
- Events are not restricted by ordinary group targets; select apps in the rule. Actions are queued, then applied after dispatch. Exceptions stop that handler without rolling back its state/actions; later handlers may still run. Only file actions have result events.

## API

- `on(type, handler)` → boolean. Registers `handler(ev)`; multiple handlers run in registration order. False means invalid arguments or handler limit reached. `ev = { type: string, now: number, data }`; `now` is Unix milliseconds.
- `v.state`: mutable JSON object, persisted after event dispatch. Initialize missing fields rather than overwriting existing state. Assigning a non-object or array resets it to `{}`; nonserializable/oversized updates are not persisted.
- `v.log(...values)`: the only producer of this group's Log. Logs/Clear are independent per group. Load errors appear in Run status; handler diagnostics do not populate Log.
- `v.emit(type, data)`: queues a JSON copy of `data` for this group's handlers after the current event, with a fresh `now`; not a synchronous call.
- `v.panel(id, spec)`: replaces this group's named floating panel; null `spec` removes it. See Panels.
- `v.file(op, path, payload?)` → request ID string. See Files.
- `v.block(appId, on)`: true maintains an app block, false removes this group's block. Blocks combine across enabled groups; this call cannot unblock another group's target. Blocking requests a normal quit and retries at the Settings interval; it does not prevent process launch or guarantee an app accepts Quit.
- `v.quit(appId)`: one normal quit request, subject to the same protection/retry policy; no ongoing block.
- `v.open(appId)`: asks macOS to open an installed app; no success callback.

Other calls return `undefined`. App IDs are bundle identifiers (for example `com.valvesoftware.steam`), available in events. Block/Quit ignore `com.apple.*`, browsers, Vault and its helpers, and empty IDs. Panel IDs/state belong to one group, not its display name.

## Events

Payload notation below describes types; it is not executable code. `?` marks optional fields.

```text
tick (~1 second): { frontmost: App | null, running: App[] }
app: { kind: "launch" | "quit" | "focus" | "blur" | "hide" | "unhide",
       appId: string, name: string, previousAppId?: string | null }
snooze: {}
panel: { panelId: string, controlId: string, eventName: string,
         value: string, values: { [controlId: string]: string } }
file: see Files
App = { appId: string, name: string }
```

- `tick` is approximate; use timestamps, not tick counts. Running includes foreground, menu-bar and background `.app` processes with bundle IDs; not every Unix process. Frontmost can be null or have an empty app ID.
- `app` reports observed lifecycle changes before that tick's `tick` event. Only focus includes `previousAppId` (null if unknown). Names are display names, not stable IDs.
- `snooze` means the group's Snooze button was pressed. It applies no pause by itself.
- File replies target the requesting group. Correlate `requestId`, check `ok`, and set a deadline using ticks: replies can be lost if the rule reloads/is disabled. Request IDs can repeat after Run; pending requests are not durable work.

## Panels

```text
spec = { title?: string, description?: string, controls?: Control[],
         position?: "top-left" | "top-right" | "bottom-left" | "bottom-right" | "center",
         width?: "small" | "medium" | "large" | number }
Control = { id?: string, type?: string, label?: string, value?, disabled?: boolean,
            ...type-specific fields below }
```

Defaults: position bottom-right, width 300px; presets small/medium/large are 220/280/360px; numeric width clamps to 180–520px and accepts pixel strings. Native panels/sections stack controls vertically; browser layout, alignment, role, autofocus and control-dimension fields do not affect the native renderer.

IDs normalize to ASCII letters/digits/`_`/`-` (max 80); choose unique stable IDs. Omitted control ID becomes `control-N`, omitted/unknown type becomes text. Omitted text/lists are empty; disabled is false. Each call replaces the whole spec. Explicit `value` overrides stored input; omitted value uses the last event value then type normalization. Native events supply strings: parse them into the declared value type before rendering an updated panel. Unknown fields are discarded; panel colors/fonts/CSS belong to Vault.

Control fields and initial values:

- `text`: `text` string; defaults to label. `html`: `html` string, sanitized and displayed as plain text on Mac.
- `button`: `label`, optional `action: "submit" | "cancel" | "close"`. Click value is the action string, or empty. Actions do not submit/close anything automatically.
- `checkbox`, `toggle`: boolean `value` (default false); event value is `"true"`/`"false"`.
- `select`, `radio`: `options: (string | { value: string, label?: string })[]`; string value (default empty). Empty option values removed; labels default to value. Update the panel's typed value after selection.
- `textInput`, `textarea`: string value (default empty); textInput `placeholder`; textarea `rows` 1–12 (default 3). Native textarea ignores placeholder.
- `numberInput`, `range`: numeric value (default 0), `min`, `max`, positive `step`. Values clamp to bounds on panel updates; unspecified normalization bounds are −1000000…1000000. Native numberInput is text entry: validate `Number(event.value)` yourself; min/max/step do not constrain typing. Native range defaults to 0…100 with step 1.
- `date`, `time`: text entry; initial value formats `YYYY-MM-DD`, `HH:MM`/`HH:MM:SS` (invalid initial formats become empty). Validate edits yourself. `color`: `#RRGGBB` (default `#000000`).
- `pin`: digit string; `length` 3–12 (default 6), `masked` true by default, `autoSubmit` false. `section`: `text`, `controls`; child sections at depth 3 have no children (root controls depth 0).

Panel events: ordinary inputs send `change`; buttons send `click` only; PIN sends `change`, plus `submit` when autoSubmit fills it. No native mount/unmount/focus/key events. Values are strings, including numbers/booleans. `values` contains the rendered snapshot's input values and may lag the triggering edit; `value` identifies that edit. Save it into `v.state` and render typed values for reliable forms. Non-click events are coalesced within 100ms per control; do not count events as keystrokes.

Text limits: title/label 240; description/text 1000; HTML 20000; placeholder 500; input text 2000; other value strings 512; option value/label 256. Excess is truncated.

## Files

`op`: `"read"`, `"write"`, `"append"`, `"list"`, `"exists"`. Requires **Custom-rule folder** in Settings and its permission.

- `path` is relative; `/` separates directories. Segments permit ASCII letters/digits, spaces and `_.,@()-`; no leading dot, `.`/`..`, absolute path or URL. File suffix: `.txt`, `.csv`, `.json` (case-insensitive). List path is a directory; `""` lists the chosen root. Paths escaping the chosen folder, including through symlinks, are rejected.
- Read returns UTF-8 text. Write replaces/creates; append creates/appends without an automatic newline. Parent directories are created on writes. String payload is written verbatim; other JSON payloads are serialized; null/omitted means empty text. JSON/CSV parsing is the rule's job. Maximum file size: 1048576 UTF-8 bytes.
- List returns immediate visible subdirectories and supported files. Entries: `{ name: string, path: string, kind: "directory" | "file", extension?: string }`; extension includes the dot on files. Exists returns a boolean for a supported file path.

```text
file.data = { requestId: string, op: string, path: string, ok: boolean,
              text: string | null, entries: Entry[] | null,
              exists: boolean | null, error: string }
```

Unused result fields are null; success has empty error. Failures include invalid-path, unsupported-file-type, folder unavailable, missing file and file-too-large. Treat error as a string, not a fixed exhaustive enum. No transaction API; serialize read-modify-write operations per path.

## Limits

Per event per group: 256 queued actions, 200 log calls, 64 emits; excess is dropped. Per rule: 1000 handlers, 24 panels; each control list has 32 entries and each choice 64 options; excess is ignored/truncated. Emit chains stop after 16 generations. Serialized state limit: 65536 JavaScript string characters. Keep registration and each event's combined handlers under 1 second; repeated overruns or a hard timeout stop the rule until Run. Log retains 200 entries per group. Timing/replies are best-effort, not real-time guarantees.

## Complete rule

Steam is blocked except during a five-minute pause triggered by Snooze or its panel button:

```javascript
(on, v) => {
  v.state.pauseUntil ??= 0;
  const pause = ev => { v.state.pauseUntil = ev.now + 300000; };
  v.panel("pause", { controls: [{ id: "pause", type: "button", label: "Pause 5 min" }] });
  on("snooze", pause);
  on("panel", ev => {
    if (ev.data.panelId === "pause" && ev.data.controlId === "pause" && ev.data.eventName === "click") pause(ev);
  });
  on("tick", ev => v.block("com.valvesoftware.steam", ev.now >= v.state.pauseUntil));
}
```
