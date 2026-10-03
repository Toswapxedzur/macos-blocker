# คู่มือโค้ด Mac Vault

[คู่มือผู้ใช้](../manual/th.md)

## ข้อกำหนดของกฎ

แหล่งที่มา: function expression หนึ่งรายการ `(on, v) => { ... }` รองรับเฉพาะ synchronous JavaScript และ API ด้านล่าง ไม่มี timers, network, native system APIs หรือการเข้าถึง browser-page กฎที่อิงเวลาใช้ `ev.now` และ events กฎของ Safari ใช้ browser code manual และทำงานในแอป container ของ Safari Vault เอง

- การแก้ไขจะบันทึกเป็น draft; **Run** จะเปิดใช้และเปิดใช้กลุ่ม กลุ่มที่ตรึงไว้กด Run ไม่ได้ source ว่างจะ unload กฎ
- Run ที่สำเร็จจะแทนที่ handlers/panels และล้าง app-block set ของกลุ่มนี้ โดยเก็บ `v.state` ไว้ หาก compilation/registration ล้มเหลวจะคงกฎก่อนหน้าไว้ แต่ timeout อาจหยุดได้ Restart จะ register source ที่เปิดใช้ล่าสุดอีกครั้ง; closure variables และ app-block sets จะ reset
- ระหว่าง registration อาจเริ่มต้น state, register handlers, แสดง panels และเขียน log ได้ การกระทำกับแอป/ไฟล์และ emits ต้องอยู่ใน handlers; สิ่งที่ queue ไว้ตอน registration จะถูกทิ้ง
- Disable จะระงับ handlers และนำ panels/app blocks ออก Enable จะคืน rule ที่โหลดและ panels/blocks ที่เก็บไว้ Delete จะนำ handlers/state/effects ออก แอปที่ quit ไปแล้วจะไม่เปิดใหม่; file writes จะไม่ถูกย้อนกลับ
- Events ไม่จำกัดตาม targets ทั่วไปของกลุ่ม ให้เลือกแอปในกฎ Actions จะถูก queue แล้วนำไปใช้หลัง dispatch หากเกิด exception handler นั้นหยุดโดยไม่ย้อน state/actions; handlers ถัดไปอาจยังทำงาน มีเพียง file actions ที่มี result events

## API

- `on(type, handler)` → boolean ลงทะเบียน `handler(ev)`; หลาย handlers ทำงานตามลำดับที่ลงทะเบียน False หมายถึง arguments ไม่ถูกต้องหรือถึงขีดจำกัด handlers `ev = { type: string, now: number, data }`; `now` คือ Unix milliseconds
- `v.state`: JSON object ที่แก้ไขได้และบันทึกหลัง event dispatch ให้เริ่มเฉพาะ fields ที่หายไปแทนการเขียนทับ state เดิม การกำหนด non-object หรือ array จะ reset เป็น `{}`; การอัปเดตที่ serialize ไม่ได้หรือใหญ่เกินไปจะไม่ถูกบันทึก
- `v.log(...values)`: วิธีเดียวที่สร้าง Log ของกลุ่มนี้ Logs/Clear แยกกันแต่ละกลุ่ม Load errors ปรากฏใน Run status; handler diagnostics ไม่ลงใน Log
- `v.emit(type, data)`: queue สำเนา JSON ของ `data` ให้ handlers กลุ่มนี้หลัง event ปัจจุบัน พร้อม `now` ใหม่; ไม่ใช่ synchronous call
- `v.panel(id, spec)`: แทนที่ floating panel ที่ตั้งชื่อของกลุ่มนี้; หาก `spec` เป็น null จะนำออก ดู Panels
- `v.file(op, path, payload?)` → request ID string ดู Files
- `v.block(appId, on)`: true คงการบล็อกแอปไว้; false นำ block ของกลุ่มนี้ออก Blocks จากกลุ่มที่เปิดใช้อยู่จะรวมกัน; call นี้ปลด block เป้าหมายของกลุ่มอื่นไม่ได้ การบล็อกจะขอให้ปิดตามปกติและลองใหม่ตาม interval ใน Settings; ไม่ขัดขวางการเปิด process และไม่รับประกันว่าแอปจะยอม Quit
- `v.quit(appId)`: ขอปิดตามปกติหนึ่งครั้ง ภายใต้นโยบาย protection/retry เดียวกัน; ไม่ใช่ block ต่อเนื่อง
- `v.open(appId)`: ขอให้ macOS เปิดแอปที่ติดตั้งไว้; ไม่มี success callback

