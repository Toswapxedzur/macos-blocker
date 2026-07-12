# Hướng dẫn phát hành Mac Vault

Hướng dẫn này tuân theo các tập lệnh xây dựng đã đăng ký. Nó cố ý không chứa danh tính ký tên cá nhân, hồ sơ công chứng, mật khẩu hoặc dữ liệu tài khoản.

## Trước khi phát hành

1. Chạy `swift test` từ thư mục gốc của kho lưu trữ.
2. Đặt phiên bản phát hành và số bản dựng trong cấu hình dự án/bản dựng được kiểm soát.
3. Xem lại hướng dẫn sử dụng tiếng Anh, hướng dẫn sử dụng đã bản địa hóa và kiểm tra bản dịch của biên tập viên.
4. Xác minh chính sách nhánh phát hành, thẻ và cột mốc trước khi xuất bản một tạo phẩm.

## Đường dẫn DMG của trang web

Các tập lệnh tồn tại trong `scripts/release/`. Giá trị mặc định của chúng có thể được ghi đè bằng các biến môi trường, bao gồm `APP_NAME`, `BUNDLE_ID`, `TEAM_ID`, `SIGNING_IDENTITY`, `NOTARY_PROFILE`, `VERSION` và `BUILD_NUMBER`.

Chỉ chạy đường dẫn hoàn chỉnh trên máy ký được định cấu hình:

```bash
VERSION=<version> BUILD_NUMBER=<build> scripts/release/full_release_dmg.sh
```

Quy trình này bao gồm các tập lệnh xây dựng, ký, DMG, công chứng và xác minh hiện có. Hãy coi đầu ra của nó như một ứng cử viên phát hành cho đến khi bước xác minh thành công.

## Mục tiêu phân phối Xcode

Tạo dự án Xcode từ `XcodeProject/project.yml`, định cấu hình nhóm ký và khả năng phù hợp trong môi trường được phê duyệt, sau đó lưu trữ mục tiêu liên quan. Không cam kết thông tin xác thực đã tạo, tệp cung cấp hoặc hồ sơ công chứng.

## Sau khi phát hành

1. Tạo thẻ phiên bản bất biến và nhánh phát hành vĩnh viễn theo chính sách quản lý phát hành.
2. Xuất bản tạo phẩm phát hành và tổng kiểm tra.
3. Chỉ cập nhật sổ đăng ký phát hành công khai sau khi URL giả tạo là cuối cùng.
4. Giữ ghi chú phát hành bằng tiếng Anh trừ khi có ghi chú phát hành đã bản địa hóa được đánh giá.
