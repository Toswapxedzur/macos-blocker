# Mac Vault कोड मैनुअल

[उपयोगकर्ता मैनुअल](../manual/hi.md)

## नियम अनुबंध

स्रोत: एक function expression `(on, v) => { ... }`। केवल synchronous JavaScript और नीचे दिया API समर्थित है; JavaScript के scheduling callbacks, network, native system API या browser-page तक पहुँच नहीं है। समय-आधारित नियम नीचे दिए प्रबंधित timer/tracker या `ev.now` और events का उपयोग करते हैं। Safari नियम browser code manual का उपयोग करते हैं और Safari Vault के अपने containing app में चलते हैं।

- संपादन draft सहेजता है; **Run** नियम सक्रिय कर group सक्षम करता है। फ़्रीज़ group Run नहीं कर सकता। खाली source नियम unload करता है।
- सफल Run handlers/panels बदलता और इस group का app-block set साफ़ करता है, `v.state` बचाए रखता है। Compile/registration failure पिछला नियम रखता है; timeout रोक सकता है। Restart अंतिम activated source register करता है; closure variables और app-block sets reset होते हैं।
- Registration state initialize, handlers register, panels दिखा और log कर सकता है। App/file actions व emits handlers में रखें; registration का queue छोड़ दिया जाता है।
- Disable handlers रोकता और panels/app blocks हटाता है। Enable loaded rule और रखे panels/blocks फिर चलाता है। Delete handlers/state/effects हटाता है। पहले quit apps फिर नहीं खुलते; file writes वापस नहीं होते।
- Events सामान्य group targets से सीमित नहीं; नियम में apps चुनें। Actions queue होकर dispatch के बाद लागू होते हैं। Exception handler रोकता है पर state/actions rollback नहीं; आगे के handlers चल सकते हैं। केवल file actions result event देते हैं।

## प्रबंधित टाइमर और चलती समय-सीमा का उपयोग

`v.timer(id, {direction:"down", durationMs:300000})` एक नामित countdown बनाता है या मौजूदा countdown लौटाता है, जो शुरुआत में paused होता है। Count-up timer के लिए `{direction:"up"}` इस्तेमाल करें। Handle में `start()`, `pause()`, `resume()`, `reset()` और `snapshot()` हैं। Start/resume को बार-बार बुलाने से अतिरिक्त असर नहीं होता; reset समय को शून्य elapsed वाली paused स्थिति में लौटाता है। Snapshot fields में `ready`, `error`, `elapsedMs`, `remainingMs` (count-up के लिए null), `running` और `completed` शामिल हैं।

चलते timer app/browser बंद होने या rule disabled होने पर भी घड़ी के वास्तविक समय के अनुसार आगे बढ़ते हैं। पूरा हुआ countdown हर timer incarnation और generation के लिए हर member का rule अगली बार चलने पर एक बार `timerEnded` के साथ `{id, direction, durationMs, generation, incarnation}` देता है; Run इसे फिर नहीं देता। Delivery host events पर निर्भर है; यह real-time alarm नहीं है। मौजूदा text control से दिखाने के लिए panel में `{type:"timer", timerId:"focus", label:"Focus"}` रखें।

`v.rolling(id, {windowMs:3600000, limitMs:600000})` एक नामित सक्रिय उपयोग tracker बनाता है या मौजूदा tracker लौटाता है। `assign({websites:["youtube.com","reddit.com"], apps:[]})` इस member के target assignments बदल देता है। Native rules इसके बदले platform app IDs दे सकते हैं। Domains में subdomains भी शामिल हैं। एक tracker अपने सभी targets का उपयोग मिलाकर गिनता है; अन्य IDs की allowance स्वतंत्र होती है। `snapshot()` से `ready`, `error`, `usedMs`, `remainingMs`, `available` और `nextReturnAtMs` (अगला millisecond जब कोई दर्ज उपयोग expire होगा) मिलते हैं। Target दिए जाने पर `available(target?)` assignment भी जाँचता है। `reset()` इस object का history मिटाता है।

