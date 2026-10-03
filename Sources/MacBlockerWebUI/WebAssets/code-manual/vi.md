# Hướng dẫn mã Mac Vault

[Hướng dẫn sử dụng](../manual/vi.md)

## Quy định của quy tắc

Source: một biểu thức hàm `(on, v) => { ... }`. Chỉ hỗ trợ JavaScript đồng bộ và API bên dưới; không có timers, network, native system APIs hoặc truy cập browser-page. Quy tắc theo thời gian dùng `ev.now` và events. Quy tắc Safari dùng browser code manual và chạy trong ứng dụng chứa riêng của Safari Vault.

- Chỉnh sửa lưu thành draft; **Run** kích hoạt và bật nhóm. Nhóm khóa không thể Run. Source rỗng unload quy tắc.
- Run thành công thay handlers/panels và xóa app-block set của nhóm này, đồng thời giữ `v.state`. Compilation/registration thất bại sẽ giữ quy tắc trước; timeout có thể dừng quy tắc. Restart đăng ký lại source được kích hoạt gần nhất; closure variables và app-block sets được reset.
- Registration có thể khởi tạo state, đăng ký handlers, hiện panels và ghi log. Thao tác app/file cùng emits thuộc handlers; hàng đợi lúc registration bị bỏ.
- Disable ngăn handlers và gỡ panels/app blocks. Enable khôi phục rule đã tải cùng panels/blocks còn giữ. Delete gỡ handlers/state/effects. Ứng dụng đã quit không được mở lại; file writes không được hoàn tác.
- Events không bị giới hạn theo targets thường của nhóm; hãy chọn ứng dụng trong quy tắc. Actions được xếp hàng rồi áp dụng sau dispatch. Exception dừng handler nhưng không hoàn tác state/actions của nó; handlers sau có thể vẫn chạy. Chỉ file actions có result events.

## API

- `on(type, handler)` → boolean. Đăng ký `handler(ev)`; nhiều handlers chạy theo thứ tự đăng ký. False nghĩa là arguments không hợp lệ hoặc chạm giới hạn handlers. `ev = { type: string, now: number, data }`; `now` là Unix milliseconds.
- `v.state`: JSON object thay đổi được, lưu sau event dispatch. Khởi tạo fields thiếu thay vì ghi đè state hiện có. Gán non-object hoặc array reset thành `{}`; cập nhật không serialize được/quá lớn sẽ không lưu.
- `v.log(...values)`: nguồn duy nhất ghi Log của nhóm này. Logs/Clear độc lập từng nhóm. Load errors hiện trong Run status; handler diagnostics không ghi Log.
- `v.emit(type, data)`: xếp hàng bản sao JSON của `data` cho handlers nhóm này sau event hiện tại, cùng `now` mới; không phải lời gọi đồng bộ.
- `v.panel(id, spec)`: thay floating panel có tên của nhóm này; `spec` null sẽ xóa. Xem Panels.
- `v.file(op, path, payload?)` → request ID string. Xem Files.
- `v.block(appId, on)`: true duy trì chặn ứng dụng, false gỡ chặn của nhóm này. Chặn của các nhóm đang bật được kết hợp; lời gọi này không thể gỡ mục tiêu của nhóm khác. Việc chặn gửi yêu cầu thoát bình thường và thử lại theo interval trong Settings; không ngăn process khởi chạy và không đảm bảo ứng dụng chấp nhận Quit.
- `v.quit(appId)`: gửi một yêu cầu thoát bình thường, theo cùng chính sách bảo vệ/thử lại; không chặn liên tục.
- `v.open(appId)`: yêu cầu macOS mở ứng dụng đã cài; không có callback thành công.

Các lời gọi khác trả `undefined`. App IDs là bundle identifiers (ví dụ `com.valvesoftware.steam`), có trong events. Block/Quit bỏ qua `com.apple.*`, browsers, Vault và helpers của Vault, cùng IDs trống. Panel IDs/state thuộc về nhóm, không phải tên hiển thị.

## Events

Ký hiệu payload bên dưới mô tả kiểu dữ liệu, không phải mã có thể chạy. `?` đánh dấu fields tùy chọn.

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

- `tick` gần đúng; dùng timestamps thay vì đếm tick. Running gồm process `.app` foreground, menu-bar và background có bundle IDs; không gồm mọi Unix process. Frontmost có thể null hoặc có app ID rỗng.
- `app` báo thay đổi vòng đời được quan sát trước event `tick` của tick đó. Chỉ focus có `previousAppId` (null nếu chưa biết). Names là tên hiển thị, không phải IDs ổn định.
- `snooze` nghĩa là nhấn nút Snooze của nhóm. Nó không tự tạm dừng gì.
- File replies gửi về nhóm yêu cầu. Đối chiếu `requestId`, kiểm tra `ok` và đặt deadline bằng ticks: replies có thể mất nếu rule được tải lại/tắt. Request IDs có thể lặp sau Run; requests đang chờ không phải công việc bền vững.

## Panels

```text
spec = { title?: string, description?: string, controls?: Control[],
         position?: "top-left" | "top-right" | "bottom-left" | "bottom-right" | "center",
         width?: "small" | "medium" | "large" | number }
Control = { id?: string, type?: string, label?: string, value?, disabled?: boolean,
            ...type-specific fields below }
```

Mặc định: vị trí dưới bên phải, rộng 300px; preset small/medium/large lần lượt 220/280/360px; độ rộng số giới hạn 180–520px và nhận pixel strings. Native panels/sections xếp controls theo chiều dọc; browser layout, alignment, role, autofocus và control-dimension fields không ảnh hưởng native renderer.

