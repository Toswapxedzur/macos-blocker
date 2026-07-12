# Mac Vault 实现图

该地图源自当前的源树。它是一种导航辅助工具，而不是声称每个浏览器功能都具有本机等效功能。

|关注|当前 macOS 实施 |
| --- | --- |
|组和策略模型| `Sources/MacBlockerCore/BlockGroup.swift`、`PolicyEvaluator.swift`、`UsageState.swift` 和 `Schedule.swift` |
|网页编辑器 | `Sources/MacBlockerWebUI/` 和`WebAssets/` 位于`WKWebView` 内 |
|编辑坚持| `BlockerWebStore.swift` 和 WebView 桥 |
|原生应用库存 | `Sources/MacBlockerMacControl/MacApplicationInventory.swift` 和 `MacAppInventoryJSON.swift` |
|执行计划| `Sources/MacBlockerCore/EnforcementPlan.swift` 和 `Sources/MacBlockerAppFeature/MacEnforcementBridge.swift` |
|本机控制适配器| `Sources/MacBlockerMacControl/` 和 `Sources/MacBlockerScreenTime/` |
|自定义规则 | `CustomJavaScriptPolicyRuntime.swift` 加上 JavaScript 运行时资源 |
|桥枢纽| `Sources/MacBlockerAppFeature/ConnectionHub.swift` |
|应用程序生命周期| `BlockerAppDelegate.swift`、`BlockerMainView.swift` 和 `MacBlockerPanelApp.swift` |

## 产品边界

WebView 编辑器与 Vault 扩展共享面向组的用户模型，但主机决定操作可以执行的操作。仅浏览器操作不会被默认视为本机强制执行。本机执行取决于 Mac 上可用的权限、目标和适配器。

## 保持资产最新

英文使用说明书为`WebAssets/manual/en.md`；翻译后的手册与其区域设置代码共享同一目录。翻译目录保留在`WebAssets/translation/` 中，而其余维护文档的翻译副本则位于`i18n-docs/<locale>/` 下。

更改编辑器字符串时，请先更新其英文密钥，然后更新区域设置目录并运行共享翻译审核。
