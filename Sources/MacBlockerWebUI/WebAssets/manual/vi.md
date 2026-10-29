# Hướng dẫn sử dụng Mac Vault

Mac Vault có ba trang: **Vault** chặn ứng dụng native, **Gắn thẻ nội dung** gắn thẻ nội dung trình duyệt được hỗ trợ và **Hoạt động** hiển thị hoạt động đã ghi. Tiện ích mở rộng trình duyệt thu thập nội dung hỗ trợ và áp dụng chặn trong trình duyệt. Hãy cài đặt và kết nối tiện ích trong trình duyệt bạn dùng.

## Bắt đầu nhanh

1. Trong **Vault**, thêm nhóm chặn và mục tiêu Apps, rồi chọn ứng dụng bằng bộ chọn +.
2. Chọn cách chặn và bật nhóm.
3. Trong **Gắn thẻ nội dung**, tạo nhóm, chọn nền tảng và thêm thẻ kèm mô tả.
4. Mở Cài đặt → **Kết nối AI**, chọn ChatGPT subscription, OpenAI API, Gemini API hoặc Grok API. Kết nối tài khoản hoặc nhập khóa và tải danh sách mô hình; sau đó chọn kết nối/mô hình cho nhóm. Bật tagging và tiếp tục nhóm.
5. Mở nội dung được hỗ trợ trong trình duyệt đã kết nối. Đặt bộ lọc thẻ trong browser nhóm chặn nếu muốn thẻ điều khiển việc chặn.

## Nhóm chặn

**Nhóm chặn** áp dụng chính sách chặn. **Gắn thẻ nội dung** gán thẻ cho nội dung, không tự chặn. Thêm và đặt tên nhóm, chọn mục tiêu tại **Áp dụng cho**, xác định thời điểm chặn rồi đặt lịch hoặc hạn mức thời gian, sau đó bật nhóm. Các sửa đổi thông thường được lưu tự động. Lỗi nghĩa là thay đổi chưa được chấp nhận; hãy sửa trường và thử lại. Tắt nhóm dừng chính sách nhưng giữ cấu hình; **Xoa nhom** xóa nhóm. Kéo để sắp xếp nhóm. Nhiều nhóm có thể áp dụng cho cùng mục tiêu; snooze một nhóm không bỏ chặn của nhóm khác. **Xuất khẩu** sao chép cấu hình; **Nhập khẩu** thay cấu hình của nhóm đã chọn sau khi xác nhận.

### Hạn mức thời gian và lịch

**Block immediately** chặn khi nhóm bật khớp điều kiện và lịch đang hoạt động. **Block when the time allowance is used** cho phép dùng đến khi hết hạn mức. Đặt hạn mức theo phút và chu kỳ đặt lại theo giờ. Rolling limit tính mức dùng trong cửa sổ trước đó. Đặt lại lúc nửa đêm bắt đầu chu kỳ mới theo nửa đêm địa phương, kể cả với rolling limit. Chọn các ngày trong tuần hoạt động và các khoảng giờ địa phương tùy chọn, mỗi dòng một khoảng, ví dụ **09:00-12:00**. Danh sách khoảng trống áp dụng suốt ngày đã chọn. Khoảng phải kết thúc muộn hơn lúc bắt đầu trong cùng ngày; chia lịch qua đêm thành các ngày riêng.

### Tạm hoãn

Cấu hình snooze cho từng nhóm chặn. **Pause blocking** tạm dừng chính sách trong thời lượng đã chọn. **Add to the time allowance** cộng phút có thể dùng cho nhóm giới hạn thời gian. Chỉ phần hạn mức bổ sung đã dùng mới được tính là thời gian snooze. Phần dư hết hạn khi đặt lại lần tới; với rolling limit thì sau một cửa sổ, hoặc sớm hơn vào nửa đêm nếu bật đặt lại. **Activation delay** trì hoãn snooze trong khi chặn vẫn tiếp tục. **Cooldown** là thời gian chờ sau snooze trước yêu cầu kế tiếp. **Required confirmations** đặt số bước xác nhận. Nhóm bị freeze chỉ dùng snooze nếu đã cho phép trước khi freeze.

### Freeze và PIN

