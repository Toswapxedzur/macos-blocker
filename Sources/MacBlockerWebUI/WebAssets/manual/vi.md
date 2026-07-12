# Tham khảo chức năng của ứng dụng máy tính để bàn Vault

## Mục đích và ranh giới

Đây là tài liệu tham khảo chính thức cho giao diện ứng dụng máy tính để bàn Vault. Nó được cố ý tách biệt khỏi hướng dẫn sử dụng tiện ích mở rộng trình duyệt Vault.

Ứng dụng dành cho máy tính để bàn quản lý ** ứng dụng gốc và cửa sổ ứng dụng **. Tiện ích mở rộng trình duyệt quản lý các trang web, tab trình duyệt và nguồn cấp dữ liệu nền tảng web được hỗ trợ. Chúng có chung ý tưởng—nhóm, lịch trình, bộ tính giờ, tạm dừng, báo lại, quy tắc tùy chỉnh và cầu nối tùy chọn—nhưng chúng không có cùng bề mặt thực thi.

Sử dụng tài liệu này để định cấu hình, kiểm tra, tái tạo hoặc duy trì hoạt động của ứng dụng dành cho máy tính để bàn. Mã này là chuẩn nếu việc triển khai và hướng dẫn này khác nhau.

## 1. Ứng dụng desktop có thể và không thể kiểm soát những gì

Vault đánh giá chính sách trọng tâm cho các ứng dụng gốc đã chọn. Khi có sẵn khả năng thực thi gốc, nó có thể áp dụng kế hoạch hiện tại để phù hợp với các mục tiêu ứng dụng và báo cáo kết quả lá chắn/trạng thái cho giao diện người dùng máy chủ.

Nó có thể:

- tạo, kích hoạt, vô hiệu hóa, sắp xếp lại, nhập, xuất, đóng băng, báo lại và xóa nhóm;
- nhắm mục tiêu các ứng dụng gốc được chọn thông qua bộ chọn ứng dụng;
- áp dụng khối ngay lập tức, trợ cấp theo thời gian hoặc bộ đếm thời gian chỉ đếm ngược;
- giới hạn các nhóm bình thường vào các ngày trong tuần và khung giờ địa phương;
- chạy các quy tắc chính sách JavaScript tùy chỉnh cho các sự kiện trong vòng đời ứng dụng;
- hiển thị thông tin bảng/trạng thái gốc do quy tắc tạo thông qua máy chủ;
- quản lý một thư mục cục bộ tùy chọn cho các yêu cầu tệp Quy tắc tùy chỉnh được hỗ trợ;
- tham gia các nhóm được liên kết rõ ràng tương thích thông qua cầu Vault cục bộ.

Nó không thể:

- hoạt động như một tiện ích mở rộng của trình duyệt, kiểm tra DOM của trang web hoặc thao tác với thẻ nguồn cấp dữ liệu của trình duyệt;
- đảm bảo rằng hệ điều hành sẽ cho phép kiểm soát mọi ứng dụng, quy trình, cửa sổ hoặc dịch vụ hệ thống;
- biến việc lựa chọn ứng dụng thành quản trị từ xa, giám sát thiết bị hoặc tường lửa;
- làm cho các trình trợ giúp Tùy chỉnh chỉ dành cho trình duyệt như DOM, điều hướng, chuyển hướng hoặc kiểm soát tab hoạt động trong thời gian chạy gốc;
- tự động đồng bộ hóa mọi nhóm chỉ vì cầu nối cục bộ đang chạy.

## 2. Từ vựng

| Kỳ hạn | Ý nghĩa |
| --- | --- |
| Nhóm | Một đối tượng chính sách tập trung được đặt tên. Tên nhóm phải là duy nhất trong điểm cuối Vault hiện tại. |
| Mục tiêu | Danh tính ứng dụng gốc được chọn cho một nhóm. |
| Nhóm ứng dụng mặc định | Một nhóm bình thường có mục tiêu là các ứng dụng gốc từ bộ chọn ứng dụng. |
| Custom group | A group whose JavaScript rule reacts to application-policy events. |
| Trận đấu | Ứng dụng nền trước/đang chạy hiện tại khớp với mục tiêu nhóm đã bật và đang hoạt động hoặc điều kiện Quy tắc tùy chỉnh. |
| Đang hoạt động | Đã bật, trong lịch trình bình thường và không được tạm ẩn. |
| Kế hoạch thực thi | Quyết định cho phép/bảo vệ/trạng thái của máy chủ gốc sau khi đánh giá các nhóm có thể áp dụng. |
| Đóng băng | Bảo vệ chống lại sự sửa đổi thông thường của một nhóm. |
| Báo lại | Một ngoại lệ tạm thời đối với chính sách nhóm thông thường. |