IDs được chuẩn hóa thành ASCII letters/digits/`_`/`-` (tối đa 80); chọn IDs ổn định, duy nhất. Control ID bỏ trống thành `control-N`; type bỏ trống/không biết thành text. text/lists bỏ trống là rỗng; disabled là false. Mỗi lời gọi thay toàn bộ spec. `value` được nêu rõ sẽ ghi đè; nếu bỏ qua sẽ dùng event value gần nhất rồi chuẩn hóa theo type. Native events cung cấp strings: parse sang value type đã khai báo trước khi render panel cập nhật. Fields lạ bị bỏ; panel colors/fonts/CSS thuộc Vault.

Các fields và values ban đầu của controls:

- `text`: string `text`; mặc định theo label. `html`: string `html`, được sanitize và hiển thị thành văn bản thuần trên Mac.
- `button`: `label`, `action: "submit" | "cancel" | "close"` tùy chọn. Giá trị click là action string hoặc rỗng. Actions không tự submit/close gì.
- `checkbox`, `toggle`: boolean `value` (mặc định false); event value là `"true"`/`"false"`.
- `select`, `radio`: `options: (string | { value: string, label?: string })[]`; string value (mặc định rỗng). Xóa option values rỗng; labels mặc định theo value. Cập nhật typed value của panel sau khi chọn.
- `textInput`, `textarea`: string value (mặc định rỗng); textInput có `placeholder`; textarea `rows` 1–12 (mặc định 3). Native textarea bỏ qua placeholder.
- `numberInput`, `range`: numeric value (mặc định 0), `min`, `max`, `step` dương. Khi cập nhật panel values bị giới hạn theo bounds; bounds normalization không nêu là −1000000…1000000. Native numberInput là nhập văn bản: tự kiểm tra `Number(event.value)`; min/max/step không hạn chế việc nhập. Native range mặc định 0…100 với step 1.
- `date`, `time`: nhập văn bản; formats ban đầu `YYYY-MM-DD`, `HH:MM`/`HH:MM:SS` (format sai sẽ thành rỗng). Tự kiểm tra chỉnh sửa. `color`: `#RRGGBB` (mặc định `#000000`).
- `pin`: string chữ số; `length` 3–12 (mặc định 6), `masked` mặc định true, `autoSubmit` false. `section`: `text`, `controls`; child sections ở depth 3 không có children (root controls depth 0).

Panel events: input thông thường gửi `change`; buttons chỉ gửi `click`; PIN gửi `change` và `submit` khi autoSubmit nhập đủ. Không có native mount/unmount/focus/key events. Values là strings, gồm cả numbers/booleans. `values` chứa input values của rendered snapshot và có thể chậm hơn edit gây event; `value` xác định edit đó. Lưu vào `v.state` và render typed values để form đáng tin cậy. Non-click events được gộp trong 100ms cho mỗi control; đừng đếm events như keystrokes.

Giới hạn text: title/label 240; description/text 1000; HTML 20000; placeholder 500; input text 2000; value strings khác 512; option value/label 256. Phần vượt mức bị cắt.

## Files

`op`: `"read"`, `"write"`, `"append"`, `"list"`, `"exists"`. Cần bật **Thư mục quy tắc tùy chỉnh** trong Settings và cấp quyền.

- `path` là relative; `/` phân cách directories. Segments cho phép ASCII letters/digits, spaces và `_.,@()-`; không cho dấu chấm ở đầu, `.`/`..`, absolute path hoặc URL. Đuôi tệp: `.txt`, `.csv`, `.json` (không phân biệt hoa thường). List path là directory; `""` liệt kê root đã chọn. Paths thoát ra ngoài thư mục đã chọn, kể cả qua symlinks, đều bị từ chối.
- Read trả UTF-8 text. Write thay thế/tạo; append tạo/nối thêm không tự thêm newline. Thư mục cha được tạo khi ghi. String payload ghi nguyên văn; JSON payload khác được serialize; null/bỏ qua nghĩa là text rỗng. Rule tự xử lý JSON/CSV. Kích thước tệp tối đa: 1048576 UTF-8 bytes.
- List trả subdirectories và files được hỗ trợ ngay bên dưới, đang hiển thị. Entries: `{ name: string, path: string, kind: "directory" | "file", extension?: string }`; extension của files có dấu chấm. Exists trả boolean cho file path được hỗ trợ.

```text
file.data = { requestId: string, op: string, path: string, ok: boolean,
              text: string | null, entries: Entry[] | null,
              exists: boolean | null, error: string }
```

result fields không dùng là null; thành công có error rỗng. Lỗi gồm invalid-path, unsupported-file-type, folder unavailable, missing file và file-too-large. Xem error là string, không phải enum cố định đầy đủ. Không có transaction API; tuần tự hóa thao tác read-modify-write theo từng path.

## Giới hạn

Mỗi event trên mỗi group: 256 queued actions, 200 log calls, 64 emits; phần vượt bị bỏ. Mỗi rule: 1000 handlers, 24 panels; mỗi control list có 32 entries, mỗi choice 64 options; phần vượt bị bỏ qua/cắt. Emit chains dừng sau 16 generations. Serialized state limit: 65536 JavaScript string characters. Giữ registration và handlers kết hợp mỗi event dưới 1 second; vượt lặp lại hoặc hard timeout sẽ dừng rule đến khi Run. Log lưu 200 entries mỗi nhóm. Timing/replies là best-effort, không đảm bảo real-time.

## Quy tắc đầy đủ

Steam bị chặn trừ khoảng tạm dừng năm phút được kích hoạt bởi Snooze hoặc nút panel của nó:

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
