# Hướng dẫn sử dụng Mac Vault

Mac Vault có ba trang: **Vault** chặn ứng dụng native, **Bộ phân loại** gắn thẻ nội dung trình duyệt được hỗ trợ và **Activity** hiển thị mức sử dụng đã ghi nhận. Tiện ích trình duyệt thu thập nội dung được hỗ trợ và áp dụng việc chặn trong trình duyệt. Cài đặt và kết nối tiện ích trong trình duyệt bạn sử dụng.

## Bắt đầu nhanh

1. Trong **Vault**, thêm nhóm chặn và mục tiêu Apps, sau đó chọn ứng dụng bằng bộ chọn +.
2. Chọn hành vi chặn của nhóm và bật nhóm.
3. Trong **Bộ phân loại**, tạo nhóm, chọn nền tảng rồi thêm thẻ kèm mô tả.
4. Chọn cấp mô hình cục bộ và tải xuống nếu cần. Bật gắn thẻ trong Cài đặt và tiếp tục nhóm.
5. Mở nội dung được hỗ trợ trong trình duyệt đã kết nối. Cấu hình bộ lọc thẻ trong nhóm chặn của trình duyệt nếu muốn thẻ điều khiển việc chặn.

## Nhóm chặn

**Nhóm chặn** áp dụng chính sách chặn. **Nhóm phân loại** gắn thẻ cho nội dung; bản thân nhóm này không chặn gì.

1. Thêm một nhóm chặn và đặt tên.
2. Chọn mục tiêu trong **Áp dụng cho**.
3. Chọn thời điểm áp dụng chặn, rồi đặt lịch hoặc thời lượng cho phép nếu cần.
4. Bật nhóm. Các mục tiêu của nhóm dùng chung chính sách đó.

Các chỉnh sửa thông thường được lưu tự động. Nếu có lỗi, chỉnh sửa chưa được chấp nhận; hãy sửa trường đó rồi thử lại. Tắt nhóm để ngừng chính sách nhưng giữ cấu hình. **Xóa nhóm** sẽ xóa nhóm. Kéo nhóm để sắp xếp lại. Nhiều nhóm có thể áp dụng cho cùng mục tiêu; hoãn một nhóm không gỡ chặn của nhóm khác.

**Xuất** sao chép cấu hình nhóm. **Nhập** thay thế cấu hình của nhóm đã chọn sau khi xác nhận.

### Thời lượng cho phép và lịch

**Chặn ngay** áp dụng bất cứ khi nào nhóm đang bật khớp và lịch của nhóm có hiệu lực. **Chặn khi hết thời lượng cho phép** cho phép sử dụng nội dung khớp cho đến khi thời lượng cho phép cạn.

Đặt thời lượng cho phép theo phút và chu kỳ đặt lại theo giờ. Giới hạn trượt tính mức sử dụng trong khoảng thời gian ngay trước đó. Đặt lại lúc nửa đêm sẽ bắt đầu chu kỳ mới vào nửa đêm theo giờ địa phương, kể cả với giới hạn trượt.

Chọn các ngày trong tuần cần hoạt động và các khung giờ địa phương tùy chọn, mỗi dòng một khung, chẳng hạn **09:00-12:00**. Nếu không có khung giờ, lịch áp dụng suốt các ngày đã chọn. Giờ kết thúc phải muộn hơn giờ bắt đầu trong cùng ngày; hãy tách lịch qua đêm thành các ngày riêng.

### Hoãn

Cấu hình hoãn trong từng nhóm chặn. **Tạm dừng chặn** đình chỉ chính sách của nhóm trong thời lượng tạm dừng. **Cộng vào thời lượng cho phép** thêm phút sử dụng được cho nhóm giới hạn thời gian. Chỉ phần thời lượng cộng thêm đã dùng mới được tính là thời gian hoãn. Thời lượng cộng thêm chưa dùng sẽ hết hạn vào lần đặt lại kế tiếp; với giới hạn trượt, hết hạn sau một cửa sổ hoặc sớm hơn vào nửa đêm nếu bật tùy chọn đó.

