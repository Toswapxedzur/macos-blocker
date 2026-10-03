# Mac Vault কোড নির্দেশিকা

[ব্যবহারকারী নির্দেশিকা](../manual/bn.md)

## নিয়মের শর্ত

Source: একটি function expression `(on, v) => { ... }`। কেবল synchronous JavaScript ও নিচের API সমর্থিত; timer, network, native system API বা browser-page access নয়। সময়নির্ভর rule `ev.now` ও event ব্যবহার করে। Safari rule browser code manual ব্যবহার করে এবং Safari Vault-এর নিজস্ব containing app-এ চলে।

- সম্পাদনা draft save করে; **Run** rule activate করে ও group enable করে। Frozen group Run করা যায় না। খালি source rule unload করে।
- সফল Run handler/panel প্রতিস্থাপন করে এবং `v.state` রেখে এই group-এর app-block set মুছে। Compile/registration failure আগের rule রাখে; timeout থামাতে পারে। Restart শেষ activated source register করে; closure variable ও app-block set reset হয়।
- Registration state initialize, handler register, panel দেখাতে ও log করতে পারে। App/file action ও emit handler-এ রাখুন; registration-এর queue বাতিল।
- Disable handler থামায় ও panel/app block তোলে। Enable loaded rule এবং থাকা panel/block resume করে। Delete handler/state/effect মুছে। আগে quit করা app আবার খোলে না; file write ফেরানো হয় না।
- সাধারণ group target event সীমিত করে না; rule-এ app বেছে নিন। Action queue হয় ও dispatch-এর পরে চলে। Exception handler থামালেও তার state/action ফেরায় না; পরের handler চলতে পারে। কেবল file action result event দেয়।

## API

- `on(type, handler)` → boolean। `handler(ev)` নিবন্ধন করে; একাধিক handler registration order-এ চলে। False মানে invalid argument বা handler limit। `ev = { type: string, now: number, data }`; `now` Unix milliseconds।
- `v.state`: mutable JSON object, event dispatch-এর পরে সংরক্ষিত। পুরনো state না মুছে missing field initialize করুন। Object নয় বা array দিলে `{}` হয়; nonserializable/oversized update save হয় না।
- `v.log(...values)`: এই group-এর Log-এর একমাত্র উৎস। Log/Clear group-ভেদে আলাদা। Load error Run status-এ যায়; handler diagnostic Log-এ নয়।
- `v.emit(type, data)`: বর্তমান event-এর পরে group handler-এ `data`-র JSON copy queue করে, নতুন `now`-সহ; synchronous call নয়।
- `v.panel(id, spec)`: group-এর named floating panel প্রতিস্থাপন করে; null `spec` সরায়। Panels দেখুন।
- `v.file(op, path, payload?)` → request ID string। Files দেখুন।
- `v.block(appId, on)`: true app block বজায় রাখে, false এই group-এর block সরায়। Enabled group-এর block একত্র হয়; অন্য group-এর target unblock করা যায় না। Blocking স্বাভাবিক quit চায় এবং Settings interval-এ retry করে; process start ঠেকায় না, app Quit মানবে নিশ্চয়তা দেয় না।
- `v.quit(appId)`: একই protection/retry নীতিতে একবার normal quit; স্থায়ী block নয়।
- `v.open(appId)`: macOS-কে installed app খুলতে বলে; success callback নেই।

অন্য call `undefined` দেয়। App ID bundle identifier (যেমন `com.valvesoftware.steam`), event-এ পাওয়া যায়। Block/Quit `com.apple.*`, browser, Vault ও helper, এবং ফাঁকা ID উপেক্ষা করে। Panel ID/state group-এর, display name-এর নয়।

## Event

নিচের payload notation type বোঝায়, executable code নয়। `?` ঐচ্ছিক field চিহ্নিত করে।

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

- `tick` আনুমানিক; count নয়, timestamp ব্যবহার করুন। Running-এ foreground, menu-bar ও background `.app` process থাকে যাদের bundle ID আছে; সব Unix process নয়। Frontmost null বা ফাঁকা app ID হতে পারে।
- `app` ওই tick-এর `tick` event-এর আগে দেখা lifecycle change জানায়। কেবল focus-এ `previousAppId` থাকে (অজানা হলে null)। Name display name, স্থায়ী ID নয়।
- `snooze` মানে group-এর Snooze button চাপা হয়েছে। এটি নিজে pause করে না।
- File reply অনুরোধকারী group-এ যায়। `requestId` মিলিয়ে `ok` পরীক্ষা করে tick দিয়ে deadline দিন: rule reload/disable হলে reply হারাতে পারে। Run-এর পর request ID পুনরায় হতে পারে; pending request স্থায়ী কাজ নয়।

## Panel

```text
spec = { title?: string, description?: string, controls?: Control[],
         position?: "top-left" | "top-right" | "bottom-left" | "bottom-right" | "center",
         width?: "small" | "medium" | "large" | number }
Control = { id?: string, type?: string, label?: string, value?, disabled?: boolean,
            ...type-specific fields below }
```

Default: bottom-right position, width 300px; small/medium/large preset 220/280/360px; numeric width 180–520px-এ সীমাবদ্ধ এবং pixel string নেয়। Native panel/section control উল্লম্বভাবে সাজায়; browser layout, alignment, role, autofocus ও control dimension native renderer বদলায় না।

