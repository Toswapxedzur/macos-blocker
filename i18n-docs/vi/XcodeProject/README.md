#dự án Mac Vault Xcode

`project.yml` là thông số XcodeGen đã được đăng ký cho các mục tiêu macOS và iOS sử dụng gói Swift được chia sẻ.

## Tạo dự án

```bash
cd XcodeProject
./generate.sh
open macosBlocker.xcodeproj
```

Tái tạo sau khi thay đổi `project.yml`, mục tiêu, quyền lợi hoặc tư cách thành viên nguồn. Không sử dụng các tệp dự án được tạo làm cấu hình chuẩn.

## Các gia đình mục tiêu hiện tại

- `AdamanciaVaultMac` là mục tiêu ứng dụng macOS được hỗ trợ bởi `MacBlockerAppFeature`.
- `macosBlocker` là mục tiêu ứng dụng iOS.
- Dự án iOS bao gồm các tiện ích mở rộng Hoạt động thiết bị, Cấu hình khiên và Hành động khiên.

Mã định danh hiện tại, mục tiêu triển khai, trường phiên bản và khả năng được xác định trong `project.yml` và các tệp quyền được tham chiếu. Xem lại chúng trong môi trường ký kết trước khi phân phối.

## Ký kết và khả năng

Sử dụng số nhận dạng nhóm và gói thuộc về tài khoản phân phối. Xác nhận các khả năng mà mục tiêu bạn đang xây dựng yêu cầu. Không bao giờ thêm bí mật ký, hồ sơ cung cấp hoặc thông tin xác thực tài khoản vào kho lưu trữ này.

## Kiểm tra trước

Chạy thử nghiệm gói chia sẻ trước khi tạo bản lưu trữ:

```bash
cd ..
swift test
```
