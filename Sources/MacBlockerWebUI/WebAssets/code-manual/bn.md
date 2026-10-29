# Mac Vault কোড নির্দেশিকা

[ব্যবহারকারী নির্দেশিকা](../manual/bn.md)

## নিয়মের শর্ত

উৎস: একটি function expression `(on, v) => { ... }`। শুধু synchronous JavaScript ও নিচের API সমর্থিত; JavaScript-এর সময়সূচিভিত্তিক callback, network, native system API বা browser-page অ্যাক্সেস নেই। সময়নির্ভর নিয়মে নিচের পরিচালিত timer/tracker অথবা `ev.now` ও event ব্যবহার করুন। Safari rule browser code manual ব্যবহার করে এবং Safari Vault-এর নিজস্ব containing app-এ চলে।

- সম্পাদনা draft save করে; **Run** rule activate করে ও group enable করে। Frozen group Run করা যায় না। খালি source rule unload করে।
- সফল Run handler/panel প্রতিস্থাপন করে এবং `v.state` রেখে এই group-এর app-block set মুছে। Compile/registration failure আগের rule রাখে; timeout থামাতে পারে। Restart শেষ activated source register করে; closure variable ও app-block set reset হয়।
- Registration state initialize, handler register, panel দেখাতে ও log করতে পারে। App/file action ও emit handler-এ রাখুন; registration-এর queue বাতিল।
- Disable handler থামায় ও panel/app block তোলে। Enable loaded rule এবং থাকা panel/block resume করে। Delete handler/state/effect মুছে। আগে quit করা app আবার খোলে না; file write ফেরানো হয় না।
- সাধারণ group target event সীমিত করে না; rule-এ app বেছে নিন। Action queue হয় ও dispatch-এর পরে চলে। Exception handler থামালেও তার state/action ফেরায় না; পরের handler চলতে পারে। কেবল file action result event দেয়।

## পরিচালিত টাইমার ও চলমান সময়সীমার ব্যবহার

`v.timer(id, {direction:"down", durationMs:300000})` একটি নামযুক্ত countdown তৈরি করে অথবা বিদ্যমানটি ফেরত দেয়; শুরুতে সেটি paused থাকে। Count-up timer-এর জন্য `{direction:"up"}` ব্যবহার করুন। Handle-এ আছে `start()`, `pause()`, `resume()`, `reset()` ও `snapshot()`। Start/resume বারবার ডাকলেও একই ফল হয়; reset করলে elapsed সময় শূন্য হয়ে paused অবস্থায় ফেরে। Snapshot field-এর মধ্যে আছে `ready`, `error`, `elapsedMs`, `remainingMs` (count-up-এর জন্য null), `running` ও `completed`।

App/browser বন্ধ থাকলেও বা rule disabled থাকলেও চলমান timer ঘড়ির প্রকৃত সময় অনুযায়ী এগোয়। Countdown শেষ হলে প্রতিটি timer incarnation ও generation-এর জন্য প্রতিটি member-এর rule পরেরবার চলার সময় একবার `timerEnded` এবং `{id, direction, durationMs, generation, incarnation}` পৌঁছে দেয়; Run এটি আবার পাঠায় না। Delivery host event-এর ওপর নির্ভর করে; এটি real-time alarm নয়। বিদ্যমান text control দিয়ে দেখাতে panel-এ `{type:"timer", timerId:"focus", label:"Focus"}` রাখুন।

`v.rolling(id, {windowMs:3600000, limitMs:600000})` একটি নামযুক্ত সক্রিয় ব্যবহার tracker তৈরি করে অথবা বিদ্যমানটি ফেরত দেয়। `assign({websites:["youtube.com","reddit.com"], apps:[]})` এই member-এর target assignment প্রতিস্থাপন করে। Native rule পরিবর্তে platform app ID দিতে পারে। Domain-এর মধ্যে subdomain-ও পড়ে। একটি tracker তার target-গুলোর ব্যবহার একত্র করে; অন্য ID-এর allowance স্বাধীন। `snapshot()` ফেরত দেয় `ready`, `error`, `usedMs`, `remainingMs`, `available` ও `nextReturnAtMs` (পরের যে millisecond-এ কোনো নথিভুক্ত ব্যবহারের মেয়াদ শেষ হবে)। Target দিলে `available(target?)` assignment-ও পরীক্ষা করে। `reset()` এই object-এর history মুছে দেয়।