ID ASCII letter/digit/`_`/`-`-এ normalize (max 80); unique stable ID নিন। বাদ control ID `control-N`; বাদ/unknown type text। বাদ text/list ফাঁকা; disabled false। প্রতিটি call পুরো spec প্রতিস্থাপন করে। Explicit `value` stored input-কে অগ্রাহ্য করে; omitted value সর্বশেষ event value নিয়ে type normalization করে। Native event string দেয়: updated panel দেখানোর আগে declared value type-এ parse করুন। Unknown field বাদ যায়; panel color/font/CSS Vault-এর বিষয়।

Control field ও initial value:

- `text`: `text` string; default label। `html`: `html` string, sanitize করে Mac-এ plain text দেখায়।
- `button`: `label`, optional `action: "submit" | "cancel" | "close"`। Click value action string বা ফাঁকা। Action নিজে submit/close করে না।
- `checkbox`, `toggle`: boolean `value` (default false); event value `"true"`/`"false"`।
- `select`, `radio`: `options: (string | { value: string, label?: string })[]`; string value (default ফাঁকা)। Empty option value বাদ; label default value। Selection-এর পর panel-এর typed value update করুন।
- `textInput`, `textarea`: string value (default ফাঁকা); textInput `placeholder`; textarea `rows` 1–12 (default 3)। Native textarea placeholder উপেক্ষা করে।
- `numberInput`, `range`: numeric value (default 0), `min`, `max`, positive `step`। Panel update-এ value bound-এ সীমাবদ্ধ; unspecified normalization −1000000…1000000। Native numberInput text entry: নিজে `Number(event.value)` যাচাই করুন; min/max/step typing সীমাবদ্ধ করে না। Native range default 0…100, step 1।
- `date`, `time`: text entry; initial value `YYYY-MM-DD`, `HH:MM`/`HH:MM:SS` (invalid format ফাঁকা হয়)। Edit নিজে যাচাই করুন। `color`: `#RRGGBB` (default `#000000`)।
- `pin`: digit string; `length` 3–12 (default 6), `masked` default true, `autoSubmit` false। `section`: `text`, `controls`; depth 3-এর child section-এর child নেই (root control depth 0)।

Panel event: সাধারণ input `change`; button শুধু `click`; PIN `change`, autoSubmit পূর্ণ হলে `submit` পাঠায়। Native mount/unmount/focus/key event নেই। Number/boolean-সহ value string। `values` rendered snapshot-এর input value রাখে এবং triggering edit থেকে পিছিয়ে থাকতে পারে; `value` সেই edit চিহ্নিত করে। নির্ভরযোগ্য form-এর জন্য `v.state`-এ save করে typed value render করুন। Non-click event প্রতি control-এ 100ms-এর মধ্যে coalesce হয়; event-কে keystroke হিসেবে গণনা করবেন না।

Text limit: title/label 240; description/text 1000; HTML 20000; placeholder 500; input text 2000; অন্য value string 512; option value/label 256। অতিরিক্ত অংশ কাটা হয়।

## File

`op`: `"read"`, `"write"`, `"append"`, `"list"`, `"exists"`। Settings-এ **Custom-rule folder** ও permission লাগে।

- `path` relative; `/` directory আলাদা করে। Segment-এ ASCII letter/digit, space ও `_.,@()-` অনুমোদিত; leading dot, `.`/`..`, absolute path বা URL নয়। File suffix `.txt`, `.csv`, `.json` (case-insensitive)। List path directory; `""` নির্বাচিত root দেখায়। নির্বাচিত folder-এর বাইরে যাওয়া path, symlink দিয়েও, reject হয়।
- Read UTF-8 text দেয়। Write replace/create; append স্বয়ংক্রিয় newline ছাড়া append/create করে। Write-এ parent directory তৈরি হয়। String payload হুবহু লেখা হয়; অন্য JSON payload serialize হয়; null/omitted মানে ফাঁকা text। JSON/CSV parsing rule-এর কাজ। Max file size 1048576 UTF-8 byte।
- List সঙ্গে সঙ্গে দৃশ্যমান subdirectory ও supported file দেয়। Entry: `{ name: string, path: string, kind: "directory" | "file", extension?: string }`; file extension-এ dot থাকে। Exists supported file path-এর boolean দেয়।

```text
file.data = { requestId: string, op: string, path: string, ok: boolean,
              text: string | null, entries: Entry[] | null,
              exists: boolean | null, error: string }
```

Unused result field null; success-এ error ফাঁকা। Failure-এ invalid-path, unsupported-file-type, folder unavailable, missing file, file-too-large আছে। Error string, সম্পূর্ণ নির্দিষ্ট enum নয়। Transaction API নেই; প্রতি path-এ read-modify-write ধারাবাহিক করুন।

## সীমা

প্রতি event/group: 256 queued action, 200 log call, 64 emit; অতিরিক্ত বাদ। প্রতি rule: 1000 handler, 24 panel; প্রতি control list-এ 32 entry এবং choice-এ 64 option; অতিরিক্ত ignore/truncate। Emit chain 16 generation-এ থামে। Serialized state limit 65536 JavaScript character। Registration ও প্রতি event-এর combined handler 1 সেকেন্ডের মধ্যে রাখুন; বারবার limit ছাড়ালে বা hard timeout হলে Run পর্যন্ত rule থামে। প্রতি group-এ Log 200 entry রাখে। Timing/reply best-effort, real-time guarantee নয়।

## সম্পূর্ণ নিয়ম

Snooze বা তার panel button চালু করা পাঁচ মিনিটের বিরতি ছাড়া Steam blocked থাকে:

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