Allowance से अधिक उपयोग समेत सभी देखे गए पात्र उपयोग गिने जाते हैं; tracker स्वयं page/app block नहीं करता। दिखाई दे रहे pages के overlapping intervals एक बार गिने जाते हैं और native apps में देखा गया foreground उपयोग गिना जाता है। Disabled rules नया उपयोग नहीं जोड़ते; history फिर भी interval की सटीक सीमाओं पर expire होता रहता है। Availability तभी लौटती है जब बची हुई history का उपयोग limit से नीचे हो। Heartbeat samples अधिकतम पाँच सेकंड के होते हैं; shutdown/disabled gaps से काल्पनिक activity नहीं बनती। उपयोगकर्ता के emit किए events उपयोग नहीं जोड़ते।

Linked custom groups में समान object IDs एक स्थानीय native hub के नियंत्रण को साझा करते हैं। Linking tracker history और assignments मिलाता है और linking शुरू करने वाले timer की state रखता है; असंगत configurations linking अस्वीकार करते हैं। हर member को अपना completion event मिलता है। Disconnect होने पर fresh authoritative जानकारी लौटने तक shared trackers unavailable होते हैं और timer controls अस्वीकार होते हैं। Unlink पर हर member अंतिम shared usage और timer state रखता है, अपने targets वापस पाता है और पुराने link के commands छोड़ देता है। लौटने वाला member अंतिम snapshot save करके acknowledgement देने तक hub उसे रखता है; नया link उपलब्ध होने से पहले pending handovers पूरे होते हैं।

नामित objects Run और restart के बाद भी आरक्षित `v.state.$vaultTime` में रहते हैं; उस field को सीधे edit न करें। साफ़ तौर पर हटाने के लिए `v.removeTime(id)` इस्तेमाल करें। IDs में 1–80 ASCII अक्षर, अंक, `_` या `-` हो सकते हैं; आरक्षित property names अस्वीकार होते हैं। अधिकतम 32 objects rule की 64KiB UTF-8 state limit साझा करते हैं। Duration पूर्णांक millisecond में, अधिकतम 365 दिन है। Rolling history में अधिकतम 1024 minute buckets और 2048 merged intervals होते हैं। History capacity errors tracker को स्पष्ट reset तक unavailable रखते हैं; invalid configurations और oversized saves त्रुटियाँ बताते हैं, saved data मिटाते नहीं हैं।

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

- `on(type, handler)` → boolean। `handler(ev)` register करता है; कई handlers registration order में चलते हैं। False invalid arguments या handler limit बताता है। `ev = { type: string, now: number, data }`; `now` Unix milliseconds है।
- `v.state`: mutable JSON object, event dispatch के बाद सहेजा जाता है। पुराने state को मिटाने के बजाय missing fields initialize करें। Non-object/array देने पर `{}`; nonserializable/अत्यधिक बड़ा update सहेजा नहीं जाता।
- `v.log(...values)`: इस group के Log में जोड़ता है। Execution और delivery failures इसी feed में स्पष्ट error entries के रूप में दिखते हैं। Logs/Clear हर group के लिए अलग हैं। Load errors Run status में भी दिखते हैं; आंशिक रूप से चले events अपने आप दोबारा नहीं चलते।
- `v.emit(type, data)`: मौजूदा event के बाद group handlers के लिए `data` की JSON copy queue करता है, नए `now` के साथ; synchronous call नहीं।
- `v.panel(id, spec)`: group का नामित floating panel बदलता है; null `spec` हटाता है। Panels देखें।
- `v.file(op, path, payload?)` → request ID string। Files देखें।
- `v.block(appId, on)`: true app block बनाए रखता है, false इस group का block हटाता है। Enabled groups के blocks जुड़ते हैं; दूसरे group का target unblock नहीं करता। Blocking normal quit माँगता और Settings interval पर retry करता है; process launch नहीं रोकता या app के Quit स्वीकारने की गारंटी नहीं देता।
- `v.quit(appId)`: समान protection/retry नीति वाला एक सामान्य quit अनुरोध; निरंतर block नहीं।
- `v.open(appId)`: macOS से installed app खोलने को कहता है; success callback नहीं।