**Freeze** ngăn sửa đổi thông thường. Bỏ freeze cần mười lần xác nhận cách nhau năm giây, thời gian chờ đã đặt và PIN sáu chữ số. **Wait before unfreezing** nhận 0–72 giờ; 0 nghĩa là không chờ. Khi đang freeze, có thể tăng thời gian chờ và thêm PIN còn thiếu, nhưng không thể nới điều kiện trước khi bỏ freeze. Xóa nhóm cũng phải tuân theo thời gian còn lại và PIN.

### Nhóm liên kết

Dùng **Liên kết** để nối các nhóm được chọn rõ ràng từ chương trình Vault khác. Nhóm chia sẻ tên, cài đặt chính sách được hỗ trợ, mục tiêu, mức dùng và điều kiện freeze. Mỗi chương trình sửa và thực thi loại mục tiêu mà nó hỗ trợ; mục tiêu khác vẫn có sẵn cho chương trình liên kết. **Hủy liên kết** ngắt liên kết nhưng giữ nhóm và cài đặt. Nếu thành viên ngoại tuyến, mở Mac Vault và trình duyệt liên kết để kết nối lại. Chính sách đã lưu cục bộ có thể tiếp tục áp dụng khi thành viên ngoại tuyến.

## Trợ giúp

Nhấp **i** nhỏ cạnh trường để xem giải thích; nhấp bên ngoài hoặc nhấn Escape để đóng. Danh sách nằm trong hộp có thể cuộn; tìm kiếm lọc mục đang hiển thị mà không xóa. [Code manual](../code-manual/vi.md) dành cho quy tắc tùy chỉnh giải thích trình soạn thảo, kích hoạt, nhật ký, quyền truy cập tệp và API.

## Ứng dụng native

Dùng bộ chọn + của mục tiêu Apps để chọn ứng dụng đã cài hoặc đang chạy. Mở lại để làm mới danh sách sau khi chạy ứng dụng từ thư mục khác. **Chặn tất cả ứng dụng ngoại trừ các ứng dụng được liệt kê ở đây** biến danh sách thành allowlist. Mac Vault có thể chặn ứng dụng Apple thông thường và toàn bộ trình duyệt; Mac Vault và ứng dụng dùng chung bundle identifier vẫn được bảo vệ. Ứng dụng bị chặn được yêu cầu thoát; **Yêu cầu ứng dụng bị chặn thoát lại mỗi (phút)** đặt khoảng thời gian yêu cầu lại. Chuyển hướng trang web, tạm dừng trang và ẩn feed do tiện ích mở rộng trình duyệt thực hiện, không phải hành động native.

## Gắn thẻ nội dung

Mỗi nhóm gắn thẻ nội dung từ nền tảng được gán bằng cây thẻ và cài đặt mô hình riêng. Mỗi nền tảng thuộc một nhóm; chọn khi tạo vì sau đó không đổi được. Lịch và bộ lọc nhóm chặn không điều khiển tagging. Bật tagging trong Cài đặt và dùng **Tạm dừng gắn thẻ / Tiếp tục gắn thẻ** riêng từng nhóm. Tắt ghi feed nền tảng tại **Hoạt động → Ghi dữ liệu** cũng dừng tagging của feed đó.

### Thẻ và cài đặt mô hình

Tạo thẻ, mô tả ý nghĩa, đặt hoặc bỏ thẻ cha trong cây. Kéo thẻ để di chuyển nhánh. Mô tả rõ giúp mô hình phân biệt các thẻ giống nhau. Cài đặt mỗi nhóm độc lập. **Độ tin cậy tối thiểu của thẻ** đặt mức bằng chứng cần cho từng thẻ dự đoán từ 1 đến 5; nhóm mới bắt đầu ở 4 (hỗ trợ mạnh). Không có số lượng thẻ mục tiêu; mục có thể không có thẻ. **Hướng dẫn gắn thẻ** lưu tùy chọn của nhóm. Sửa đổi thông thường tự lưu; mỗi nhóm dùng connection, model và reasoning effort đã chọn rõ ràng.

### Kết nối AI

Cài đặt có ChatGPT subscription, OpenAI API, Gemini API và Grok API. Đăng ký ChatGPT dùng đăng nhập riêng của Vault và gói đủ điều kiện. API key chịu phí và giới hạn của nhà cung cấp đã chọn. Chọn nhà cung cấp rồi nhập key ngay dưới danh sách chung; chỉnh sửa key tự lưu, xóa nội dung trường sẽ xóa key. **Tải danh sách mô hình** lấy mô hình nhưng không tự chọn; hãy chọn model trong nhóm Gắn thẻ nội dung hoặc custom-rule.

