# Hướng dẫn mã Mac Vault

[Hướng dẫn sử dụng](../manual/vi.md)

## Quy định của quy tắc

Source: một biểu thức hàm `(on, v) => { ... }`. Chỉ hỗ trợ JavaScript đồng bộ và API bên dưới; không có callback lập lịch JavaScript, mạng, API hệ thống native hoặc truy cập trang trình duyệt. Quy tắc dựa trên thời gian dùng bộ hẹn giờ/bộ theo dõi được quản lý bên dưới, hoặc `ev.now` và sự kiện. Quy tắc Safari dùng browser code manual và chạy trong ứng dụng chứa riêng của Safari Vault.

- Chỉnh sửa lưu thành draft; **Run** kích hoạt và bật nhóm. Nhóm khóa không thể Run. Source rỗng unload quy tắc.
- Run thành công thay handlers/panels và xóa app-block set của nhóm này, đồng thời giữ `v.state`. Compilation/registration thất bại sẽ giữ quy tắc trước; timeout có thể dừng quy tắc. Restart đăng ký lại source được kích hoạt gần nhất; closure variables và app-block sets được reset.
- Registration có thể khởi tạo state, đăng ký handlers, hiện panels và ghi log. Thao tác app/file cùng emits thuộc handlers; hàng đợi lúc registration bị bỏ.
- Disable ngăn handlers và gỡ panels/app blocks. Enable khôi phục rule đã tải cùng panels/blocks còn giữ. Delete gỡ handlers/state/effects. Ứng dụng đã quit không được mở lại; file writes không được hoàn tác.
- Events không bị giới hạn theo targets thường của nhóm; hãy chọn ứng dụng trong quy tắc. Actions được xếp hàng rồi áp dụng sau dispatch. Exception dừng handler nhưng không hoàn tác state/actions của nó; handlers sau có thể vẫn chạy. Chỉ file actions có result events.

## Bộ hẹn giờ được quản lý và mức sử dụng trong cửa sổ trượt

`v.timer(id, {direction:"down", durationMs:300000})` tạo hoặc trả về bộ đếm ngược có tên, ban đầu ở trạng thái tạm dừng. Dùng `{direction:"up"}` cho bộ đếm xuôi. Handle có `start()`, `pause()`, `resume()`, `reset()` và `snapshot()`. Gọi bắt đầu/tiếp tục nhiều lần vẫn cho cùng hiệu quả; đặt lại đưa về trạng thái tạm dừng với thời gian đã trôi qua bằng 0. Các trường snapshot gồm `ready`, `error`, `elapsedMs`, `remainingMs` (null với bộ đếm xuôi), `running` và `completed`.

Bộ hẹn giờ đang chạy tiếp tục tiến theo thời gian thực khi ứng dụng/trình duyệt đóng hoặc quy tắc bị tắt. Bộ đếm ngược hoàn tất gửi `timerEnded` kèm `{id, direction, durationMs, generation, incarnation}` một lần cho mỗi hiện thân và thế hệ bộ hẹn giờ, tới từng thành viên khi quy tắc của thành viên đó chạy tiếp; Run không gửi lại sự kiện này. Việc gửi phụ thuộc vào sự kiện của host; đây không phải báo thức thời gian thực. Đặt `{type:"timer", timerId:"focus", label:"Focus"}` trong panel để hiển thị qua điều khiển văn bản hiện có.

`v.rolling(id, {windowMs:3600000, limitMs:600000})` tạo hoặc trả về bộ theo dõi thời gian sử dụng thực tế có tên. `assign({websites:["youtube.com","reddit.com"], apps:[]})` thay thế các mục tiêu được gán cho thành viên này. Quy tắc native có thể gán ID ứng dụng của nền tảng thay thế. Tên miền bao gồm tên miền phụ. Một bộ theo dõi cộng gộp mức sử dụng của các mục tiêu; ID khác có hạn mức độc lập. `snapshot()` trả về `ready`, `error`, `usedMs`, `remainingMs`, `available` và `nextReturnAtMs` (thời điểm mili giây tiếp theo mà bất kỳ phần sử dụng đã ghi nào hết hạn). `available(target?)` cũng kiểm tra việc gán khi có mục tiêu. `reset()` xóa lịch sử của đối tượng này.