Calls อื่นคืน `undefined` App IDs คือ bundle identifiers (เช่น `com.valvesoftware.steam`) ที่มีให้ใน events Block/Quit จะละเว้น `com.apple.*`, browsers, Vault และ helpers ของ Vault รวมถึง IDs ว่าง Panel IDs/state เป็นของกลุ่ม ไม่ใช่ชื่อที่แสดง

## Events

สัญกรณ์ payload ด้านล่างระบุชนิดข้อมูล ไม่ใช่โค้ดที่รันได้ `?` หมายถึง field ที่ไม่บังคับ

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

- `tick` เป็นค่าโดยประมาณ ใช้ timestamps แทนการนับ ticks Running รวม processes `.app` แบบ foreground, menu-bar และ background ที่มี bundle IDs; ไม่ได้รวมทุก Unix process Frontmost อาจเป็น null หรือมี app ID ว่าง
- `app` รายงานการเปลี่ยน lifecycle ที่สังเกตเห็นก่อน `tick` event ของ tick นั้น เฉพาะ focus เท่านั้นที่มี `previousAppId` (ถ้าไม่ทราบจะเป็น null) Names เป็นชื่อแสดงผล ไม่ใช่ IDs ถาวร
- `snooze` หมายถึงกดปุ่ม Snooze ของกลุ่ม ไม่ได้พักอะไรด้วยตัวเอง
- File replies ส่งให้กลุ่มที่ร้องขอ จับคู่ด้วย `requestId`, ตรวจ `ok` และตั้ง deadline ด้วย ticks: replies อาจหายถ้า reload/disable rule Request IDs อาจซ้ำหลัง Run; requests ที่ค้างไม่ใช่งานถาวร

## Panels

```text
spec = { title?: string, description?: string, controls?: Control[],
         position?: "top-left" | "top-right" | "bottom-left" | "bottom-right" | "center",
         width?: "small" | "medium" | "large" | number }
Control = { id?: string, type?: string, label?: string, value?, disabled?: boolean,
            ...type-specific fields below }
```

ค่าเริ่มต้น: ตำแหน่งล่างขวา ความกว้าง 300px; presets small/medium/large คือ 220/280/360px; ความกว้างตัวเลขจำกัดที่ 180–520px และรับ pixel strings ได้ Native panels/sections เรียง controls แนวตั้ง; browser layout, alignment, role, autofocus และ control-dimension fields ไม่มีผลกับ native renderer

IDs ปรับเป็น ASCII letters/digits/`_`/`-` (สูงสุด 80); เลือก IDs ที่ไม่ซ้ำและคงที่ หากไม่ระบุ control ID จะเป็น `control-N`; type ที่ไม่ระบุ/ไม่รู้จักจะเป็น text ข้อความ/lists ที่ไม่ระบุจะว่าง; disabled เป็น false แต่ละ call จะแทนที่ spec ทั้งหมด `value` ที่ระบุชัดจะใช้ก่อน; หากไม่ระบุจะใช้ event value ล่าสุดแล้ว normalize ตาม type Native events ส่ง strings: parse เป็น value type ที่กำหนดก่อน render panel ใหม่ fields ที่ไม่รู้จักจะถูกทิ้ง; panel colors/fonts/CSS เป็นของ Vault

Fields และค่าเริ่มต้นของ controls:

- `text`: string `text`; ค่าเริ่มต้นตาม label `html`: string `html`, ผ่านการ sanitize และแสดงเป็นข้อความธรรมดาบน Mac
- `button`: `label`, และ `action: "submit" | "cancel" | "close"` ที่ไม่บังคับ ค่า click คือ action string หรือค่าว่าง Actions ไม่ submit/close อะไรโดยอัตโนมัติ
- `checkbox`, `toggle`: boolean `value` (เริ่มต้น false); event value คือ `"true"`/`"false"`
- `select`, `radio`: `options: (string | { value: string, label?: string })[]`; string value (เริ่มต้นว่าง) นำ option values ที่ว่างออก; labels เริ่มต้นตาม value หลังเลือกให้อัปเดต typed value ของ panel
- `textInput`, `textarea`: string value (เริ่มต้นว่าง); textInput มี `placeholder`; textarea `rows` 1–12 (เริ่มต้น 3) Native textarea ไม่ใช้ placeholder
- `numberInput`, `range`: numeric value (เริ่มต้น 0), `min`, `max`, `step` ที่เป็นบวก เมื่ออัปเดต panel จะจำกัด values ให้อยู่ใน bounds; bounds สำหรับ normalization ที่ไม่ได้ระบุคือ −1000000…1000000 Native numberInput เป็นการป้อนข้อความ: ตรวจ `Number(event.value)` เอง; min/max/step ไม่จำกัดการพิมพ์ Native range เริ่มต้น 0…100 โดย step 1
- `date`, `time`: ป้อนข้อความ; รูปแบบค่าเริ่มต้น `YYYY-MM-DD`, `HH:MM`/`HH:MM:SS` (รูปแบบเริ่มต้นไม่ถูกต้องจะว่าง) ตรวจ edits เอง `color`: `#RRGGBB` (เริ่มต้น `#000000`)
- `pin`: string ตัวเลข; `length` 3–12 (เริ่มต้น 6), `masked` เริ่มต้น true, `autoSubmit` false `section`: `text`, `controls`; child sections ที่ depth 3 ไม่มี children (root controls depth 0)

