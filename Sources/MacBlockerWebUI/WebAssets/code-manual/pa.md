# Mac Vault ਕੋਡ ਮੈਨੂਅਲ

[ਵਰਤੋਂਕਾਰ ਮੈਨੂਅਲ](../manual/pa.md)

## ਨਿਯਮ ਕਰਾਰ

ਸਰੋਤ: ਇੱਕ function expression `(on, v) => { ... }`। ਸਿਰਫ਼ synchronous JavaScript ਅਤੇ ਹੇਠਾਂ ਦਿੱਤੀ API ਸਮਰਥਿਤ ਹੈ; timers, network, native system APIs ਜਾਂ browser-page access ਨਹੀਂ। ਸਮੇਂ-ਆਧਾਰਿਤ ਨਿਯਮ `ev.now` ਅਤੇ events ਵਰਤਦੇ ਹਨ। Safari ਨਿਯਮਾਂ ਲਈ browser code manual ਵੇਖੋ; ਇਹ Safari Vault ਦੇ ਆਪਣੇ container app ਵਿੱਚ ਚੱਲਦੇ ਹਨ।

- ਸੰਪਾਦਨ draft ਸੰਭਾਲਦਾ ਹੈ; **ਚਲਾਓ** ਇਸਨੂੰ ਸਰਗਰਮ ਕਰਦਾ ਅਤੇ group ਨੂੰ ਸਮਰੱਥ ਬਣਾਉਂਦਾ ਹੈ। Freeze ਕੀਤੇ group ਨੂੰ ਚਲਾਇਆ ਨਹੀਂ ਜਾ ਸਕਦਾ। ਖਾਲੀ source ਨਿਯਮ ਨੂੰ unload ਕਰਦਾ ਹੈ।
- ਸਫਲ Run handlers/panels ਬਦਲਦਾ ਅਤੇ ਇਸ group ਦਾ app-block set ਸਾਫ਼ ਕਰਦਾ ਹੈ; `v.state` ਬਰਕਰਾਰ ਰਹਿੰਦੀ ਹੈ। Compilation/registration ਅਸਫਲ ਹੋਣ 'ਤੇ ਪਿਛਲਾ ਨਿਯਮ ਰੱਖਿਆ ਜਾਂਦਾ ਹੈ; timeout ਇਸਨੂੰ ਰੋਕ ਸਕਦਾ ਹੈ। Restart ਆਖ਼ਰੀ ਸਰਗਰਮ source ਮੁੜ register ਕਰਦਾ ਹੈ; closure variables ਅਤੇ app-block sets reset ਹੁੰਦੇ ਹਨ।
- Registration state ਸ਼ੁਰੂ ਕਰ ਸਕਦੀ ਹੈ, handlers register ਕਰ ਸਕਦੀ ਹੈ, panels ਦਿਖਾ ਸਕਦੀ ਹੈ ਅਤੇ log ਕਰ ਸਕਦੀ ਹੈ। App/file ਕਾਰਵਾਈਆਂ ਅਤੇ emits handlers ਵਿੱਚ ਹੋਣੀਆਂ ਚਾਹੀਦੀਆਂ ਹਨ; registration ਵੇਲੇ queue ਕੀਤੀਆਂ ਕਾਰਵਾਈਆਂ ਰੱਦ ਹੋ ਜਾਂਦੀਆਂ ਹਨ।
- Disable handlers ਨੂੰ ਰੋਕਦਾ ਅਤੇ panels/app blocks ਹਟਾਉਂਦਾ ਹੈ। Enable loaded rule ਅਤੇ ਇਸ ਦੇ ਬਚੇ panels/blocks ਮੁੜ ਚਲਾਉਂਦਾ ਹੈ। Delete ਇਸ ਦੇ handlers/state/effects ਹਟਾਉਂਦਾ ਹੈ। ਪਹਿਲਾਂ quit ਕੀਤੀਆਂ apps ਮੁੜ ਨਹੀਂ ਖੁੱਲ੍ਹਦੀਆਂ; file writes ਵਾਪਸ ਨਹੀਂ ਹੁੰਦੀਆਂ।
- Events ਆਮ group targets ਤੱਕ ਸੀਮਿਤ ਨਹੀਂ; apps ਨਿਯਮ ਵਿੱਚ ਚੁਣੋ। ਕਾਰਵਾਈਆਂ queue ਹੁੰਦੀਆਂ ਹਨ ਅਤੇ dispatch ਮਗਰੋਂ ਲਾਗੂ ਹੁੰਦੀਆਂ ਹਨ। Exceptions ਉਸ handler ਨੂੰ ਰੋਕਦੀਆਂ ਹਨ ਪਰ ਇਸ ਦੀ state/actions ਵਾਪਸ ਨਹੀਂ ਕਰਦੀਆਂ; ਅਗਲੇ handlers ਫਿਰ ਵੀ ਚੱਲ ਸਕਦੇ ਹਨ। ਸਿਰਫ਼ file actions ਦੇ result events ਹੁੰਦੇ ਹਨ।