Mọi mức sử dụng đủ điều kiện quan sát được đều được tính, kể cả phần vượt hạn mức; bản thân bộ theo dõi không chặn trang/ứng dụng. Các khoảng trang hiển thị chồng lấn chỉ được tính một lần, còn ứng dụng native tính thời gian sử dụng ở tiền cảnh quan sát được. Quy tắc bị tắt không cộng thêm sử dụng; lịch sử vẫn hết hạn đúng tại ranh giới khoảng thời gian. Chỉ có thể sử dụng lại khi lịch sử còn lại thấp hơn giới hạn. Mẫu heartbeat bị giới hạn tối đa năm giây; khoảng trống do tắt ứng dụng/quy tắc không tự tạo hoạt động. Sự kiện do người dùng phát không cộng thêm sử dụng.

Các ID đối tượng giống nhau trong nhóm tùy chỉnh được liên kết cùng dùng một hub native cục bộ làm nguồn thẩm quyền. Liên kết hợp nhất lịch sử và mục tiêu được gán của bộ theo dõi, đồng thời giữ trạng thái bộ hẹn giờ của bên khởi tạo; cấu hình không tương thích sẽ từ chối liên kết. Mỗi thành viên nhận sự kiện hoàn tất riêng. Mất kết nối làm bộ theo dõi dùng chung không khả dụng và từ chối điều khiển bộ hẹn giờ cho đến khi có lại nguồn thẩm quyền mới nhất. Khi hủy liên kết, mỗi thành viên giữ mức sử dụng chung và trạng thái bộ hẹn giờ cuối cùng, khôi phục mục tiêu riêng và bỏ lệnh từ liên kết cũ. Hub giữ snapshot cuối cùng cho đến khi thành viên quay lại lưu và xác nhận; việc bàn giao đang chờ phải hoàn tất trước khi có thể dùng liên kết mới.

Đối tượng có tên tồn tại qua Run và khởi động lại trong `v.state.$vaultTime` được dành riêng; không sửa trực tiếp trường này. Xóa rõ ràng bằng `v.removeTime(id)`. ID gồm 1–80 chữ cái ASCII, chữ số, `_` hoặc `-`; tên thuộc tính dành riêng bị từ chối. Tối đa 32 đối tượng dùng chung giới hạn state UTF-8 64 KiB của quy tắc. Thời lượng là số nguyên mili giây, tối đa 365 ngày. Lịch sử trượt bị giới hạn ở 1024 bucket phút và 2048 khoảng đã hợp nhất. Lỗi dung lượng lịch sử khiến bộ theo dõi không khả dụng cho đến khi được đặt lại rõ ràng; cấu hình không hợp lệ và lần lưu quá lớn báo lỗi mà không xóa dữ liệu đã lưu.

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

- `on(type, handler)` → boolean. Đăng ký `handler(ev)`; nhiều handlers chạy theo thứ tự đăng ký. False nghĩa là arguments không hợp lệ hoặc chạm giới hạn handlers. `ev = { type: string, now: number, data }`; `now` là Unix milliseconds.
- `v.state`: JSON object thay đổi được, lưu sau event dispatch. Khởi tạo fields thiếu thay vì ghi đè state hiện có. Gán non-object hoặc array reset thành `{}`; cập nhật không serialize được/quá lớn sẽ không lưu.
- `v.log(...values)`: thêm vào Log của nhóm này. Lỗi thực thi và chuyển giao xuất hiện dưới dạng mục lỗi rõ ràng trong cùng bảng tin. Logs/Clear độc lập theo nhóm. Lỗi tải cũng hiện trong trạng thái Run; sự kiện đã thực thi một phần không tự động được chạy lại.
- `v.emit(type, data)`: xếp hàng bản sao JSON của `data` cho handlers nhóm này sau event hiện tại, cùng `now` mới; không phải lời gọi đồng bộ.
- `v.panel(id, spec)`: thay floating panel có tên của nhóm này; `spec` null sẽ xóa. Xem Panels.
- `v.file(op, path, payload?)` → request ID string. Xem Files.
- `v.block(appId, on)`: true duy trì chặn ứng dụng, false gỡ chặn của nhóm này. Chặn của các nhóm đang bật được kết hợp; lời gọi này không thể gỡ mục tiêu của nhóm khác. Việc chặn gửi yêu cầu thoát bình thường và thử lại theo interval trong Settings; không ngăn process khởi chạy và không đảm bảo ứng dụng chấp nhận Quit.
- `v.quit(appId)`: gửi một yêu cầu thoát bình thường, theo cùng chính sách bảo vệ/thử lại; không chặn liên tục.
- `v.open(appId)`: yêu cầu macOS mở ứng dụng đã cài; không có callback thành công.