Allowance-এর অতিরিক্ত ব্যবহারসহ পর্যবেক্ষিত সব যোগ্য ব্যবহার গণনা হয়; tracker নিজে page/app block করে না। একই সময়ের overlapping visible-page interval একবার গণনা হয়, আর native app-এ পর্যবেক্ষিত foreground ব্যবহার গণনা হয়। Disabled rule ব্যবহার যোগ করে না; তবে interval-এর সুনির্দিষ্ট সীমানায় history-এর মেয়াদ শেষ হতে থাকে। অবশিষ্ট history-এর ব্যবহার limit-এর নিচে নামলেই কেবল availability ফেরে। Heartbeat sample সর্বোচ্চ পাঁচ সেকেন্ডের; shutdown/disabled gap থেকে কৃত্রিম activity তৈরি হয় না। ব্যবহারকারীর emit করা event ব্যবহার যোগ করে না।

Linked custom group-এ একই object ID একটি স্থানীয় native hub-এর কর্তৃত্ব ভাগ করে। Linking tracker history ও assignment একত্র করে এবং যে পক্ষ linking শুরু করেছে তার timer state রাখে; অসামঞ্জস্যপূর্ণ configuration linking প্রত্যাখ্যান করে। প্রতিটি member নিজস্ব completion event পায়। Disconnect হলে নতুন authoritative তথ্য না ফেরা পর্যন্ত shared tracker unavailable হয় এবং timer control প্রত্যাখ্যাত হয়। Unlink-এ প্রতিটি member চূড়ান্ত shared usage ও timer state রাখে, নিজস্ব target ফেরত পায় এবং পুরোনো link-এর command বাদ দেয়। ফিরে আসা member চূড়ান্ত snapshot save করে acknowledgement না দেওয়া পর্যন্ত hub সেটি রাখে; নতুন link পাওয়ার আগে pending handover শেষ হয়।

নামযুক্ত object Run ও restart-এর পরেও সংরক্ষিত `v.state.$vaultTime`-এ থাকে; field-টি সরাসরি edit করবেন না। স্পষ্টভাবে সরাতে `v.removeTime(id)` ব্যবহার করুন। ID-তে 1–80টি ASCII অক্ষর, সংখ্যা, `_` বা `-` থাকতে পারে; সংরক্ষিত property name প্রত্যাখ্যাত হয়। সর্বোচ্চ 32টি object rule-এর 64KiB UTF-8 state limit ভাগ করে। Duration পূর্ণসংখ্যা millisecond, সর্বোচ্চ 365 দিন। Rolling history সর্বোচ্চ 1024টি minute bucket ও 2048টি merged interval রাখে। History capacity error হলে স্পষ্টভাবে reset না করা পর্যন্ত tracker unavailable থাকে; invalid configuration ও oversized save error জানায় কিন্তু saved data মুছে না।

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