## API

- `on(type, handler)` → boolean। `handler(ev)` register ਕਰਦਾ ਹੈ; ਕਈ handlers registration ਕ੍ਰਮ ਵਿੱਚ ਚੱਲਦੇ ਹਨ। False ਦਾ ਅਰਥ ਗਲਤ arguments ਜਾਂ handler limit ਪੂਰੀ ਹੋਈ। `ev = { type: string, now: number, data }`; `now` Unix milliseconds ਹੈ।
- `v.state`: ਬਦਲਣਯੋਗ JSON object, ਜੋ event dispatch ਮਗਰੋਂ ਸੰਭਾਲਿਆ ਜਾਂਦਾ ਹੈ। ਮੌਜੂਦਾ state ਮਿਟਾਉਣ ਦੀ ਥਾਂ ਗੁੰਮ fields ਸ਼ੁਰੂ ਕਰੋ। Non-object ਜਾਂ array ਦੇਣ ਨਾਲ ਇਹ `{}` ਬਣ ਜਾਂਦੀ ਹੈ; serialize ਨਾ ਹੋ ਸਕਣ ਵਾਲੇ ਜਾਂ ਬਹੁਤ ਵੱਡੇ updates ਸੰਭਾਲੇ ਨਹੀਂ ਜਾਂਦੇ।
- `v.log(...values)`: ਇਸ group ਦੇ Log ਵਿੱਚ ਲਿਖਣ ਦਾ ਇਕੱਲਾ ਤਰੀਕਾ। Logs/Clear ਹਰ group ਲਈ ਵੱਖਰੇ ਹਨ। Load errors Run status ਵਿੱਚ ਦਿਖਦੇ ਹਨ; handler diagnostics Log ਵਿੱਚ ਨਹੀਂ ਜਾਂਦੇ।
- `v.emit(type, data)`: `data` ਦੀ JSON copy ਮੌਜੂਦਾ event ਮਗਰੋਂ ਇਸ group ਦੇ handlers ਲਈ queue ਕਰਦਾ ਹੈ, ਨਵੇਂ `now` ਨਾਲ; ਇਹ synchronous call ਨਹੀਂ।
- `v.panel(id, spec)`: ਇਸ group ਦਾ ਨਾਮਿਤ floating panel ਬਦਲਦਾ ਹੈ; null `spec` ਇਸਨੂੰ ਹਟਾਉਂਦਾ ਹੈ। Panels ਵੇਖੋ।
- `v.file(op, path, payload?)` → request ID string। Files ਵੇਖੋ।
- `v.block(appId, on)`: true app block ਕਾਇਮ ਰੱਖਦਾ ਹੈ; false ਇਸ group ਦਾ block ਹਟਾਉਂਦਾ ਹੈ। ਸਮਰੱਥ groups ਦੇ blocks ਇਕੱਠੇ ਲਾਗੂ ਹੁੰਦੇ ਹਨ; ਇਹ call ਹੋਰ group ਦਾ target unblock ਨਹੀਂ ਕਰ ਸਕਦੀ। Blocking ਆਮ quit ਮੰਗਦੀ ਹੈ ਅਤੇ Settings ਦੇ interval 'ਤੇ ਮੁੜ ਕੋਸ਼ਿਸ਼ ਕਰਦੀ ਹੈ; ਇਹ process launch ਨਹੀਂ ਰੋਕਦੀ ਅਤੇ app ਵੱਲੋਂ Quit ਮੰਨਣ ਦੀ ਗਾਰੰਟੀ ਨਹੀਂ।
- `v.quit(appId)`: ਇੱਕ ਆਮ quit ਬੇਨਤੀ, ਉਸੇ protection/retry ਨੀਤੀ ਹੇਠ; ਲਗਾਤਾਰ block ਨਹੀਂ।
- `v.open(appId)`: macOS ਨੂੰ installed app ਖੋਲ੍ਹਣ ਲਈ ਕਹਿੰਦਾ ਹੈ; ਸਫਲਤਾ callback ਨਹੀਂ।