## 3. Nhận dạng mục tiêu và chọn ứng dụng

Chọn ứng dụng thông qua bộ chọn **++** trong nhóm ứng dụng Mặc định. Vault lưu trữ danh tính chuẩn hóa cũng như tên hiển thị.

| Máy chủ | Nhận dạng mục tiêu được sử dụng để khớp |
| --- | --- |
| macOS | Mã định danh gói ứng dụng nếu có. |
| Windows | Đường dẫn thực thi hoặc tên quy trình được chuẩn hóa do bộ chọn ứng dụng cung cấp. |

Tên hiển thị dành cho người biên tập. Giá trị chuẩn hóa là danh tính được lớp thực thi gốc sử dụng. Đổi tên ứng dụng trong giao diện người dùng không thay đổi danh tính. Mục tiêu cũng có thể mang thẻ để sử dụng chính sách Quy tắc tùy chỉnh.

Không nhập URL trang web vào trường mục tiêu ứng dụng và yêu cầu thực thi ứng dụng gốc. Sử dụng Nhóm trang web của tiện ích mở rộng để chặn trang web.

## 4. Vòng đời và mức độ ưu tiên của nhóm

Một nhóm mới được bật theo mặc định. Danh sách nhóm hỗ trợ lựa chọn, bật/tắt, sắp xếp kéo, Thêm, Xóa, nhập, xuất và xóa. Nhóm đã chọn sẽ mở ra trong trình chỉnh sửa.

Các chỉnh sửa trường thông thường được lưu thông qua chính sách lưu tự động của người chỉnh sửa. Nhóm bị đóng băng sẽ vô hiệu hóa các điều khiển chỉnh sửa thông thường. Nguồn tùy chỉnh thì khác: việc lưu văn bản không làm cho nó hoạt động; **Run** là thao tác tải nguồn hiện tại vào thời gian chạy chính sách.

Một số nhóm có thể phù hợp với cùng một ứng dụng. Vault đánh giá chính sách nhóm theo thứ tự được lưu trữ và xây dựng kế hoạch thực thi gốc. Giữ sự chồng chéo có chủ ý, đặc biệt khi các nhóm sử dụng các chính sách theo thời gian khác nhau hoặc đưa ra các quyết định cho phép/bảo vệ quy tắc tùy chỉnh. Sắp xếp lại các nhóm để làm rõ mức độ ưu tiên dự định; không dựa vào việc giải quyết cấu hình xung đột theo cách thân thiện với người dùng cụ thể.

## 5. Nhóm ứng dụng thông thường

### 5.1 Trạng thái nhóm

| Lĩnh vực | Hợp đồng chức năng |
| --- | --- |
| Tên | Không trống, được cắt bớt, không phân biệt chữ hoa chữ thường trong điểm cuối này. |
| Đã bật | Các nhóm khuyết tật được giữ lại nhưng không tham gia thực thi thông thường. |
| Mục tiêu | Một hoặc nhiều danh tính ứng dụng được chọn từ bộ chọn. |
| Hành vi | Chặn ngay lập tức, chặn sau khi cho phép hoặc hẹn giờ/đếm ngược. |
| Lịch trình | Các ngày trong tuần được chọn và các cửa sổ giờ địa phương tùy chọn. |
| Đóng băng | Không có, Đông lạnh, Đông lạnh nghiêm ngặt, hoặc Đông lạnh từ cha mẹ. |
| Báo lại | Chính sách ngoại lệ tạm thời cho mỗi nhóm. |
| Thông báo dự phòng/trạng thái | Thông báo mà máy chủ gốc có thể hiển thị khi áp dụng phản hồi lá chắn/trạng thái. |

Nhóm Mặc định trống không có mục tiêu ứng dụng được chọn và do đó không khớp với ứng dụng chỉ theo hiện có.

### 5.2 Hành vi chặn

| Hành vi | Kết quả |
| --- | --- |
| Chặn ngay lập tức | Một mục tiêu hoạt động phù hợp sẽ tạo ra quyết định chặn/lá chắn gốc ngay lập tức. |
| Chặn sau vài phút | Việc sử dụng phù hợp sẽ được tích lũy theo phụ cấp nhóm. Khi hết hạn mức, nhóm sẽ đưa ra quyết định khối/lá chắn gốc cho đến khi thời gian sử dụng của nhóm được đặt lại hoặc trạng thái khác khiến nhóm không hoạt động. |
| Hẹn giờ (đếm ngược, không chặn) | Việc sử dụng phù hợp được đo lường và có thể được hiển thị, nhưng riêng bộ đếm thời gian đó không bao giờ tạo ra khối. |

