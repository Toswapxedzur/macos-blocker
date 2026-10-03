# Mac Vault कोड मैनुअल

[उपयोगकर्ता मैनुअल](../manual/hi.md)

## नियम अनुबंध

Source: एक function expression `(on, v) => { ... }`। केवल synchronous JavaScript और नीचे API समर्थित है; timer, network, native system API या browser-page access नहीं। समय-आधारित नियम `ev.now` और events उपयोग करते हैं। Browser rules browser extension code manual उपयोग करते हैं।

- संपादन draft सहेजता है; **Run** नियम सक्रिय कर group सक्षम करता है। फ़्रीज़ group Run नहीं कर सकता। खाली source नियम unload करता है।
- सफल Run handlers/panels बदलता और इस group का app-block set साफ़ करता है, `v.state` बचाए रखता है। Compile/registration failure पिछला नियम रखता है; timeout रोक सकता है। Restart अंतिम activated source register करता है; closure variables और app-block sets reset होते हैं।
- Registration state initialize, handlers register, panels दिखा और log कर सकता है। App/file actions व emits handlers में रखें; registration का queue छोड़ दिया जाता है।
- Disable handlers रोकता और panels/app blocks हटाता है। Enable loaded rule और रखे panels/blocks फिर चलाता है। Delete handlers/state/effects हटाता है। पहले quit apps फिर नहीं खुलते; file writes वापस नहीं होते।
- Events सामान्य group targets से सीमित नहीं; नियम में apps चुनें। Actions queue होकर dispatch के बाद लागू होते हैं। Exception handler रोकता है पर state/actions rollback नहीं; आगे के handlers चल सकते हैं। केवल file actions result event देते हैं।

## API

- `on(type, handler)` → boolean। `handler(ev)` register करता है; कई handlers registration order में चलते हैं। False invalid arguments या handler limit बताता है। `ev = { type: string, now: number, data }`; `now` Unix milliseconds है।
- `v.state`: mutable JSON object, event dispatch के बाद सहेजा जाता है। पुराने state को मिटाने के बजाय missing fields initialize करें। Non-object/array देने पर `{}`; nonserializable/अत्यधिक बड़ा update सहेजा नहीं जाता।
- `v.log(...values)`: इस group के Log का एकमात्र स्रोत। Logs/Clear प्रति group स्वतंत्र। Load errors Run status में; handler diagnostics Log में नहीं।
- `v.emit(type, data)`: मौजूदा event के बाद group handlers के लिए `data` की JSON copy queue करता है, नए `now` के साथ; synchronous call नहीं।
- `v.panel(id, spec)`: group का नामित floating panel बदलता है; null `spec` हटाता है। Panels देखें।
- `v.file(op, path, payload?)` → request ID string। Files देखें।
- `v.block(appId, on)`: true app block बनाए रखता है, false इस group का block हटाता है। Enabled groups के blocks जुड़ते हैं; दूसरे group का target unblock नहीं करता। Blocking normal quit माँगता और Settings interval पर retry करता है; process launch नहीं रोकता या app के Quit स्वीकारने की गारंटी नहीं देता।
- `v.quit(appId)`: समान protection/retry नीति वाला एक सामान्य quit अनुरोध; निरंतर block नहीं।
- `v.open(appId)`: macOS से installed app खोलने को कहता है; success callback नहीं।

अन्य calls `undefined` लौटाते हैं। App IDs bundle identifiers हैं (जैसे `com.valvesoftware.steam`) और events में उपलब्ध हैं। Block/Quit `com.apple.*`, browsers, Vault/helpers और खाली IDs अनदेखा करते हैं। Panel IDs/state group के हैं, display name के नहीं।

## Events

नीचे payload notation type बताता है, executable code नहीं। `?` वैकल्पिक fields दर्शाता है।

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

- `tick` अनुमानित है; tick count नहीं, timestamps उपयोग करें। Running में foreground, menu-bar और background `.app` processes शामिल हैं जिनके bundle IDs हैं; सभी Unix processes नहीं। Frontmost null या खाली app ID हो सकता है।
- `app` उस tick के `tick` event से पहले देखे lifecycle changes बताता है। केवल focus में `previousAppId` है (अज्ञात पर null)। Names display names हैं, stable IDs नहीं।
- `snooze` का अर्थ group का Snooze button दबाया गया। यह स्वयं pause नहीं करता।
- File replies अनुरोध करने वाले group को मिलते हैं। `requestId` मिलाएँ, `ok` जाँचें और ticks से deadline तय करें: rule reload/disable होने पर replies खो सकते हैं। Run के बाद request IDs दोहर सकते हैं; pending requests स्थायी काम नहीं।

## Panels

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

## Files

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

## सीमाएँ

प्रति event/group: 256 queued actions, 200 log calls, 64 emits; अतिरिक्त drop होते हैं। प्रति rule: 1000 handlers, 24 panels; हर control list में 32 entries और हर choice में 64 options; अतिरिक्त ignore/truncate। Emit chains 16 generations पर रुकते हैं। Serialized state limit 65536 JavaScript string characters। Registration और हर event के संयुक्त handlers 1 second से कम रखें; बार-बार अधिक समय या hard timeout rule को Run तक रोकता है। Log प्रति group 200 entries रखता है। Timing/replies best-effort हैं, real-time guarantee नहीं।

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