Panel events: inputs ทั่วไปส่ง `change`; buttons ส่งเฉพาะ `click`; PIN ส่ง `change` และ `submit` เมื่อ autoSubmit กรอกครบ ไม่มี native mount/unmount/focus/key events Values เป็น strings รวมถึง numbers/booleans `values` มีค่า input จาก rendered snapshot และอาจล้าหลัง edit ที่ทำให้เกิด event; `value` ระบุ edit นั้น สำหรับ forms ที่เชื่อถือได้ ให้เก็บไว้ใน `v.state` และ render typed values Non-click events จะรวมภายใน 100ms ต่อ control; อย่านับ events เป็นจำนวน keystrokes

ขีดจำกัดข้อความ: title/label 240; description/text 1000; HTML 20000; placeholder 500; input text 2000; value strings อื่น 512; option value/label 256 ข้อความเกินจะถูกตัด

## Files

`op`: `"read"`, `"write"`, `"append"`, `"list"`, `"exists"` ต้องเปิด **โฟลเดอร์กฎแบบกำหนดเอง** และ permission ของโฟลเดอร์ใน Settings

- `path` เป็น relative; `/` ใช้แยก directories แต่ละส่วนอนุญาต ASCII letters/digits, spaces และ `_.,@()-`; ห้ามเริ่มด้วยจุด, `.`/`..`, absolute path หรือ URL นามสกุลไฟล์: `.txt`, `.csv`, `.json` (ไม่แยกตัวพิมพ์เล็กใหญ่) List path เป็น directory; `""` แสดง root ที่เลือก Paths ที่ออกนอกโฟลเดอร์ที่เลือก รวมถึงผ่าน symlinks จะถูกปฏิเสธ
- Read คืน UTF-8 text Write แทนที่/สร้างไฟล์; append สร้าง/ต่อท้ายโดยไม่เพิ่ม newline อัตโนมัติ การเขียนจะสร้าง parent directories ให้ String payload เขียนตามตัวอักษร; JSON payload อื่นจะ serialize; null/ไม่ระบุหมายถึง text ว่าง JSON/CSV parsing เป็นหน้าที่ของ rule ขนาดไฟล์สูงสุด: 1048576 UTF-8 bytes
- List คืน subdirectories และ files ที่รองรับซึ่งมองเห็นได้ในระดับถัดไป Entries: `{ name: string, path: string, kind: "directory" | "file", extension?: string }`; extension ของ files มีจุดนำหน้า Exists คืน boolean สำหรับ file path ที่รองรับ

```text
file.data = { requestId: string, op: string, path: string, ok: boolean,
              text: string | null, entries: Entry[] | null,
              exists: boolean | null, error: string }
```

result fields ที่ไม่ได้ใช้เป็น null; เมื่อสำเร็จ error จะว่าง ความล้มเหลวรวมถึง invalid-path, unsupported-file-type, folder unavailable, missing file และ file-too-large ให้ถือว่า error เป็น string ไม่ใช่ enum ที่แจกแจงครบ API ไม่มี transaction; จัด read-modify-write ตามลำดับสำหรับแต่ละ path

## ขีดจำกัด

ต่อ event ต่อ group: 256 queued actions, 200 log calls, 64 emits; ส่วนเกินจะถูกทิ้ง ต่อ rule: 1000 handlers, 24 panels; แต่ละ control list มี 32 entries และแต่ละ choice มี 64 options; ส่วนเกินจะถูกละเว้น/ตัด Emit chains หยุดหลัง 16 generations Serialized state limit: 65536 JavaScript string characters ให้ registration และ handlers รวมของแต่ละ event ใช้เวลาต่ำกว่า 1 second หากเกินซ้ำ ๆ หรือชน hard timeout rule จะหยุดจนกด Run Log เก็บ 200 entries ต่อกลุ่ม Timing/replies เป็น best-effort ไม่ใช่การรับประกันแบบ real-time

## กฎฉบับเต็ม

Steam ถูกบล็อก ยกเว้นช่วงพักห้านาทีที่เริ่มจาก Snooze หรือปุ่ม panel ของมัน:

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