ਹੋਰ calls `undefined` ਵਾਪਸ ਕਰਦੀਆਂ ਹਨ। App IDs bundle identifiers ਹਨ (ਮਿਸਾਲ ਲਈ `com.valvesoftware.steam`) ਅਤੇ events ਵਿੱਚ ਉਪਲਬਧ ਹਨ। Block/Quit `com.apple.*`, browsers, Vault ਅਤੇ ਇਸ ਦੇ helpers, ਅਤੇ ਖਾਲੀ IDs ਨੂੰ ਅਣਡਿੱਠਾ ਕਰਦੇ ਹਨ। Panel IDs/state ਇੱਕ group ਨਾਲ ਜੁੜੇ ਹਨ, ਇਸ ਦੇ display name ਨਾਲ ਨਹੀਂ।

## Events

ਹੇਠਲੀ payload notation types ਦੱਸਦੀ ਹੈ, ਚੱਲਣਯੋਗ code ਨਹੀਂ। `?` optional fields ਦਰਸਾਉਂਦਾ ਹੈ।

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

- `tick` ਅੰਦਾਜ਼ਨ ਹੈ; tick ਗਿਣਨ ਦੀ ਥਾਂ timestamps ਵਰਤੋ। ਚੱਲ ਰਹੀਆਂ apps ਵਿੱਚ foreground, menu-bar ਅਤੇ background `.app` processes ਸ਼ਾਮਲ ਹਨ ਜਿਨ੍ਹਾਂ ਦੇ bundle IDs ਹਨ; ਹਰ Unix process ਨਹੀਂ। Frontmost null ਹੋ ਸਕਦਾ ਹੈ ਜਾਂ ਇਸ ਦਾ app ID ਖਾਲੀ ਹੋ ਸਕਦਾ ਹੈ।
- `app` ਵੇਖੀਆਂ lifecycle ਤਬਦੀਲੀਆਂ ਉਸ tick ਦੇ `tick` event ਤੋਂ ਪਹਿਲਾਂ ਦੱਸਦਾ ਹੈ। ਸਿਰਫ਼ focus ਵਿੱਚ `previousAppId` ਹੁੰਦਾ ਹੈ (ਅਣਜਾਣ ਹੋਵੇ ਤਾਂ null)। Names display names ਹਨ, ਸਥਿਰ IDs ਨਹੀਂ।
- `snooze` ਦਾ ਮਤਲਬ group ਦਾ Snooze button ਦਬਾਇਆ ਗਿਆ। ਇਹ ਆਪਣੇ ਆਪ ਕੋਈ pause ਲਾਗੂ ਨਹੀਂ ਕਰਦਾ।
- File replies ਬੇਨਤੀ ਕਰਨ ਵਾਲੇ group ਨੂੰ ਜਾਂਦੇ ਹਨ। `requestId` ਨਾਲ ਮਿਲਾਓ, `ok` ਜਾਂਚੋ ਅਤੇ ticks ਨਾਲ deadline ਰੱਖੋ: rule reload/disable ਹੋਣ 'ਤੇ replies ਗੁੰਮ ਹੋ ਸਕਦੇ ਹਨ। Run ਮਗਰੋਂ request IDs ਦੁਹਰਾਏ ਜਾ ਸਕਦੇ ਹਨ; pending requests ਟਿਕਾਊ ਕੰਮ ਨਹੀਂ ਹਨ।

## Panels

```text
spec = { title?: string, description?: string, controls?: Control[],
         position?: "top-left" | "top-right" | "bottom-left" | "bottom-right" | "center",
         width?: "small" | "medium" | "large" | number }
Control = { id?: string, type?: string, label?: string, value?, disabled?: boolean,
            ...type-specific fields below }
```

