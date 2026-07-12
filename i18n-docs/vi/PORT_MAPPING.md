# Sơ đồ triển khai Mac Vault

Bản đồ này được lấy từ cây nguồn hiện tại. Nó là một công cụ hỗ trợ điều hướng, không phải là tuyên bố rằng mọi khả năng của trình duyệt đều có tính tương đương gốc.

| Mối quan tâm | Triển khai macOS hiện tại |
| --- | --- |
| Nhóm và mô hình chính sách | `Sources/MacBlockerCore/BlockGroup.swift`, `PolicyEvaluator.swift`, `UsageState.swift`, và `Schedule.swift` |
| Biên tập web | `Sources/MacBlockerWebUI/` và `WebAssets/` bên trong `WKWebView` |
| Biên tập viên kiên trì | `BlockerWebStore.swift` và cầu WebView |
| Khoảng không quảng cáo ứng dụng gốc | `Sources/MacBlockerMacControl/MacApplicationInventory.swift` và `MacAppInventoryJSON.swift` |
| Kế hoạch thực thi | `Sources/MacBlockerCore/EnforcementPlan.swift` và `Sources/MacBlockerAppFeature/MacEnforcementBridge.swift` |
| Bộ điều hợp điều khiển gốc | `Sources/MacBlockerMacControl/` và `Sources/MacBlockerScreenTime/` |
| Quy tắc tùy chỉnh | `CustomJavaScriptPolicyRuntime.swift` cộng với tài nguyên thời gian chạy JavaScript |
| Trung tâm cầu | `Sources/MacBlockerAppFeature/ConnectionHub.swift` |
| Vòng đời ứng dụng | `BlockerAppDelegate.swift`, `BlockerMainView.swift` và `MacBlockerPanelApp.swift` |

## Ranh giới sản phẩm

Trình chỉnh sửa WebView chia sẻ mô hình người dùng hướng đến nhóm với tiện ích mở rộng Vault nhưng máy chủ sẽ quyết định hành động nào có thể thực hiện. Các hành động chỉ dành cho trình duyệt không được âm thầm coi là thực thi gốc. Việc thực thi tự nhiên phụ thuộc vào quyền, mục tiêu và bộ điều hợp có sẵn trên máy Mac.

## Duy trì tài sản hiện tại

Hướng dẫn sử dụng bằng tiếng Anh là `WebAssets/manual/en.md`; các hướng dẫn đã dịch chia sẻ cùng một thư mục với mã ngôn ngữ của chúng. Danh mục dịch thuật vẫn ở `WebAssets/translation/`, trong khi bản dịch của các tài liệu được lưu giữ còn lại ở `i18n-docs/<locale>/`.

Khi thay đổi chuỗi trình soạn thảo, trước tiên hãy cập nhật khóa tiếng Anh của nó, sau đó cập nhật danh mục ngôn ngữ và chạy kiểm tra bản dịch được chia sẻ.
