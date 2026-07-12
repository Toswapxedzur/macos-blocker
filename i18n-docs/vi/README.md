# Mac Vault

Mac Vault là thành viên macOS gốc của dòng sản phẩm Vault. Nó kết hợp công cụ chính sách Swift, trình soạn thảo WebView, bộ điều hợp thực thi và kiểm kê ứng dụng gốc, hỗ trợ quy tắc tùy chỉnh và trung tâm cầu nối ứng dụng web cục bộ.

Mã hiện tại là nguồn gốc của sự thật. Tài liệu tham khảo trong ứng dụng bằng tiếng Anh là [Sources/MacBlockerWebUI/WebAssets/manual/en.md](Sources/MacBlockerWebUI/WebAssets/manual/en.md).

## Những gì được thực hiện

- Nhóm mặc định cho các ứng dụng macOS đã chọn và Nhóm tùy chỉnh cho các quy tắc chính sách nâng cao.
- Chế độ chặn ngay lập tức, trợ cấp và đếm ngược.
- Lịch trình, chế độ đóng băng, luồng báo lại, nhập/xuất và trạng thái nhóm liên tục.
- Kiểm kê ứng dụng, trạng thái cấp phép kiểm soát thiết bị, bộ điều hợp thực thi gốc và bề mặt trạng thái nổi.
- Thời gian chạy chính sách JavaScript được kiểm soát bằng tính năng ghi nhật ký và kiểm tra cú pháp.
- Một trung tâm cầu nối WebSocket loopback dành cho các nhóm tương thích được liên kết rõ ràng.
- Trình chỉnh sửa WebView có cùng mô hình nhóm cốt lõi với dòng sản phẩm Vault.

## Phát triển

Chạy thử nghiệm gói Swift:

```bash
swift test
```

Gói này bao gồm các thử nghiệm chính sách cốt lõi, lịch trình, quy tắc tùy chỉnh, cầu nối, nhập và kiểm soát macOS.

## dự án Xcode

Dự án Xcode tùy chọn được tạo từ [XcodeProject/project.yml](XcodeProject/project.yml):

```bash
cd XcodeProject
./generate.sh
```

Đọc [XcodeProject/README.md](XcodeProject/README.md) trước khi định cấu hình mục tiêu ký hoặc phân phối.

## Chính sách tài liệu

Tài liệu tiếng Anh vẫn còn kinh điển. Giao diện người dùng của trình soạn thảo có các danh mục ngôn ngữ hoàn chỉnh, các sách hướng dẫn đã dịch nằm bên cạnh `WebAssets/manual/en.md` và bản dịch của các tài liệu được duy trì còn lại nằm ở `i18n-docs/<locale>/`.

Các điều khoản pháp lý và thông báo về quyền riêng tư vẫn là các tài liệu pháp lý riêng biệt; README này không thay thế chúng.