**Mức độ suy luận** điều chỉnh mức suy nghĩ của mô hình: Model default, Low, Medium hoặc High nếu được hỗ trợ. Lựa chọn mới bắt đầu ở Medium; lựa chọn cũ giữ nguyên. Mức cao hơn có thể tốn thời gian và token. Web search luôn bật cho tagging; mô hình quyết định lúc dùng. Chọn mô hình hỗ trợ tìm kiếm và tagging có cấu trúc. Yêu cầu lỗi/không khả dụng vẫn giữ kết quả cache hợp lệ; mục mới chưa có kết quả cho đến khi chọn **Thử lại phân loại trên đám mây**. Vault không tự đổi nhà cung cấp; mỗi connection có chu kỳ retry và giới hạn lần thử riêng. Sửa thẻ trong tiện ích trình duyệt: nhấn **+ tag**, tìm và chọn để thêm; dùng nút xóa hoặc chọn thẻ rồi nhấn Delete một lần để xóa. **Chưa gắn thẻ** nghĩa là tagging xong nhưng không có thẻ; **Đang gắn thẻ** nghĩa là kết quả đang chờ. Sửa đổi của bạn có hiệu lực cho mục đó.

## Hoạt động

Hoạt động ghi cục bộ việc dùng ứng dụng đã bật, lượt truy cập trang web và **Nội dung đã xem** được hỗ trợ. Biểu đồ phản ánh dữ liệu đã ghi; khoảng trống không chứng minh Mac không hoạt động. Chọn khoảng ngày. **Dòng thời gian** hiển thị theo giờ trong ngày; **Tổng** cộng thời lượng; **Khoảng thời gian** gom hoạt động mỗi khoảng thành khối dọc. **Màu sắc** là chú giải có thể nhấp; chọn nguồn để tập trung biểu đồ. Chọn ngày để xem từ ngày đó.

### Nhóm Hoạt động

Tạo nhóm để hiển thị chung ứng dụng và trang web đã chọn trong Usage. **Merge** dùng chung một tên và màu cho các thành viên trên Hoạt động. Nhóm Hoạt động sắp xếp hoạt động đã ghi và tách biệt với nhóm chặn và Gắn thẻ nội dung. Lưu trình chỉnh sửa bằng **Save**.

### Ghi và lưu giữ

Trong **Ghi dữ liệu**, bật/tắt ghi theo danh mục hoặc nguồn riêng. **Lưu giữ** đặt thời gian lưu lịch sử; **Mãi mãi** không tự hết hạn. Lựa chọn riêng có thể theo cài đặt rộng hơn. Tắt ghi sẽ dừng bản ghi mới; xóa lịch sử xóa mục đã ghi. Feed nền tảng thu thập nội dung hiển thị trên trang được hỗ trợ dù trang đã mở hay chưa. Feed **Hỗ trợ gắn thẻ** có thể cung cấp nội dung cho Gắn thẻ nội dung khi đang ghi. Thời hạn lưu feed tách biệt khỏi việc dùng ứng dụng và trang web. Tạm dừng nhóm tagging không tự dừng ghi.

## Cài đặt

Chọn ngôn ngữ giao diện trong Cài đặt. Nút Info cung cấp giải thích trường bằng ngôn ngữ đã chọn.

## Lưu và khắc phục sự cố

Sửa đổi thường ngày của Vault và Gắn thẻ nội dung tự lưu; trình chỉnh sửa Hoạt động group cần **Save**. Thêm, xóa, kiểm tra kết nối và lấy danh sách model là thao tác rõ ràng. Nếu thiếu thẻ, kiểm tra kết nối trình duyệt, công tắc tagging chung, trạng thái tạm dừng, ghi nền tảng, connection/model đã chọn và thông tin xác thực. Khi yêu cầu AI lỗi, kiểm tra thêm giới hạn nhà cung cấp và Log nhóm. Nếu không sửa được nhóm liên kết, kết nối lại chương trình hoặc bỏ freeze theo hướng dẫn.