Các lời gọi khác trả về `undefined`. ID ứng dụng là bundle identifier (ví dụ `com.valvesoftware.steam`), có trong sự kiện. Block/Quit có thể nhắm đến ứng dụng Apple và toàn bộ trình duyệt. Chúng bỏ qua bundle identifier của Mac Vault và các ứng dụng hỗ trợ của nó, bao gồm ứng dụng khác dùng chung danh tính đó, cùng ID trống. ID/state của panel thuộc về một nhóm, không phải tên hiển thị.

## Sự kiện

Ký hiệu payload bên dưới mô tả kiểu dữ liệu, không phải mã có thể chạy. `?` đánh dấu fields tùy chọn.

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

- `tick` gần đúng; dùng timestamps thay vì đếm tick. Running gồm process `.app` foreground, menu-bar và background có bundle IDs; không gồm mọi Unix process. Frontmost có thể null hoặc có app ID rỗng.
- `app` báo thay đổi vòng đời được quan sát trước event `tick` của tick đó. Chỉ focus có `previousAppId` (null nếu chưa biết). Names là tên hiển thị, không phải IDs ổn định.
- `snooze` nghĩa là nhấn nút Snooze của nhóm. Nó không tự tạm dừng gì.
- File replies gửi về nhóm yêu cầu. Đối chiếu `requestId`, kiểm tra `ok` và đặt deadline bằng ticks: replies có thể mất nếu rule được tải lại/tắt. Request IDs có thể lặp sau Run; requests đang chờ không phải công việc bền vững.

## Bảng điều khiển

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

## Tệp

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

## Bản ghi nhóm

`v.store(request)` bắt đầu thao tác bản ghi JSON bất đồng bộ trong handler. Bản ghi riêng tư theo nhóm, tồn tại qua Run và khởi động lại, rồi bị xóa cùng nhóm. Nhóm liên kết có store riêng. Quy tắc chọn key, value, version, cache invalidation và mức ưu tiên phản hồi. Quy tắc Mac và trình duyệt dùng cùng API nhưng mỗi app/trình duyệt có store riêng.

| Request | Result |
|---|---|
| `{op:"get", key}` | `record` hoặc `null` |
| `{op:"put", key, value, version?, ifRevision?}` | `record` đã lưu |
| `{op:"delete", key, ifRevision?}` | `record: null` |
| `{op:"list", prefix?, after?, limit?}` | `entries` đã sắp xếp và `next` |
| `{op:"clear", prefix?}` | số `deleted` |

Mỗi record là `{value, revision, version, updatedAt}`. `revision` opaque đổi khi ghi thực sự; `version` là metadata của bên gọi. `list` trả header không kèm value; dùng `get` để đọc, `after: next` để lấy trang tiếp. Bỏ `ifRevision` nghĩa là put/delete vô điều kiện; `null` yêu cầu key chưa tồn tại, chuỗi revision yêu cầu trùng khớp chính xác. Sai lệch trả `ok:false`, `error:"store-conflict"` và `record` hiện tại để phản hồi tự động đến muộn không ghi đè ý kiến người dùng. `v.context.revision` là dấu cấu hình opaque mà quy tắc có thể đưa vào version; framework không áp đặt chính sách cache.