Các nhóm mới sử dụng thời gian cho phép là 15 phút và khoảng thời gian đặt lại là 24 giờ trừ khi có thay đổi. Việc sử dụng theo thời gian thuộc về nhóm, vì vậy tất cả các mục tiêu phù hợp đều chia sẻ chính sách nhóm đó. Phản hồi chính xác đối với một khối được thực hiện bởi máy chủ gốc và bị hạn chế bởi các quyền của hệ điều hành và cơ chế thực thi được hỗ trợ.

### 5.3 Lịch trình

Lịch trình áp dụng cho nhóm bình thường. Nhóm Tùy chỉnh đưa ra quyết định về thời gian của riêng mình bằng JavaScript.

Chọn bất kỳ sự kết hợp nào từ Thứ Hai đến Chủ Nhật. Mỗi cửa sổ thời gian là một dòng theo giờ địa phương:

```text
0900-1200
1330-1730
```

Định dạng được chấp nhận chính xác là HHMM-HHMM. Giờ phải từ 00 đến 23, phút từ 00 đến 59 và thời điểm bắt đầu phải sớm hơn thời điểm kết thúc trong cùng ngày. Một cửa sổ bao gồm phần bắt đầu và loại trừ phần kết thúc của nó. Cửa sổ quá nửa đêm không được chấp nhận. Cửa sổ trống có nghĩa là toàn bộ ngày đã chọn.

Nhóm bình thường chỉ hoạt động khi:

1. nó được kích hoạt;
2. ngày trong tuần hiện tại được chọn;
3. giờ địa phương nằm trong cửa sổ được định cấu hình hoặc nhóm không có cửa sổ;
4. nó không ở trạng thái báo lại.

### 5.4 Tạm ẩn

Báo lại tạm thời loại bỏ một nhóm bình thường khỏi quá trình thực thi tích cực. Các giai đoạn của nó là:

| Giai đoạn | Kết quả |
| --- | --- |
| Đang chờ xử lý | Yêu cầu tồn tại nhưng độ trễ kích hoạt vẫn chưa trôi qua; nhóm vẫn hoạt động. |
| Đang hoạt động | Nhóm tạm thời không hoạt động trong thời gian báo lại. |
| Thời gian hồi chiêu | Thời gian báo lại đã kết thúc và nhóm đang hoạt động trở lại nhưng vẫn chưa có thời gian báo lại mới. |

| Cài đặt | Quy tắc |
| --- | --- |
| Cho phép báo lại | Khi tắt, nhóm không thể được báo lại bình thường. |
| Thời lượng báo lại | Số phút dương. Mặc định cho một nhóm mới là 30 phút. |
| Độ trễ kích hoạt | Không hoặc nhiều phút hơn trước khi chế độ báo lại hoạt động. |
| Thời gian hồi chiêu | Không đến năm phút sau khi thời gian báo lại đang hoạt động kết thúc. |
| Xác nhận | Toàn bộ số lượng tương tác xác nhận bắt buộc không âm. |

Báo lại hiện hoạt là một ngoại lệ chính sách tạm thời, không phải là xóa hoặc giải phóng. Cấu hình nhóm vẫn còn nguyên.

### 5,5 Đóng băng

Đóng băng là một rào cản sửa đổi có chủ ý.

| Chế độ | Hợp đồng |
| --- | --- |
| đông lạnh | Các chỉnh sửa thông thường và thay đổi trạng thái thông thường vẫn bị khóa cho đến khi quy trình xác nhận giải phóng sản phẩm thành công. |
| đông lạnh nghiêm ngặt | Nhóm không thể được đóng băng trước khi thời gian đóng băng nghiêm ngặt của nhóm kết thúc. Thời lượng là tích cực và giới hạn trong 72 giờ. |
| Cha mẹ đông lạnh | Cần phải quản lý mật khẩu người giám hộ cho các hành động đóng băng/hủy đóng băng. |

Việc chọn một chế độ trong trình chỉnh sửa không tự đóng băng nhóm; sử dụng hành động đóng băng để áp dụng nó. Một nhóm được liên kết với bridge cũng có thể khóa các điều khiển đóng băng phối hợp trong khi một thành viên được yêu cầu ngoại tuyến.