अन्य calls `undefined` लौटाती हैं। App IDs bundle identifiers हैं (जैसे `com.valvesoftware.steam`), जो events में मिलते हैं। Block/Quit Apple apps और पूरे browsers को target कर सकते हैं। वे Mac Vault के bundle identifier और उसके helpers, उसी identity वाले किसी भी अन्य app, और खाली IDs को अनदेखा करते हैं। Panel IDs/state एक group के हैं, उसके display name के नहीं।

## इवेंट

नीचे payload notation type बताता है, executable code नहीं। `?` वैकल्पिक fields दर्शाता है।

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

- `tick` अनुमानित है; tick count नहीं, timestamps उपयोग करें। Running में foreground, menu-bar और background `.app` processes शामिल हैं जिनके bundle IDs हैं; सभी Unix processes नहीं। Frontmost null या खाली app ID हो सकता है।
- `app` उस tick के `tick` event से पहले देखे lifecycle changes बताता है। केवल focus में `previousAppId` है (अज्ञात पर null)। Names display names हैं, stable IDs नहीं।
- `snooze` का अर्थ group का Snooze button दबाया गया। यह स्वयं pause नहीं करता।
- File replies अनुरोध करने वाले group को मिलते हैं। `requestId` मिलाएँ, `ok` जाँचें और ticks से deadline तय करें: rule reload/disable होने पर replies खो सकते हैं। Run के बाद request IDs दोहर सकते हैं; pending requests स्थायी काम नहीं।

## पैनल

```text
spec = { title?: string, description?: string, controls?: Control[],
         position?: "top-left" | "top-right" | "bottom-left" | "bottom-right" | "center",
         width?: "small" | "medium" | "large" | number }
Control = { id?: string, type?: string, label?: string, value?, disabled?: boolean,
            ...type-specific fields below }
```

Defaults: bottom-right position, width 300px; small/medium/large presets 220/280/360px; numeric width 180–520px तक सीमित और pixel strings स्वीकारता है। Native panels/sections controls को vertical stack करते हैं; browser layout, alignment, role, autofocus और control-dimension fields native renderer को प्रभावित नहीं करते।

IDs ASCII letters/digits/`_`/`-` में normalize (max 80); unique stable ID चुनें। Omitted control ID `control-N`; omitted/unknown type text बनता है। Omitted text/lists खाली; disabled false। हर call पूरी spec बदलता है। Explicit `value` stored input को override करता है; omitted value पिछली event value लेकर type normalization करता है। Native events strings देते हैं: updated panel render करने से पहले declared value type में parse करें। Unknown fields discard; panel colors/fonts/CSS Vault के हैं।

Control fields और initial values:

- `text`: `text` string; default label। `html`: `html` string, sanitize होकर Mac पर plain text दिखता है।
- `button`: `label`, optional `action: "submit" | "cancel" | "close"`। Click value action string या खाली। Actions स्वतः submit/close नहीं करते।
- `checkbox`, `toggle`: boolean `value` (default false); event value `"true"`/`"false"`।
- `select`, `radio`: `options: (string | { value: string, label?: string })[]`; string value (default खाली)। Empty option value हटती है; label default value। Selection के बाद panel का typed value update करें।
- `textInput`, `textarea`: string value (default खाली); textInput `placeholder`; textarea `rows` 1–12 (default 3)। Native textarea placeholder अनदेखा करता है।
- `numberInput`, `range`: numeric value (default 0), `min`, `max`, positive `step`। Panel update में values सीमा तक clamp; unspecified normalization −1000000…1000000। Native numberInput text entry है: `Number(event.value)` स्वयं validate करें; min/max/step typing सीमित नहीं करते। Native range default 0…100, step 1।
- `date`, `time`: text entry; initial format `YYYY-MM-DD`, `HH:MM`/`HH:MM:SS` (invalid format खाली)। Edits स्वयं validate करें। `color`: `#RRGGBB` (default `#000000`)।
- `pin`: digit string; `length` 3–12 (default 6), `masked` default true, `autoSubmit` false। `section`: `text`, `controls`; depth 3 child section के बच्चे नहीं (root control depth 0)।