Giới hạn: key 1–2048 ký tự, version ≤128, JSON value ≤64KiB, depth ≤32, 10000 key mỗi nhóm, toàn bộ tài liệu16MiB. `list` trả tối đa100 header và96KiB mỗi trang. Tối đa32 request mỗi nhóm và128 request khởi chạy mỗi giây tổng cộng; quá tải báo một `store-busy` mỗi nhóm mỗi giây và bỏ các yêu cầu dư. Lỗi lưu trữ trả `ok:false`; tài liệu phiên bản tương lai hoặc lỗi định dạng được giữ lại và báo `store-unavailable`. Không tự retry/evict. Dùng ticks đặt deadline.

## Giới hạn

Mỗi sự kiện của mỗi nhóm: 256 thao tác trong hàng đợi, 200 lần gọi log, 64 lần phát sự kiện; phần vượt bị bỏ. Mỗi quy tắc: 1000 handler, 24 panel; mỗi danh sách điều khiển có 32 mục và mỗi điều khiển lựa chọn có 64 tùy chọn; phần vượt bị bỏ qua/cắt bớt. Chuỗi phát sự kiện dừng sau 16 thế hệ. Giới hạn state đã tuần tự hóa: 65536 byte UTF-8. Giữ tổng thời gian đăng ký và các handler của từng sự kiện dưới 1 giây; vượt quá nhiều lần hoặc hết thời gian bắt buộc sẽ dừng quy tắc cho đến khi Run. Log giữ 200 mục cho mỗi nhóm. Thời điểm/phản hồi được xử lý theo nỗ lực tốt nhất, không bảo đảm thời gian thực.

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

## Lời gọi AI từ quy tắc đang chạy

Mỗi custom group chọn một connection/model và reasoning effort trong **AI calls**. Quy tắc Mac và trình duyệt dùng cùng API; request trình duyệt cần Mac Vault kết nối, thông tin nhà cung cấp được giữ tại đó. Nhóm liên kết chia sẻ lựa chọn và daily cap tùy chọn. Để trống nghĩa là không giới hạn ở nhóm; giới hạn tài khoản vẫn áp dụng. Cap theo ngày UTC, tồn tại qua khởi động lại và đếm mọi lần gửi kể cả lỗi. Link cộng usage hiện có; unlink giữ usage trước đó.

`v.ai({ prompt, input? })` trả request ID ngay. Gọi bên trong handler, không gọi lúc đăng ký quy tắc. `input` nhận mọi giá trị JSON; prompt/input tối đa20KB mỗi phần. Phản hồi đến trong event `ai`: `{requestId, ok, text, citations, error}`. Văn bản thành công tối đa48KB; citation `{url,title}`. Giữ liên kết nguồn hiển thị và có thể nhấp khi trình bày câu trả lời từ web search. Search luôn sẵn có cho mô hình. Không có deadline cố định của app; concurrency có giới hạn; không fallback nhà cung cấp hoặc tự retry. Phản hồi là dữ liệu, không thực thi như JavaScript; quy tắc quyết định có dùng hành động hiện có nào.

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

Lời gọi đang chờ không chạy lại sau khởi động. Run, tắt/bật lại và xóa sẽ loại phản hồi cũ; trình duyệt mất kết nối báo `ai-unavailable`. Lỗi khác: `ai-not-configured`, `ai-invalid-input`, `ai-busy`, `ai-daily-limit`, `ai-request-failed`, `ai-usage-storage-unavailable`. Lời gọi lỗi không thay kết quả trước mà quy tắc muốn giữ. State của quy tắc vẫn giới hạn64KB.

Tìm lựa chọn không cần credential bằng `rule_ai_models` trên Mac hoặc `settings-rule-ai-models` trong trình duyệt; cấu hình `ruleAI` qua đường set-group hiện có. Các trường: `providerModel`, `accountID`, `reasoningEffort` (`default`, `low`, `medium`, `high`) và `dailyRequestLimit` (null hoặc1–100000). Dùng lựa chọn được trả về; không đặt key hoặc URL nhà cung cấp trong mã nguồn quy tắc.
