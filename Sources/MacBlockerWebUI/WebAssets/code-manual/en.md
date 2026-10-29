# Mac Vault code manual

[User manual](../manual/en.md)

## Rule contract

Source: one function expression `(on, v) => { ... }`. Only synchronous JavaScript and the API below are supported; no JavaScript scheduling callbacks, network, native system APIs or browser-page access. Time-based rules use managed timers/trackers below, or `ev.now` and events. Safari rules use the browser code manual and run in Safari Vault's own containing app.

- Editing saves a draft; **Run** activates it and enables the group. Frozen groups cannot Run. Empty source unloads the rule.
- Successful Run replaces handlers/panels and clears this group's app-block set, preserving `v.state`. Compilation/registration failure keeps the previous rule; a timeout can stop it. Restart registers the last activated source again; closure variables and app-block sets reset.
- Registration may initialize state, register handlers, show panels and log. App/file actions and emits belong in handlers; their registration-time queue is discarded.
- Disable suppresses handlers and lifts panels/app blocks. Enable resumes the loaded rule and its retained panels/blocks. Delete removes its handlers/state/effects. Previously quit apps are not reopened; file writes are not undone.
- Events are not restricted by ordinary group targets; select apps in the rule. Actions are queued, then applied after dispatch. Exceptions stop that handler without rolling back its state/actions; later handlers may still run. File, AI and record requests have result events.

## Managed timers and rolling usage

`v.timer(id, {direction:"down", durationMs:300000})` creates or returns a named countdown, initially paused. Use `{direction:"up"}` for a count-up timer. The handle has `start()`, `pause()`, `resume()`, `reset()` and `snapshot()`. Start/resume are idempotent; reset returns to paused zero elapsed. Snapshot fields include `ready`, `error`, `elapsedMs`, `remainingMs` (null for count-up), `running` and `completed`.

Running timers advance by wall-clock time while the app/browser is closed or the rule is disabled. A completed countdown delivers `timerEnded` with `{id, direction, durationMs, generation, incarnation}` once per timer incarnation and generation for each member when its rule next runs; Run does not replay it. Delivery depends on host events; this is not a real-time alarm. Put `{type:"timer", timerId:"focus", label:"Focus"}` in a panel to display it through the existing text control.

`v.rolling(id, {windowMs:3600000, limitMs:600000})` creates or returns a named active-use tracker. `assign({websites:["youtube.com","reddit.com"], apps:[]})` replaces this member's target assignments. Native rules can assign platform app IDs instead. Domains include subdomains. One tracker pools its targets; other IDs have independent allowances. `snapshot()` returns `ready`, `error`, `usedMs`, `remainingMs`, `available`, and `nextReturnAtMs` (the next millisecond that any recorded usage expires). `available(target?)` also checks assignment when a target is supplied. `reset()` clears this object's history.

All observed eligible usage counts, including usage beyond the allowance; the tracker itself does not block a page/app. Overlapping visible-page intervals count once, and native apps count observed foreground usage. Disabled rules add no usage; history still expires at exact interval boundaries. Availability returns only when the remaining history is below the limit. Heartbeat samples are bounded to five seconds; shutdown/disabled gaps do not manufacture activity. User-emitted events do not add usage.

Same object IDs in linked custom groups share one local native-hub authority. Linking combines tracker history and assignments and keeps the initiating timer state; incompatible configurations refuse linking. Each member receives its own completion event. Disconnection makes shared trackers unavailable and rejects timer controls until fresh authority returns. On unlink, each member keeps final shared usage and timer state, restores its own targets, and drops commands from the old link. The hub retains the final snapshot until the returning member saves and acknowledges it; pending handovers finish before a new link becomes available.

Named objects survive Run and restart in reserved `v.state.$vaultTime`; do not edit that field directly. Remove explicitly with `v.removeTime(id)`. IDs are 1–80 ASCII letters, digits, `_` or `-`; reserved property names are refused. Up to32 objects share the rule's64KiB UTF-8 state limit. Durations are integer milliseconds up to365days. Rolling history is bounded to1024 minute buckets and2048 merged intervals. History-capacity errors leave the tracker unavailable until explicitly reset; invalid configurations and oversized saves report errors without erasing saved data.

