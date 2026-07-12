# Mac Vault 구현 맵

이 맵은 현재 소스 트리에서 파생됩니다. 이는 모든 브라우저 기능에 기본적으로 동등한 기능이 있다는 주장이 아니라 탐색 보조 기능입니다.

| 우려사항 | 현재 macOS 구현 |
| --- | --- |
| 그룹 및 정책 모델 | `Sources/MacBlockerCore/BlockGroup.swift`, `PolicyEvaluator.swift`, `UsageState.swift`, `Schedule.swift` |
| 웹 편집기 | `Sources/MacBlockerWebUI/` 및 `WebAssets/` 내부 `WKWebView` |
| 편집자 지속성 | `BlockerWebStore.swift` 및 WebView 브리지 |
| 기본 앱 인벤토리 | `Sources/MacBlockerMacControl/MacApplicationInventory.swift` 및 `MacAppInventoryJSON.swift` |
| 시행계획 | `Sources/MacBlockerCore/EnforcementPlan.swift` 및 `Sources/MacBlockerAppFeature/MacEnforcementBridge.swift` |
| 네이티브 제어 어댑터 | `Sources/MacBlockerMacControl/` 및 `Sources/MacBlockerScreenTime/` |
| 맞춤 규칙 | `CustomJavaScriptPolicyRuntime.swift` 및 JavaScript 런타임 리소스 |
| 브리지 허브 | `Sources/MacBlockerAppFeature/ConnectionHub.swift` |
| 앱 수명주기 | `BlockerAppDelegate.swift`, `BlockerMainView.swift`, `MacBlockerPanelApp.swift` |

## 제품 경계

WebView 편집기는 Vault 확장과 그룹 중심 사용자 모델을 공유하지만 작업이 수행할 수 있는 작업은 호스트가 결정합니다. 브라우저 전용 작업은 기본 적용으로 자동 처리되지 않습니다. 기본 실행은 Mac에서 사용 가능한 권한, 대상 및 어댑터에 따라 다릅니다.

## 자산을 최신 상태로 유지

영어 사용 설명서는 `WebAssets/manual/en.md`입니다. 번역된 매뉴얼은 해당 로케일 코드와 동일한 디렉토리를 공유합니다. 번역 카탈로그는 `WebAssets/translation/`에 남아 있고, 유지 관리되는 나머지 문서의 번역된 사본은 `i18n-docs/<locale>/`에 있습니다.

편집기 문자열을 변경할 때 먼저 영어 키를 업데이트한 다음 로캘 카탈로그를 업데이트하고 공유 번역 감사를 실행하세요.