**Độ trễ kích hoạt** hoãn yêu cầu hoãn trong khi việc chặn vẫn tiếp tục. **Thời gian chờ** là khoảng chờ sau khi hết hoãn trước lần yêu cầu tiếp theo. **Số lần xác nhận bắt buộc** đặt số bước xác nhận. Chỉ có thể hoãn nhóm đã khóa nếu cho phép trước khi khóa.

### Khóa và PIN

**Khóa** ngăn chỉnh sửa thông thường. Mở khóa cần mười lần xác nhận, cách nhau năm giây, cùng thời gian chờ đã đặt và PIN sáu chữ số. **Chờ trước khi mở khóa** nhận giá trị 0–72 giờ; 0 nghĩa là không chờ thêm.

Khi đang khóa, có thể kéo dài thời gian chờ và thêm PIN nếu chưa có. Không thể nới lỏng các điều kiện đó cho đến khi mở khóa nhóm. Xóa nhóm cũng phải tuân thủ thời gian chờ còn lại và PIN.

### Nhóm được liên kết

Dùng **Liên kết** để nối các nhóm được chọn rõ ràng trong những chương trình Vault khác. Các nhóm được liên kết dùng chung tên, cài đặt chính sách được hỗ trợ, mục tiêu, mức sử dụng và điều kiện khóa. Mỗi chương trình chỉnh sửa và thực thi các loại mục tiêu mà chương trình đó hỗ trợ; các mục tiêu loại khác vẫn có sẵn cho chương trình liên kết. Hủy liên kết vẫn giữ từng nhóm và cài đặt của nhóm.

Nếu thành viên được liên kết ngoại tuyến, có thể không chỉnh sửa được. Mở Mac Vault và trình duyệt đã liên kết để kết nối lại. Chính sách đã lưu cục bộ có thể tiếp tục áp dụng khi thành viên ngoại tuyến.

## Trợ giúp

Nhấp vào chữ **i** nhỏ bên cạnh trường để xem giải thích. Nhấp bên ngoài hoặc nhấn Escape để đóng. Danh sách nằm trong các hộp có thể cuộn; cuộn trong hộp để xem thêm mục. Tìm kiếm lọc danh sách đang hiển thị mà không xóa mục nào.

Quy tắc tùy chỉnh có [Hướng dẫn mã](../code-manual/vi.md) riêng. Hướng dẫn giải thích trình chỉnh sửa, kích hoạt, nhật ký, truy cập tệp và API được hỗ trợ.

## Ứng dụng native

Dùng bộ chọn + của mục tiêu Apps để chọn ứng dụng đã cài đặt. **Chặn mọi ứng dụng ngoại trừ các ứng dụng này** biến danh sách thành allowlist. Ứng dụng hệ thống, trình duyệt và chính Vault không bị chặn ở cấp native.

Ứng dụng bị chặn sẽ được yêu cầu thoát. **Yêu cầu ứng dụng bị chặn thoát lại sau mỗi (phút)** điều khiển việc thử lại. Chuyển hướng trang web, tạm dừng trang và ẩn feed do tiện ích trình duyệt thực thi; chúng không trở thành thao tác native của ứng dụng.

## Bộ phân loại

Nhóm phân loại gắn thẻ nội dung từ nền tảng được giao, bằng cây thẻ và cài đặt mô hình riêng. Mỗi nền tảng thuộc về một nhóm. Chọn nền tảng khi tạo nhóm; không thể đổi sau đó. Lịch và bộ lọc của nhóm chặn không điều khiển việc gắn thẻ.

Bật gắn thẻ trong Cài đặt. Dùng riêng **Tạm dừng gắn thẻ / Tiếp tục gắn thẻ** cho mỗi nhóm. Tắt ghi nhận feed nền tảng trong **Activity → Ghi nhận** cũng sẽ dừng việc gắn thẻ của feed đó.

### Thẻ và cài đặt mô hình

Tạo thẻ, mô tả ý nghĩa, đặt hoặc gỡ thẻ cha trong cây thẻ. Kéo thẻ để chuyển nhánh. Mô tả rõ ràng giúp mô hình phân biệt các thẻ tương tự. Cài đặt của từng nhóm độc lập.