ਡਿਫਾਲਟ: ਹੇਠਾਂ-ਸੱਜੇ ਸਥਾਨ, ਚੌੜਾਈ 300px; small/medium/large presets 220/280/360px ਹਨ; numeric ਚੌੜਾਈ 180–520px ਤੱਕ ਸੀਮਿਤ ਹੁੰਦੀ ਹੈ ਅਤੇ pixel strings ਮਨਜ਼ੂਰ ਕਰਦੀ ਹੈ। Native panels/sections controls ਨੂੰ ਲੰਬਵਾਰ ਰੱਖਦੇ ਹਨ; browser layout, alignment, role, autofocus ਅਤੇ control-dimension fields native renderer 'ਤੇ ਅਸਰ ਨਹੀਂ ਕਰਦੇ।

IDs ASCII ਅੱਖਰਾਂ/ਅੰਕਾਂ/`_`/`-` ਤੱਕ ਸੀਮਿਤ ਹੁੰਦੇ ਹਨ (ਵੱਧ ਤੋਂ ਵੱਧ 80); ਵਿਲੱਖਣ ਸਥਿਰ IDs ਚੁਣੋ। Control ID ਨਾ ਦਿੱਤੀ ਹੋਵੇ ਤਾਂ `control-N` ਬਣਦਾ ਹੈ; ਗੁੰਮ/ਅਣਜਾਣ type text ਬਣਦਾ ਹੈ। ਨਾ ਦਿੱਤਾ text/lists ਖਾਲੀ ਹੁੰਦਾ ਹੈ; disabled false ਹੁੰਦਾ ਹੈ। ਹਰ call ਪੂਰਾ spec ਬਦਲਦੀ ਹੈ। ਦਿੱਤਾ `value` ਸੰਭਾਲੇ input ਨੂੰ ਤਰਜੀਹ ਦਿੰਦਾ ਹੈ; ਨਾ ਹੋਵੇ ਤਾਂ ਆਖ਼ਰੀ event value ਅਤੇ ਫਿਰ type normalization ਵਰਤਦਾ ਹੈ। Native events strings ਦਿੰਦੇ ਹਨ: ਨਵਾਂ panel render ਕਰਨ ਤੋਂ ਪਹਿਲਾਂ ਉਹਨਾਂ ਨੂੰ ਨਿਰਧਾਰਤ value type ਵਿੱਚ parse ਕਰੋ। ਅਣਜਾਣ fields ਹਟਾ ਦਿੱਤੇ ਜਾਂਦੇ ਹਨ; panel colors/fonts/CSS Vault ਦੇ ਹਨ।

Control fields ਅਤੇ ਸ਼ੁਰੂਆਤੀ values:

- `text`: `text` string; ਡਿਫਾਲਟ label। `html`: `html` string, sanitize ਕਰਕੇ Mac ਉੱਤੇ ਸਧਾਰਨ text ਵਜੋਂ ਦਿਖਾਈ ਜਾਂਦੀ ਹੈ।
- `button`: `label`, ਚੋਣਵਾਂ `action: "submit" | "cancel" | "close"`। Click value action string ਜਾਂ ਖਾਲੀ ਹੁੰਦੀ ਹੈ। Actions ਆਪਣੇ ਆਪ ਕੁਝ submit/close ਨਹੀਂ ਕਰਦੀਆਂ।
- `checkbox`, `toggle`: boolean `value` (ਡਿਫਾਲਟ false); event value `"true"`/`"false"` ਹੁੰਦੀ ਹੈ।
- `select`, `radio`: `options: (string | { value: string, label?: string })[]`; string value (ਡਿਫਾਲਟ ਖਾਲੀ)। ਖਾਲੀ option values ਹਟਾਏ ਜਾਂਦੇ ਹਨ; labels ਡਿਫਾਲਟ value ਹੁੰਦੇ ਹਨ। ਚੋਣ ਮਗਰੋਂ panel ਦੀ typed value ਅਪਡੇਟ ਕਰੋ।
- `textInput`, `textarea`: string value (ਡਿਫਾਲਟ ਖਾਲੀ); textInput `placeholder`; textarea `rows` 1–12 (ਡਿਫਾਲਟ 3)। Native textarea placeholder ਅਣਡਿੱਠਾ ਕਰਦੀ ਹੈ।
- `numberInput`, `range`: numeric value (ਡਿਫਾਲਟ 0), `min`, `max`, positive `step`। Panel updates ਦੌਰਾਨ values ਹੱਦਾਂ ਵਿੱਚ ਰੱਖੀਆਂ ਜਾਂਦੀਆਂ ਹਨ; ਨਿਰਧਾਰਤ ਨਾ ਕੀਤੀਆਂ normalization ਹੱਦਾਂ −1000000…1000000 ਹਨ। Native numberInput text entry ਹੈ: `Number(event.value)` ਖੁਦ validate ਕਰੋ; min/max/step typing ਨੂੰ ਸੀਮਿਤ ਨਹੀਂ ਕਰਦੇ। Native range ਦਾ ਡਿਫਾਲਟ 0…100, step 1 ਹੈ।
- `date`, `time`: text entry; ਸ਼ੁਰੂਆਤੀ value formats `YYYY-MM-DD`, `HH:MM`/`HH:MM:SS` ਹਨ (ਗਲਤ initial formats ਖਾਲੀ ਬਣਦੇ ਹਨ)। Edits ਖੁਦ validate ਕਰੋ। `color`: `#RRGGBB` (ਡਿਫਾਲਟ `#000000`)।
- `pin`: ਅੰਕਾਂ ਦੀ string; `length` 3–12 (ਡਿਫਾਲਟ 6), `masked` ਡਿਫਾਲਟ true, `autoSubmit` false। `section`: `text`, `controls`; depth 3 'ਤੇ child sections ਦੇ ਬੱਚੇ ਨਹੀਂ ਹੁੰਦੇ (root controls depth 0)।