## 6. Thực thi gốc và kiểm soát thiết bị

Trình chỉnh sửa có thể lưu nhóm một cách chính xác ngay cả khi hệ điều hành chưa cấp khả năng thực thi nhóm đó. Luôn kiểm tra **Cài đặt → Kiểm soát thiết bị** và trạng thái gốc trực tiếp sau khi thay đổi quyền.

Máy chủ gốc quyết định những hành động nào có thể thực hiện được đối với hệ điều hành, ứng dụng, cửa sổ và trạng thái quyền hiện tại. Một quy tắc có thể được định cấu hình chính xác nhưng không có tác dụng rõ ràng khi:

- Quyền Kiểm soát Thiết bị không được cấp hoặc đã bị thu hồi;
- nhóm bị vô hiệu hóa, lên lịch hoặc chủ động tạm hoãn;
- quy trình tập trung không khớp với mục tiêu chuẩn hóa đã chọn;
- hệ điều hành từ chối một hành động cho mục tiêu đó;
- phần phụ thuộc cầu nối đang ngoại tuyến đối với một hành động yêu cầu trạng thái phối hợp.

Đừng coi việc chúc mừng lưu thành công là bằng chứng cho thấy có sẵn biện pháp thực thi tích cực. Kiểm tra mục tiêu đã chọn trong khi nhóm đang hoạt động và kiểm tra trạng thái máy chủ.

## 7. Nhóm tùy chỉnh và quy tắc chính sách gốc

Các nhóm tùy chỉnh chạy trong thời gian chạy chính sách JavaScript gốc. Chúng không phải là quy tắc tùy chỉnh của trình duyệt. DOM của trình duyệt, tab, điều hướng, chuyển hướng URL và hành vi kiểm soát nguồn cấp dữ liệu không được cung cấp một cách cố ý.

### 7.1 Vòng đời nguồn

Use a function expression:

```js
(events, helpers) => {
  events.on("focusEvent", "shield-focus", (event, h) => {
    if (event.target?.id) event.setResult(-1);
  });
}
```

Run loads the source and its event registrations. Running again unloads the old source and resets its rule-owned handlers, timers, panels, persistence, and dynamic app blocklist. A source that does not evaluate to a function cannot be loaded.

### 7.2 Sự kiện tích hợp sẵn

| Sự kiện | Ý nghĩa |
| --- | --- |
| đánh dấu sự kiện | Đánh dấu máy chủ định kỳ. Tùy chọn đăng ký intervalMs có thể giới hạn tốc độ của trình xử lý. |
| hẹn giờĐã kết thúc | Đếm ngược do quy tắc sở hữu đạt đến số 0. |
| báo lạiPress | Người dùng nhấn Bắt đầu báo lại cho nhóm Tùy chỉnh. |
| bảngSự kiện | Một điều khiển bảng tùy chỉnh được sử dụng. |
| localFileEvent | Một hành động thư mục cục bộ được yêu cầu đã hoàn tất. |
| openAppEvent | Một ứng dụng được theo dõi sẽ mở ra. |
| closeAppEvent | Một ứng dụng được theo dõi sẽ đóng lại. |
| sự kiện tập trung | Ứng dụng nền trước thay đổi thành một ứng dụng. |
| không tập trungEvent | Ứng dụng nền trước thay đổi khỏi một ứng dụng. |
| minimizeEvent / unminimizeEvent | Máy chủ báo cáo quá trình chuyển đổi thu nhỏ cửa sổ được hỗ trợ. |
| switchAppEvent | Ứng dụng nền trước thay đổi từ ứng dụng này sang ứng dụng khác. |
| appChangedEvent | Sự kiện thay đổi/vòng đời ứng dụng chung. |

Đối tượng sự kiện chứa loại, groupId/groupID, groupName, URL/tên máy chủ tương đương, thời gian, dữ liệu và mục tiêu. Đối với ứng dụng gốc, mục tiêu hiển thị id, loại, tên hiển thị, giá trị chuẩn hóa và thẻ khi mục tiêu tiêu điểm khớp với mục tiêu đã định cấu hình.

Dữ liệu sự kiện trong vòng đời của ứng dụng bao gồm id/tên ứng dụng hiện tại, tên nhóm, ảnh chụp nhanh ứng dụng đang chạy được tuần tự hóa và các giá trị dành riêng cho sự kiện như BundleId, previousAppId, currentAppId hoặc lý do thay đổi.

