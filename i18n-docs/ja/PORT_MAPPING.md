# Mac Vault 実装マップ

このマップは、現在のソース ツリーから派生します。これはナビゲーション補助であり、すべてのブラウザー機能にネイティブの同等機能があるという主張ではありません。

|懸念事項 |現在の macOS の実装 |
| --- | --- |
|グループとポリシー モデル | `Sources/MacBlockerCore/BlockGroup.swift`、`PolicyEvaluator.swift`、`UsageState.swift`、および `Schedule.swift` |
|ウェブエディタ | `Sources/MacBlockerWebUI/` と `WKWebView` 内の `WebAssets/` |
|エディターの永続性 | `BlockerWebStore.swift` と WebView ブリッジ |
|ネイティブ アプリのインベントリ | `Sources/MacBlockerMacControl/MacApplicationInventory.swift` と `MacAppInventoryJSON.swift` |
|施行計画 | `Sources/MacBlockerCore/EnforcementPlan.swift` と `Sources/MacBlockerAppFeature/MacEnforcementBridge.swift` |
|ネイティブ コントロール アダプター | `Sources/MacBlockerMacControl/` と `Sources/MacBlockerScreenTime/` |
|カスタムルール | `CustomJavaScriptPolicyRuntime.swift` と JavaScript ランタイム リソース |
|ブリッジハブ | `Sources/MacBlockerAppFeature/ConnectionHub.swift` |
|アプリのライフサイクル | `BlockerAppDelegate.swift`、`BlockerMainView.swift`、および `MacBlockerPanelApp.swift` |

## 製品境界

WebView エディタはグループ指向のユーザー モデルを Vault 拡張機能と共有しますが、アクションで実行できる内容はホストが決定します。ブラウザのみのアクションは、ネイティブ強制としてサイレントに処理されません。ネイティブ実行は、Mac で利用可能な権限、ターゲット、アダプターによって異なります。

## アセットを最新の状態に保つ

英語の取扱説明書は `WebAssets/manual/en.md`;翻訳されたマニュアルは、ロケール コードと同じディレクトリを共有します。翻訳カタログは `WebAssets/translation/` に残り、残りの保守文書の翻訳コピーは `i18n-docs/<locale>/` に保存されます。

エディター文字列を変更する場合は、最初に英語キーを更新し、次にロケール カタログを更新して、共有翻訳監査を実行します。