Panel events: ਆਮ inputs `change` ਭੇਜਦੇ ਹਨ; buttons ਸਿਰਫ਼ `click`; PIN `change` ਅਤੇ autoSubmit ਭਰਨ 'ਤੇ `submit` ਭੇਜਦਾ ਹੈ। Native mount/unmount/focus/key events ਨਹੀਂ ਹਨ। Values strings ਹਨ, numbers/booleans ਸਮੇਤ। `values` rendered snapshot ਦੇ input values ਰੱਖਦਾ ਹੈ ਅਤੇ ਚਾਲੂ ਕਰਨ ਵਾਲੇ edit ਤੋਂ ਪਿੱਛੇ ਹੋ ਸਕਦਾ ਹੈ; `value` ਉਸ edit ਦੀ ਪਛਾਣ ਕਰਦਾ ਹੈ। ਭਰੋਸੇਯੋਗ forms ਲਈ ਇਸਨੂੰ `v.state` ਵਿੱਚ ਸੰਭਾਲੋ ਅਤੇ typed values render ਕਰੋ। Non-click events ਹਰ control ਲਈ 100ms ਅੰਦਰ ਇਕੱਠੇ ਕੀਤੇ ਜਾਂਦੇ ਹਨ; events ਨੂੰ keystrokes ਨਾ ਗਿਣੋ।

Text limits: title/label 240; description/text 1000; HTML 20000; placeholder 500; input text 2000; ਹੋਰ value strings 512; option value/label 256। ਵਾਧੂ ਲੰਬਾਈ truncate ਹੁੰਦੀ ਹੈ।

## Files

`op`: `"read"`, `"write"`, `"append"`, `"list"`, `"exists"`। Settings ਵਿੱਚ **Custom-rule folder** ਅਤੇ ਇਸ ਦੀ permission ਲੋੜੀਂਦੀ ਹੈ।