Panel events: सामान्य input `change`; buttons केवल `click`; PIN `change` और autoSubmit पूरा होने पर `submit` भेजता है। Native mount/unmount/focus/key events नहीं। Numbers/booleans सहित values strings हैं। `values` rendered snapshot के input values रखता है और triggering edit से पीछे हो सकता है; `value` उस edit की पहचान करता है। विश्वसनीय forms के लिए इसे `v.state` में सहेजकर typed values render करें। Non-click events प्रति control 100ms में coalesce होते हैं; events को keystrokes न गिनें।

Text limit: title/label 240; description/text 1000; HTML 20000; placeholder 500; input text 2000; अन्य value strings 512; option value/label 256। अतिरिक्त truncate होता है।

## फ़ाइलें

`op`: `"read"`, `"write"`, `"append"`, `"list"`, `"exists"`। Settings में **Custom-rule folder** और उसकी permission चाहिए।

- `path` relative; `/` directories अलग करता है। Segments ASCII letters/digits, spaces और `_.,@()-` स्वीकारते हैं; leading dot, `.`/`..`, absolute path या URL नहीं। File suffix `.txt`, `.csv`, `.json` (case-insensitive)। List path directory है; `""` चुना root दिखाता है। चुने folder से बाहर जाते paths, symlink सहित, अस्वीकार होते हैं।
- Read UTF-8 text लौटाता है। Write replace/create; append बिना automatic newline के create/append करता है। Write पर parent directories बनती हैं। String payload ज्यों का त्यों लिखा जाता है; अन्य JSON payload serialize होते हैं; null/omitted का अर्थ खाली text। JSON/CSV parsing rule का काम। Max file size 1048576 UTF-8 bytes।
- List तुरंत दिखने वाली subdirectories और supported files लौटाता है। Entries: `{ name: string, path: string, kind: "directory" | "file", extension?: string }`; files में extension के साथ dot है। Exists supported file path के लिए boolean लौटाता है।

```text
file.data = { requestId: string, op: string, path: string, ok: boolean,
              text: string | null, entries: Entry[] | null,
              exists: boolean | null, error: string }
```

Unused result fields null; success में error खाली। Failures: invalid-path, unsupported-file-type, folder unavailable, missing file, file-too-large। error string है, कोई fixed exhaustive enum नहीं। Transaction API नहीं; प्रति path read-modify-write serialize करें।

## समूह रिकॉर्ड

`v.store(request)` handler के अंदर asynchronous JSON record operation शुरू करता है। Record group के निजी होते हैं, Run/restart के बाद बने रहते हैं और group हटाने पर हटते हैं। Linked groups का store अलग है। Keys, values, version, cache invalidation और feedback precedence rule चुनता है। Mac और browser rules वही API उपयोग करते हैं, पर हर app/browser store अलग है।

| Request | Result |
|---|---|
| `{op:"get", key}` | `record` या `null` |
| `{op:"put", key, value, version?, ifRevision?}` | saved `record` |
| `{op:"delete", key, ifRevision?}` | `record: null` |
| `{op:"list", prefix?, after?, limit?}` | sorted `entries` और `next` |
| `{op:"clear", prefix?}` | `deleted` count |

Record `{value, revision, version, updatedAt}` होता है। वास्तविक write पर opaque `revision` बदलता है; `version` caller metadata है। `list` बिना values के headers लौटाता है; एक record पढ़ने को `get`, अगले page के लिए `after: next` उपयोग करें। `ifRevision` के बिना put/delete unconditional है; `null` के लिए key अनुपस्थित होनी चाहिए, revision string के लिए exact match। Mismatch में `ok:false`, `error:"store-conflict"` और current `record` लौटते हैं। इससे देर से आया automatic reply user feedback को overwrite नहीं करता। `v.context.revision` opaque rule-configuration marker है, जिसे rule अपने version में शामिल कर सकता है; framework cache नीति नहीं लगाता।