```js
(on, v) => {
  const timer = v.timer("focus", {durationMs: 300000});
  v.panel("focus", {controls: [
    {type: "timer", timerId: "focus", label: "Focus"},
    {id: "start", type: "button", label: "Start"},
    {id: "pause", type: "button", label: "Pause"},
    {id: "reset", type: "button", label: "Reset"}
  ]});
  on("panel", ev => {
    if (ev.data.eventName !== "click") return;
    if (ev.data.controlId === "start") timer.start();
    if (ev.data.controlId === "pause") timer.pause();
    if (ev.data.controlId === "reset") timer.reset();
  });
  on("timerEnded", ev => v.log("Finished", ev.data.id));
}
```

## API

- `on(type, handler)` → boolean. Registers `handler(ev)`; multiple handlers run in registration order. False means invalid arguments or handler limit reached. `ev = { type: string, now: number, origin: "host" | "user" | "rule", data }`; `now` is Unix milliseconds. Native panel input has `origin: "user"`; `v.emit` has `origin: "rule"`.
- `v.state`: mutable JSON object, persisted after event dispatch. Initialize missing fields rather than overwriting existing state. Assigning a non-object or array resets it to `{}`; nonserializable/oversized updates are not persisted.
- `v.log(...values)`: appends to this group's Log. Execution and delivery failures appear as explicit error entries in the same feed. Logs/Clear are independent per group. Load errors also appear in Run status; partially executed events are not replayed automatically.
- `v.emit(type, data)`: queues a JSON copy of `data` for this group's handlers after the current event, with a fresh `now`; not a synchronous call.
- `v.panel(id, spec)`: replaces this group's named floating panel; null `spec` removes it. See Panels.
- `v.file(op, path, payload?)` → request ID string. See Files.
- `v.store(request)` → request ID string. See Group records.
- `v.block(appId, on)`: true maintains an app block, false removes this group's block. Blocks combine across enabled groups; this call cannot unblock another group's target. Blocking requests a normal quit and retries at the Settings interval; it does not prevent process launch or guarantee an app accepts Quit.
- `v.quit(appId)`: one normal quit request, subject to the same protection/retry policy; no ongoing block.
- `v.open(appId)`: asks macOS to open an installed app; no success callback.

Other calls return `undefined`. App IDs are bundle identifiers (for example `com.valvesoftware.steam`), available in events. Block/Quit can target Apple apps and whole browsers. They ignore Mac Vault's bundle identifier and its helpers, including any other app sharing that identity, and empty IDs. Panel IDs/state belong to one group, not its display name.

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
record: { requestId: string, ok: boolean, op?: string, key?: string,
          record?: Record | null, entries?: Header[], next?: string | null,
          deleted?: number, error?: string }