- `path` relative ਹੈ; `/` directories ਵੱਖ ਕਰਦਾ ਹੈ। Segments ਵਿੱਚ ASCII letters/digits, spaces ਅਤੇ `_.,@()-` ਮਨਜ਼ੂਰ ਹਨ; ਸ਼ੁਰੂ ਵਿੱਚ dot, `.`/`..`, absolute path ਜਾਂ URL ਮਨਜ਼ੂਰ ਨਹੀਂ। File suffix: `.txt`, `.csv`, `.json` (case-insensitive)। List path directory ਹੁੰਦਾ ਹੈ; `""` ਚੁਣਿਆ root ਦਰਸਾਉਂਦਾ ਹੈ। Symlinks ਰਾਹੀਂ ਸਮੇਤ ਚੁਣੇ folder ਤੋਂ ਬਾਹਰ ਜਾਂਦੇ paths ਰੱਦ ਹੁੰਦੇ ਹਨ।
- Read UTF-8 text ਦਿੰਦਾ ਹੈ। Write ਬਦਲਦਾ/ਬਣਾਉਂਦਾ ਹੈ; append ਬਿਨਾਂ automatic newline ਜੋੜਦਾ/ਬਣਾਉਂਦਾ ਹੈ। Write ਕਰਨ ਵੇਲੇ parent directories ਬਣਦੀਆਂ ਹਨ। String payload ਜਿਵੇਂ ਦਾ ਤਿਵੇਂ ਲਿਖਿਆ ਜਾਂਦਾ ਹੈ; ਹੋਰ JSON payload serialize ਹੁੰਦੇ ਹਨ; null/ਨਾ ਦਿੱਤਾ ਹੋਵੇ ਤਾਂ ਖਾਲੀ text। JSON/CSV parsing rule ਦਾ ਕੰਮ ਹੈ। ਵੱਧ ਤੋਂ ਵੱਧ file size: 1048576 UTF-8 bytes।
- List ਤੁਰੰਤ ਦਿਸਣ ਵਾਲੀਆਂ subdirectories ਅਤੇ ਸਮਰਥਿਤ files ਦਿੰਦਾ ਹੈ। Entries: `{ name: string, path: string, kind: "directory" | "file", extension?: string }`; files ਲਈ extension ਵਿੱਚ dot ਹੁੰਦਾ ਹੈ। Exists ਸਮਰਥਿਤ file path ਲਈ boolean ਦਿੰਦਾ ਹੈ।

```text
file.data = { requestId: string, op: string, path: string, ok: boolean,
              text: string | null, entries: Entry[] | null,
              exists: boolean | null, error: string }
```

ਨਾ ਵਰਤੇ result fields null ਹੁੰਦੇ ਹਨ; ਸਫਲਤਾ ਵਿੱਚ error ਖਾਲੀ ਹੁੰਦਾ ਹੈ। ਅਸਫਲਤਾਵਾਂ ਵਿੱਚ invalid-path, unsupported-file-type, folder unavailable, missing file ਅਤੇ file-too-large ਸ਼ਾਮਲ ਹਨ। Error ਨੂੰ string ਸਮਝੋ, ਪੂਰੀ ਤਰ੍ਹਾਂ ਨਿਰਧਾਰਤ enum ਨਹੀਂ। Transaction API ਨਹੀਂ; ਹਰ path ਲਈ read-modify-write ਕਾਰਵਾਈਆਂ ਲੜੀਵਾਰ ਕਰੋ।

## ਹੱਦਾਂ

ਹਰ event ਅਤੇ group ਲਈ: 256 queued actions, 200 log calls, 64 emits; ਵਾਧੂ ਛੱਡੇ ਜਾਂਦੇ ਹਨ। ਹਰ rule ਲਈ: 1000 handlers, 24 panels; ਹਰ control list ਵਿੱਚ 32 entries ਅਤੇ ਹਰ choice ਵਿੱਚ 64 options; ਵਾਧੂ ਅਣਡਿੱਠੇ/truncate ਹੁੰਦੇ ਹਨ। Emit chains 16 generations ਮਗਰੋਂ ਰੁਕਦੀਆਂ ਹਨ। Serialized state limit: 65536 JavaScript string characters। Registration ਅਤੇ ਹਰ event ਦੇ ਸਾਰੇ handlers 1 second ਤੋਂ ਘੱਟ ਰੱਖੋ; ਵਾਰ-ਵਾਰ ਹੱਦ ਲੰਘਣ ਜਾਂ hard timeout ਨਾਲ rule Run ਤੱਕ ਰੁਕ ਜਾਂਦਾ ਹੈ। Log ਹਰ group ਲਈ 200 entries ਰੱਖਦਾ ਹੈ। Timing/replies best-effort ਹਨ, real-time ਗਾਰੰਟੀ ਨਹੀਂ।

## ਪੂਰਾ ਨਿਯਮ

Steam blocked ਰਹਿੰਦਾ ਹੈ, ਸਿਵਾਏ ਪੰਜ ਮਿੰਟਾਂ ਦੇ pause ਦੌਰਾਨ ਜੋ Snooze ਜਾਂ ਇਸ ਦੇ panel button ਨਾਲ ਸ਼ੁਰੂ ਹੁੰਦਾ ਹੈ:

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