- **Tốc độ ↔ Chất lượng** chọn cấp mô hình cục bộ. Mô hình lớn dùng nhiều bộ nhớ hơn; tốc độ và kết quả tùy thuộc Mac và khối lượng công việc. Các nhóm dùng chung tệp tải xuống.
- **Nghiêm ngặt ↔ Mở rộng** đặt yêu cầu độ tin cậy và số lượng thẻ mặc định.
- **Thẻ tối thiểu / Thẻ tối đa** trong Thêm sẽ thay các số lượng mặc định đó. Nghiêm ngặt ↔ Mở rộng vẫn kiểm soát độ tin cậy của thẻ bổ sung. Để trống trường nào để dùng giá trị mặc định của trường đó.
- **Hướng dẫn gắn thẻ** thêm chỉ dẫn tùy chọn cho nhóm này.

Các chỉnh sửa thông thường trong bộ phân loại được lưu tự động. Cấp đã chọn phải được tải xuống trước khi gắn thẻ nội dung. Các nhóm dùng cùng cấp chia sẻ mô hình đã tải; tối đa hai cấp được giữ tải cùng lúc.

Sửa thẻ của mục nội dung trong tiện ích trình duyệt. Nhấp **+ thẻ**, tìm thẻ hiện có trong bộ phân loại rồi chọn để thêm. Dùng nút xóa của thẻ hoặc chọn thẻ rồi nhấn Delete một lần để gỡ. **Chưa gắn thẻ** nghĩa là gắn thẻ đã hoàn tất nhưng không có thẻ; **Đang gắn thẻ** nghĩa là kết quả đang chờ. Các chỉnh sửa giúp cải thiện lần gắn thẻ sau.

## Knowledge và nghiên cứu web

Knowledge lưu mô tả ngắn trên Mac này cho mô hình gắn thẻ cục bộ. **Nguồn nội dung** gồm nhà sáng tạo, tài khoản, kênh và cộng đồng. Mô tả nguồn đi cùng nội dung của nguồn đó. **Thuật ngữ đã biết** áp dụng khi thuật ngữ xuất hiện trong tiêu đề.

Thêm nguồn hoặc thuật ngữ cùng mô tả, hoặc để trống mô tả để yêu cầu nghiên cứu khi bật tính năng. Gợi ý nhà sáng tạo giúp tìm nguồn mà bộ phân loại đã thu thập. Danh sách có ít nhất sáu mục có ô tìm kiếm ngay phía trên: Terms và Content sources của từng nền tảng có ô riêng để tìm theo tên, mã định danh hoặc mô tả. Sửa mô tả ảnh hưởng đến lần gắn thẻ sau; xóa kiến thức nguồn không ngăn nghiên cứu tạo lại sau này.

### Cấu hình nhà cung cấp nghiên cứu

1. Mở **Cài đặt → API keys & providers**.
2. Chọn loại nhà cung cấp và **Thêm nhà cung cấp**. Thao tác này tạo cấu hình, không cấp API key.
3. Lấy thông tin xác thực từ nhà cung cấp đó rồi nhập vào. Với endpoint tùy chỉnh tương thích, cấu hình thêm các trường endpoint và protocol.
4. Trong **Nghiên cứu web**, chọn nhà cung cấp có web search tích hợp. Lấy danh sách mô hình rồi chọn mô hình nghiên cứu. Dùng ô tìm kiếm của bộ chọn mô hình để thu hẹp danh sách; làm mới để lấy lại danh sách.
5. Đọc thông báo đồng ý và bật chấp thuận. Trong mỗi nhóm, chọn **Bật**, **Tắt** hoặc **Theo Cài đặt**.

**Thiết lập nghiên cứu web…** mở cài đặt khi thiếu cấu hình. Nhóm không thể bỏ qua yêu cầu đồng ý nghiên cứu. **Kiểm tra kết nối** xác nhận yêu cầu thử đã thành công, không xác nhận mọi mô hình đều hỗ trợ nghiên cứu. Mô hình thử của nhà cung cấp khác với mô hình nghiên cứu đã chọn.