- `on(type, handler)` → boolean। `handler(ev)` নিবন্ধন করে; একাধিক handler registration order-এ চলে। False মানে invalid argument বা handler limit। `ev = { type: string, now: number, origin: "host" | "user" | "rule", data }`; `now` Unix milliseconds। Native panel input-এ `origin: "user"`; `v.emit`-এ `origin: "rule"` থাকে।
- `v.state`: mutable JSON object, event dispatch-এর পরে সংরক্ষিত। পুরনো state না মুছে missing field initialize করুন। Object নয় বা array দিলে `{}` হয়; nonserializable/oversized update save হয় না।
- `v.log(...values)`: এই group-এর Log-এ যোগ করে। Execution ও delivery failure একই feed-এ স্পষ্ট error entry হিসেবে দেখা যায়। Log/Clear প্রতি group আলাদা। Load error Run status-এও দেখা যায়; আংশিকভাবে চালানো event স্বয়ংক্রিয়ভাবে আবার চালানো হয় না।
- `v.emit(type, data)`: বর্তমান event-এর পরে group handler-এ `data`-র JSON copy queue করে, নতুন `now`-সহ; synchronous call নয়।
- `v.panel(id, spec)`: group-এর named floating panel প্রতিস্থাপন করে; null `spec` সরায়। Panels দেখুন।
- `v.file(op, path, payload?)` → request ID string। Files দেখুন।
- `v.store(request)` → request ID string। Group records দেখুন।
- `v.block(appId, on)`: true app block বজায় রাখে, false এই group-এর block সরায়। Enabled group-এর block একত্র হয়; অন্য group-এর target unblock করা যায় না। Blocking স্বাভাবিক quit চায় এবং Settings interval-এ retry করে; process start ঠেকায় না, app Quit মানবে নিশ্চয়তা দেয় না।
- `v.quit(appId)`: একই protection/retry নীতিতে একবার normal quit; স্থায়ী block নয়।
- `v.open(appId)`: macOS-কে installed app খুলতে বলে; success callback নেই।

অন্য call `undefined` দেয়। App ID হলো bundle identifier (যেমন `com.valvesoftware.steam`), যা event-এ পাওয়া যায়। Block/Quit Apple app ও পুরো browser-কে target করতে পারে। এগুলো Mac Vault-এর bundle identifier ও তার helper, একই identity ব্যবহারকারী অন্য যেকোনো app, এবং ফাঁকা ID উপেক্ষা করে। Panel ID/state একটি group-এর, তার প্রদর্শিত নামের নয়।

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
record: { requestId: string, ok: boolean, op?: string, key?: string,
          record?: Record | null, entries?: Header[], next?: string | null,
          deleted?: number, error?: string }
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

## গ্রুপ রেকর্ড

`v.store(request)` handler-এর মধ্যে asynchronous JSON record operation শুরু করে। Record এই গ্রুপের ব্যক্তিগত, Run ও restart-এর পর থাকে এবং গ্রুপ মুছলে মুছে যায়; linked group-এর record আলাদা। Key, value, version, cache invalidation ও feedback precedence নিয়মই নির্ধারণ করে। Mac ও browser একই API ব্যবহার করলেও প্রতিটি app/browser store আলাদা।

| Request | Result |
|---|---|
| `{op:"get", key}` | `record` বা `null` |
| `{op:"put", key, value, version?, ifRevision?}` | সংরক্ষিত `record` |
| `{op:"delete", key, ifRevision?}` | `record: null` |
| `{op:"list", prefix?, after?, limit?}` | সাজানো `entries` ও `next` |
| `{op:"clear", prefix?}` | `deleted` সংখ্যা |

প্রতিটি record-এ `{value, revision, version, updatedAt}` থাকে। বাস্তব write হলে opaque revision বদলায়; `version` caller-এর metadata। `list` value ছাড়া header ফেরায়; একটি পড়তে `get`, পরের page-এ যেতে `after: next` ব্যবহার করুন। `put`/`delete`, `ifRevision` বাদ দিলে put/delete unconditional; `null` মানে key অনুপস্থিত হতে হবে, revision string হলে exact match চাই। Mismatch-এ `ok:false`, `error:"store-conflict"` ও বর্তমান `record` ফেরে—এটি delayed automatic reply-কে user feedback overwrite করা থেকে আটকায়। `v.context.revision` opaque rule-configuration marker; rule চাইলে নিজের version-এ রাখতে পারে। Framework cache policy নির্ধারণ করে না।

