# Chính sách quyền riêng tư của Adamancia Vault

Cập nhật lần cuối: ngày 7 tháng 7 năm 2026

Adamancia Vault là một ứng dụng tập trung và chặn. Chính sách này mô tả việc phát hành ứng dụng macOS.

## Tóm tắt

Adamancia Vault được thiết kế để duy trì các quy tắc chặn và trạng thái sử dụng cục bộ trên máy Mac của bạn theo mặc định. Ứng dụng không bán dữ liệu cá nhân, không hiển thị quảng cáo và không chia sẻ dữ liệu cá nhân với nhà môi giới dữ liệu.

## Dữ liệu được lưu trữ cục bộ

Ứng dụng có thể lưu trữ dữ liệu cục bộ sau trên máy Mac của bạn:

- Chặn nhóm, lịch trình, bộ hẹn giờ, trạng thái đóng băng/báo lại và cài đặt ứng dụng.
- Bộ nhớ trình soạn thảo web cục bộ được phản chiếu từ giao diện web đi kèm.
- Trạng thái liên kết/cầu nối cục bộ khi bạn kết nối ứng dụng macOS với tiện ích mở rộng trình duyệt.
- Các tệp chính sách thực thi ứng dụng được công cụ chặn macOS sử dụng.
- Dữ liệu vùng chứa Nhóm ứng dụng khi bản dựng App Store hoặc bản dựng tiện ích mở rộng sử dụng Nhóm ứng dụng.

Các đường dẫn cục bộ đã biết được ghi lại trong `RELEASE.md` và trong tập lệnh trình gỡ cài đặt.

## Sử dụng mạng

Ứng dụng có thể mở trình nghe mạng cục bộ cho cầu nối ứng dụng web để tiện ích mở rộng trình duyệt có thể kết nối với ứng dụng Mac. Ứng dụng cũng có thể thực hiện các yêu cầu mạng nếu một tính năng đi kèm cần liên lạc với các dịch vụ của Adamancia, chẳng hạn như tài khoản tùy chọn hoặc các tính năng liên quan đến đồng bộ hóa.

## Phân tích và Quảng cáo

Ứng dụng macOS không bao gồm SDK quảng cáo của bên thứ ba. Nó không nên gửi phân tích trừ khi một tính năng cho biết rõ ràng rằng nó đang sử dụng dịch vụ trực tuyến.

## Tài khoản tùy chọn và đồng bộ hóa

Nếu các tính năng tài khoản hoặc đồng bộ hóa được bật trong một bản phát hành thì các tính năng đó có thể gửi dữ liệu tối thiểu cần thiết để cung cấp tính năng đó, chẳng hạn như nhận dạng tài khoản và tải trọng đồng bộ hóa. Tải xuống và chặn cục bộ không được yêu cầu tài khoản.

## Quyền

Tùy thuộc vào kênh và các tính năng được bật, Adamancia Vault có thể yêu cầu macOS cấp các quyền như Trợ năng, quyền truy cập mạng, đăng ký mục đăng nhập hoặc quyền truy cập Nhóm ứng dụng. Các quyền này được sử dụng để cung cấp các tính năng chặn, khởi chạy ứng dụng, cầu nối và duy trì.

## Đang gỡ cài đặt

DMG bao gồm `uninstall.command`. Nó yêu cầu xác nhận, thoát khỏi ứng dụng nếu đang chạy, hủy đăng ký mục đăng nhập của ứng dụng khi có thể, xóa `/Applications/AdamanciaVault.app` và tùy chọn chỉ xóa các tệp đã biết do ứng dụng này tạo.

## Liên hệ

Đối với các câu hỏi về quyền riêng tư, hãy mở một vấn đề trong kho lưu trữ GitHub công khai hoặc sử dụng kênh liên hệ được xuất bản trên trang web Adamancia Vault.