App = { appId: string, name: string }
```

- `tick` is approximate; use timestamps, not tick counts. Running includes foreground, menu-bar and background `.app` processes with bundle IDs; not every Unix process. Frontmost can be null or have an empty app ID.
- `app` reports observed lifecycle changes before that tick's `tick` event. Only focus includes `previousAppId` (null if unknown). Names are display names, not stable IDs.
- `snooze` means the group's Snooze button was pressed. It applies no pause by itself.
- File and record replies target the requesting group. Correlate `requestId`, check `ok`, and set a deadline using ticks: replies can be lost if the rule reloads/is disabled. Request IDs can repeat after Run; pending requests are not durable work.

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

## Group records

`v.store(request)` starts an asynchronous JSON record operation inside a handler.
Records are private to this group, persist across Run and restart, and are
removed with the group. Linked groups have separate records. The rule chooses
keys, values, version strings, cache invalidation and feedback precedence.
Mac and browser rules use the same API, but each app/browser store is separate.

| Request | Result |
| --- | --- |
| `{op:"get", key}` | `record` or `null` |
| `{op:"put", key, value, version?, ifRevision?}` | saved `record` |
| `{op:"delete", key, ifRevision?}` | `record: null` |
| `{op:"list", prefix?, after?, limit?}` | sorted `entries` of headers and `next` cursor |
| `{op:"clear", prefix?}` | `deleted` count |

Each record has `{value, revision, version, updatedAt}`. The opaque revision
changes on a real write. `version` is caller-owned metadata. `list` returns
headers without values; use `get` to read one. Use `after: next` for the next
page. For `put`/`delete`, omitted `ifRevision` means unconditional. `null`
requires an absent key; a revision string requires an exact match. A mismatch
returns `ok:false`, `error:"store-conflict"` and the current `record`. Use
this to prevent delayed automatic replies from overwriting user feedback.
`v.context.revision` is an opaque rule-configuration marker that a rule may
include in its own version. The framework does not impose cache policy.

Limits: key1–2048 characters, version≤128, JSON value≤64KiB, depth≤32,
10000 keys per group,16MiB whole record document. `list` returns at most100
headers and96KiB per page. At most32 requests per group and128 total requests
start per second; overload reports one `store-busy` error per group per second
and drops further requests that second. Storage errors return `ok:false`; a
future or malformed record document is preserved and reported as
`store-unavailable`. There is no automatic retry or eviction. Use ticks for
deadlines when a reply matters.

## Limits

Per event per group: 256 queued actions, 200 log calls, 64 emits; excess is dropped. Per rule: 1000 handlers, 24 panels; each control list has 32 entries and each choice 64 options; excess is ignored/truncated. Emit chains stop after 16 generations. Serialized state limit:65536 UTF-8 bytes. Keep registration and each event's combined handlers under 1 second; repeated overruns or a hard timeout stop the rule until Run. Log retains 200 entries per group. Timing/replies are best-effort, not real-time guarantees.

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


## AI calls from a running rule

Each custom group selects one connection/model and reasoning effort in **AI calls**.
Use the same API on Mac and in browser rules. Browser requests require connected
Mac Vault; provider credentials stay there. Linked groups share the selection and
optional daily request cap. Blank means no group cap; account limits still apply.
The cap uses the UTC day, persists across restart, and counts submitted attempts
including failures. Linking combines existing usage; unlinking retains prior usage.

`v.ai({ prompt, input? })` returns a request ID immediately. Call it inside a handler,
not while registering the rule. `input` may be any JSON value; each prompt/input is
limited to20KB. Replies arrive as `ai` events: `{requestId, ok, text, citations,
error}`. Success text is at most48KB; citations are `{url,title}`. Preserve visible,
clickable source links when displaying answers based on web search. Search is always
available to the model. Generation requests have no fixed app deadline and retain bounded concurrency;
there is no provider fallback or automatic retry. Responses are data, never executed
as JavaScript. The rule decides which existing actions to take.

For a panel with an `ask` button and `note` field:

```javascript
(on, v) => {
  let pending = null;
  on("panel", ({ data }) => {
    if (data.controlId !== "ask" || pending) return;
    pending = v.ai({ prompt: "Summarize this text.", input: data.values?.note ?? "" });
  });
  on("ai", ({ data }) => {
    if (data.requestId !== pending) return;
    pending = null;
    if (!data.ok) { v.log("AI request failed:", data.error); return; }
    v.log(data.text, data.citations);
  });
}
```

Outstanding calls are not replayed after restart. Run, disable/re-enable and deletion
discard obsolete replies; a disconnected browser reports `ai-unavailable`. Other
errors include `ai-not-configured`, `ai-invalid-input`, `ai-busy`, `ai-daily-limit`,
`ai-request-failed` and `ai-usage-storage-unavailable`. Failed calls do
not overwrite a previous result the rule chose to retain. Rule state still has its
existing64KB limit.

Tools can discover credential-free choices with `rule_ai_models` on Mac, or the
browser's `settings-rule-ai-models`, and configure `ruleAI` through the existing
set-group path. Its fields are `providerModel`, `accountID`, `reasoningEffort`
(`default`, `low`, `medium`, `high`) and `dailyRequestLimit` (null or1–100000).
Use a returned choice; do not put a key or provider URL into rule source.