সীমা: key 1–2048 অক্ষর, version ≤128, JSON value ≤64KiB, depth ≤32, প্রতি group 10000 key, পুরো record document 16MiB। `list` প্রতি page-এ সর্বোচ্চ100 header ও96KiB দেয়। প্রতি group 32 এবং মোট প্রতি সেকেন্ডে 128 request start; overload-এ প্রতি group-এ প্রতি সেকেন্ডে একটি `store-busy` error, অতিরিক্ত request drop হয়। Storage error `ok:false`; future/malformed document সংরক্ষণ করে `store-unavailable` জানায়। Auto retry/eviction নেই; deadline-এর জন্য ticks ব্যবহার করুন।

## সীমা

প্রতি event/group: 256 queued action, 200 log call, 64 emit; অতিরিক্ত বাদ। প্রতি rule: 1000 handler, 24 panel; প্রতি control list-এ 32 entry এবং choice-এ 64 option; অতিরিক্ত ignore/truncate। Emit chain 16 generation-এ থামে। Serialized state limit 65536 UTF-8 byte। Registration ও প্রতি event-এর combined handler 1 সেকেন্ডের নিচে রাখুন; বারবার limit ছাড়ালে বা hard timeout হলে Run পর্যন্ত rule থামে। প্রতি group-এ Log 200 entry রাখে। Timing/reply best-effort, real-time guarantee নয়।

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

## চলমান নিয়ম থেকে AI কল

প্রতিটি custom group **AI calls**-এ একটি connection/model ও reasoning effort বেছে নেয়। Mac ও browser rule একই API ব্যবহার করে; browser request-এর জন্য Mac Vault connected থাকতে হবে, provider credential সেখানেই থাকে। Linked group নির্বাচন ও ঐচ্ছিক দৈনিক request cap ভাগ করে। ফাঁকা মানে group cap নেই; account limit থাকে। Cap UTC দিন ধরে, restart-এ স্থায়ী এবং ব্যর্থসহ submitted attempt গোনে। Link করলে আগের usage যোগ হয়; unlink করলেও আগের usage থাকে।

`v.ai({ prompt, input? })` সঙ্গে সঙ্গে request ID দেয়। Registration-এ নয়, handler-এর মধ্যে কল করুন। `input` যেকোনো JSON; prompt/input প্রত্যেকটি সর্বোচ্চ20KB। উত্তর `ai` event-এ আসে: `{requestId, ok, text, citations,
error}`। সফল text সর্বোচ্চ48KB; citation `{url,title}`। Web search-এর উত্তর দেখালে source link দৃশ্যমান ও clickable রাখুন। Model-এর জন্য search সর্বদা উপলভ্য। নির্দিষ্ট app deadline নেই; bounded concurrency থাকে; provider fallback বা auto retry নেই। উত্তর data, JavaScript হিসেবে execute হয় না; বিদ্যমান action নেবে কি না rule ঠিক করে।

`ask` বোতাম ও `note` field-সহ panel-এর জন্য:

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

Restart-এ outstanding call replay হয় না। Run, disable/enable বা delete পুরনো reply বাতিল করে; disconnected browser `ai-unavailable` দেয়। অন্য error: `ai-not-configured`, `ai-invalid-input`, `ai-busy`, `ai-daily-limit`, `ai-request-failed`, `ai-usage-storage-unavailable`। Failed call rule-এর আগের রাখা result বদলায় না; rule state-এর64KB সীমা আগের মতোই।

Credential-মুক্ত model পছন্দ Mac-এ `rule_ai_models`, browser-এ `settings-rule-ai-models` দিয়ে খুঁজুন; বর্তমান set-group path-এ `ruleAI` কনফিগার করুন। Field: `providerModel`, `accountID`, `reasoningEffort` (`default`, `low`, `medium`, `high`) এবং `dailyRequestLimit` (null বা1–100000)। ফেরত পাওয়া choice ব্যবহার করুন; rule source-এ key বা provider URL দেবেন না।