सीमाएं: key 1–2048 अक्षर, version ≤128, JSON value ≤64KiB, depth ≤32, प्रति group 10000 keys और पूरे record document की सीमा16MiB। `list` प्रत्येक page में अधिकतम100 headers और96KiB देता है। प्रति group 32 requests और कुल128 request starts/second; overload में प्रति group/second एक `store-busy` error आता है और बाकी requests drop होते हैं। Storage errors में `ok:false`; future/malformed document सुरक्षित रहता है और `store-unavailable` मिलता है। Auto retry/eviction नहीं। Deadline के लिए ticks उपयोग करें।

## सीमाएँ

प्रति event/group: 256 queued actions, 200 log calls, 64 emits; अतिरिक्त drop होते हैं। प्रति rule: 1000 handlers, 24 panels; हर control list में 32 entries और हर choice में 64 options; अतिरिक्त ignore/truncate। Emit chains 16 generations पर रुकते हैं। Serialized state limit 65536 UTF-8 bytes। Registration और हर event के संयुक्त handlers 1 second से कम रखें; बार-बार अधिक समय या hard timeout rule को Run तक रोकता है। Log प्रति group 200 entries रखता है। Timing/replies best-effort हैं, real-time guarantee नहीं।

## पूरा नियम

Snooze या उसके panel button से शुरू पाँच मिनट के pause को छोड़कर Steam blocked है:

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

## चलते नियम से AI कॉल

हर custom group **AI calls** में एक connection/model और reasoning effort चुनता है। Mac/browser rules वही API इस्तेमाल करते हैं; browser request के लिए Mac Vault connected होना चाहिए और provider credentials वहीं रहते हैं। Linked groups चयन और optional daily request cap साझा करते हैं। Blank का अर्थ group cap नहीं, account limits फिर भी लागू। Cap UTC day से जुड़ा है, restart के बाद रहता है और failures सहित submitted attempts गिनता है। Link पुराने usage को जोड़ता है; unlink पुराना usage रखता है।

`v.ai({ prompt, input? })` तुरंत request ID देता है। इसे handler के भीतर call करें, rule register करते समय नहीं। `input` कोई JSON value हो सकता है; prompt/input प्रत्येक अधिकतम20KB। Reply `ai` events में आता है: `{requestId, ok, text, citations, error}`। सफल text अधिकतम48KB; citation `{url,title}`। Web search आधारित उत्तर दिखाते समय source links दिखने योग्य और clickable रखें। Search model के लिए हमेशा उपलब्ध है। निश्चित app deadline नहीं, concurrency bounded है; provider fallback/automatic retry नहीं। Response data है, JavaScript के रूप में execute नहीं; कौन-सी existing action लेनी है rule तय करता है।

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

Outstanding calls restart के बाद replay नहीं होते। Run, disable/re-enable और delete पुराने replies discard करते हैं; disconnected browser `ai-unavailable` देता है। अन्य errors: `ai-not-configured`, `ai-invalid-input`, `ai-busy`, `ai-daily-limit`, `ai-request-failed`, `ai-usage-storage-unavailable`। Failed calls rule द्वारा रखे पिछले result को नहीं बदलते। Rule state की सीमा64KB ही है।

Credential-free choices Mac पर `rule_ai_models` या browser पर `settings-rule-ai-models` से खोजें; मौजूदा set-group path के जरिए `ruleAI` configure करें। Fields: `providerModel`, `accountID`, `reasoningEffort` (`default`, `low`, `medium`, `high`) और `dailyRequestLimit` (null या1–100000)। लौटाया choice उपयोग करें; rule source में key/provider URL न डालें।