### 7.3 API sự kiện và các quyết định

Cơ quan đăng ký cung cấp bật/đăng ký, tắt/hủy đăng ký, unregisterAll, countRegistered, getEvent và getEvents. Ưu tiên cao hơn chạy trước; ưu tiên bằng nhau giữ nguyên thứ tự đăng ký. Sổ đăng ký có giới hạn xử lý cho mỗi nhóm.

Đối tượng sự kiện hỗ trợ:

| Phương pháp | Kết quả |
| --- | --- |
| setResult(-1) | Đưa ra quyết định về lá chắn/khối gốc. Kết quả chuỗi cũng trở thành khối gốc vì quy tắc trên máy tính để bàn không có mục tiêu chuyển hướng trình duyệt. |
| allow(lý do) hoặc setResult(1) | Đưa ra quyết định cho phép cho sự kiện này. |
| setShieldMessage(tin nhắn) | Đặt thông báo trạng thái/lá chắn đối diện với con người cho khối gốc. |
| stopPropagation() | Dừng các trình xử lý sau cho sự kiện hiện tại. |
| khối(appId), bỏ chặn(appId) | Thêm/xóa khối ứng dụng gốc động. |
| đóng(appId), mở(appId) | Yêu cầu hành động đóng/mở gốc được hỗ trợ. |
| bài viết(loại, dữ liệu) | Gửi một sự kiện Tùy chỉnh lồng nhau trong thời gian chạy gốc. |

Thời gian chạy ứng dụng cho phép tính giờ, tính ổn định, bảng điều khiển, nhật ký, thao tác thư mục cục bộ, trình trợ giúp cửa sổ ứng dụng và tiện ích phân loại URL. Nó cố tình coi các trình trợ giúp DOM, điều hướng, chuyển hướng và tab trình duyệt là không khả dụng/trơ.

### 7.4 Người giúp việc bản xứ

| Người trợ giúp | Hành vi bản địa |
| --- | --- |
| getLogHelper | Đưa ra các quyết định về nhật ký ứng dụng/cửa sổ bật lên/màn hình. |
| getTimerHelper | Tạo bộ đếm thời gian tiến/lùi với các giới hạn, bước, biến vị ngữ phạm vi/miền, tạm dừng/tiếp tục, kiểm tra trạng thái và chuyển đổi bộ hẹn giờĐã kết thúc. Bộ hẹn giờ không tự che chắn. |
| getPersistenceHelper | Trạng thái JSON của mỗi nhóm: nhận, đặt, xóa, có, khóa, mục nhập, xóa, kích thước. |
| getStorageHelper | Persistence cộng với phần giữ chỗ yêu cầu không đồng bộ của máy chủ; không giả định một phản hồi bên ngoài đồng bộ. |
| getWindowHelper | Đọc các ứng dụng hiện tại/đang chạy và yêu cầu các hành động đóng/mở/chặn/bỏ chặn ứng dụng. |
| getPanelHelper | Tạo ảnh chụp nhanh bảng gốc đã được xác thực, điều khiển, trình xử lý nội tuyến và phản hồi panelEvent. |
| getLocalFolderHelper | Hàng đợi cho phép các hoạt động .txt, .csv và .json tương đối dưới quyền gốc do người dùng cấp. Hoàn thành là localFileEvent. |
| getDomainHelper / getDomainUtility | Trình phân loại URL và nền tảng cho các quy tắc cũng có lý do về các giá trị giống URL. |
| getPlatformHelper/nền tảng | Trình phân loại URL vẫn có sẵn; Các lệnh gọi kiểm soát DOM/nguồn cấp dữ liệu gốc không hoạt động vì máy chủ dành cho máy tính để bàn không có DOM trang web. |

Bảng tùy chỉnh sử dụng từ vựng điều khiển khai báo giống như thời gian chạy của trình duyệt: văn bản, hộp kiểm, chọn, textInput, vùng văn bản, nút, phần, bộ đếm thời gian, numberInput, phạm vi, chuyển đổi, radio, ngày, giờ, màu sắc, mã pin và html đã được dọn dẹp. Máy chủ gốc quyết định số lượng bảng điều khiển có thể được hiển thị trên nền tảng hiện tại.

## 8. Thư mục tệp cục bộ