Keys lưu trong thư mục support của ứng dụng trên Mac này, không phải system Keychain. Chúng xác thực yêu cầu gửi đến nhà cung cấp đã cấu hình; Vault không tải chúng lên máy chủ riêng. Nghiên cứu gửi các chủ đề công khai đã được làm sạch đến nhà cung cấp đã chọn, không gửi phần thân nội dung riêng tư hay bản tóm tắt. Đọc thông báo đồng ý để biết chính xác fields được gửi. Mức sử dụng nhà cung cấp tính cả kiểm tra kết nối và yêu cầu danh sách mô hình, ngoài nghiên cứu.

Trạng thái nghiên cứu hiển thị yêu cầu đang chờ, thời gian chờ thử lại, lỗi và lượng token sử dụng trong ngày. **Thử lại ngay các chủ đề lỗi** thử lại các lỗi đủ điều kiện; thao tác này không bỏ qua hạn mức ngày hoặc yêu cầu đồng ý.

## Activity

Activity ghi cục bộ việc sử dụng ứng dụng đã bật, lượt truy cập trang web và **Nội dung đã xem** được hỗ trợ. Biểu đồ phản ánh dữ liệu đã ghi; vùng trống không chứng minh Mac đã không hoạt động.

Chọn khoảng ngày. **Dòng thời gian** hiển thị mức sử dụng theo thời điểm trong ngày; **Tổng** cộng thời lượng. **Khoảng thời gian** gộp mức sử dụng trong mỗi khoảng thành các khối dọc. **Màu sắc** là chú giải có thể nhấp: chọn nguồn để tập trung biểu đồ vào nguồn đó. Chọn ngày để xem hoạt động từ ngày ấy.

### Nhóm Activity

Tạo nhóm để hiển thị các ứng dụng và trang web đã chọn cùng nhau trong Usage. **Gộp** dùng chung tên và màu cho các thành viên trên toàn Activity. Nhóm Activity sắp xếp mức sử dụng đã ghi nhận; nhóm này tách biệt với nhóm chặn hoặc nhóm phân loại. Lưu trình chỉnh sửa nhóm Activity bằng nút **Lưu**.

### Ghi nhận và lưu giữ

Trong **Ghi nhận**, bật hoặc tắt việc ghi theo từng danh mục hay nguồn riêng lẻ. **Giữ lại** kiểm soát thời gian lưu lịch sử; **Vĩnh viễn** giữ mà không tự hết hạn. Lựa chọn riêng có thể theo cài đặt rộng hơn. Tắt ghi nhận ngừng lưu dữ liệu mới; xóa lịch sử sẽ xóa các mục đã ghi.

Feed nền tảng thu thập nội dung hiển thị trên trang nền tảng được hỗ trợ, dù đã mở hay chưa. Feed có nhãn **Hỗ trợ gắn thẻ** có thể cung cấp dữ liệu cho bộ phân loại khi đang bật ghi nhận. Lưu giữ của feed kiểm soát nội dung đã thu thập riêng với mức sử dụng ứng dụng/trang web. Tạm dừng nhóm phân loại không tự tắt ghi nhận.

## Cài đặt

Chọn ngôn ngữ giao diện trong Settings. Có thể xem giải thích trường qua các nút Info nhỏ bằng ngôn ngữ giao diện đã chọn.

## Lưu và khắc phục sự cố

Các chỉnh sửa thông thường trong Vault và bộ phân loại được lưu tự động. Chỉnh sửa nhóm Activity cần **Lưu**. Thêm, xóa, tải mô hình, thử kết nối và lấy danh sách mô hình vẫn là thao tác chủ động.

Nếu thiếu thẻ, kiểm tra kết nối trình duyệt, công tắc gắn thẻ toàn cục, trạng thái tạm dừng nhóm, ghi nhận nền tảng và tải mô hình. Nếu nghiên cứu không chạy, kiểm tra đồng ý, lựa chọn nhóm, thông tin xác thực nhà cung cấp, mô hình nghiên cứu và trạng thái nghiên cứu. Nếu không chỉnh sửa được nhóm liên kết, kết nối lại các chương trình hoặc mở khóa như được hướng dẫn.