Thư mục Tệp Cục bộ là ranh giới tùy chọn, do người dùng cấp cho các quy tắc Tùy chỉnh. Các quy tắc có thể yêu cầu văn bản/CSV/JSON đọc, ghi, nối thêm, liệt kê, kiểm tra sự tồn tại và các hoạt động JSON. Đường dẫn luôn liên quan đến gốc đã chọn. Đường dẫn tuyệt đối, phân đoạn truyền tải, thành phần đường dẫn ẩn, phần mở rộng không được hỗ trợ và các hoạt động bên ngoài gốc đều bị từ chối.

Thu hồi thư mục khi một quy tắc không còn cần đến nó nữa. Một quy tắc phải xử lý các quyền không có sẵn và các kết quả localFileEvent không thành công; nó không được cho rằng thư mục đã chọn vẫn được ủy quyền sau khi khởi động lại.

##9. Cầu nối ứng dụng web

Cầu nối là sự đồng bộ hóa cục bộ tùy chọn giữa các chương trình Vault tương thích. Ứng dụng máy tính để bàn gốc có thể lưu trữ trung tâm cục bộ; khách hàng kết nối trên địa chỉ cục bộ được hỗ trợ.

Các trạng thái kết nối là Tắt, Đang kết nối, Đã ngắt kết nối, Đã kết nối/Đang chạy và Lỗi. Việc kết nối một chương trình không hợp nhất tất cả các nhóm. Người dùng phải liên kết rõ ràng các nhóm phù hợp đủ điều kiện.

Đối với liên kết nhóm:

1. Khởi động hub gốc trong Cài đặt.
2. Kết nối điểm cuối Vault tương thích khác.
3. Tạo các nhóm phù hợp, không cố định có cùng tên và loại.
4. Tại phần cầu nối nhóm chọn chương trình và kết nối nhóm.

Một nhóm liên kết tạo thành một cụm. Các giá trị chính sách chung được hỗ trợ, mức sử dụng và trạng thái báo lại có thể đồng bộ hóa trong khi các thành viên được kết nối. Việc ngắt kết nối sẽ tạm dừng đồng bộ hóa và duy trì các nhóm cục bộ. Các mục tiêu chỉ dành cho trình duyệt, hành động tùy chỉnh không được hỗ trợ và các trường dành riêng cho nền tảng không được đảm bảo chuyển.

## 10. Nhập, xuất, đặt lại và kiểm tra

Xuất lưu một đại diện nhóm tương thích. Nhập xác thực/chuẩn hóa dữ liệu nhóm tương thích và vẫn thực thi tính duy nhất của tên địa phương. Xóa nhóm sẽ xóa nhóm đã chọn và trạng thái liên kết của nó. Xóa xóa tất cả các nhóm sau khi xác nhận. Đặt lại về mặc định sẽ ảnh hưởng đến cài đặt trình chỉnh sửa chung; xuất bất cứ thứ gì phải được giữ lại trước tiên.

Trước khi dựa vào quy tắc trên máy tính để bàn:

1. Xác minh quyền Kiểm soát Thiết bị được cấp.
2. Xác minh danh tính chuẩn hóa của mục tiêu đã chọn.
3. Xác minh trạng thái kích hoạt, lịch trình, trạng thái đóng băng và giai đoạn báo lại.
4. Kiểm tra hành vi ngay lập tức, tính thời gian và đếm ngược một cách riêng biệt.
5. Đối với Nhóm tùy chỉnh, hãy chạy nguồn chính xác và kiểm tra từng sự kiện ứng dụng đã đăng ký.
6. Xác minh các lỗi thư mục cục bộ cũng như các hoạt động thành công.
7. Xác minh hành vi kết nối/ngoại tuyến của cầu nối nếu nhóm được liên kết.

## 11. Ghi chú dành riêng cho nền tảng

Các khái niệm chính sách cốt lõi được chia sẻ nhưng việc thực thi gốc lại tùy theo máy chủ:

| macOS | Windows |
| --- | --- |
| Các mục tiêu thường phân giải thành các mã định danh gói ứng dụng. Kiểm soát thiết bị và thực thi cổng trạng thái cấp phép macOS hiện tại. | Các mục tiêu thường phân giải thành đường dẫn thực thi hoặc tên quy trình được chuẩn hóa. Lớp thực thi Windows quyết định những cửa sổ/quy trình hiện tại nào có thể được quản lý. |

Tham chiếu dành cho máy tính để bàn này cố tình không mô tả danh sách chặn trang web, bộ chọn nguồn cấp dữ liệu, phân loại người sáng tạo trên YouTube, chuyển hướng trình duyệt hoặc hành động trên tab trình duyệt. Chúng thuộc về hướng dẫn sử dụng tiện ích mở rộng của Vault.
