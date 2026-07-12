# マックボールト

Mac Vault は、Vault 製品ファミリーのネイティブ macOS メンバーです。これは、Swift ポリシー エンジン、WebView エディター、ネイティブ アプリケーション インベントリと施行アダプター、カスタム ルールのサポート、ローカル Web アプリ ブリッジ ハブを組み合わせています。

現在のコードが真実の情報源です。英語のアプリ内リファレンスは [Sources/MacBlockerWebUI/WebAssets/manual/en.md](Sources/MacBlockerWebUI/WebAssets/manual/en.md) です。

## 実装される内容

- 選択した macOS アプリケーションのデフォルト グループと、高度なポリシー ルールのカスタム グループ。
- 即時、許可、およびカウントダウンのブロック モード。
- スケジュール、フリーズ モード、スヌーズ フロー、インポート/エクスポート、および永続的なグループ状態。
- アプリケーション インベントリ、デバイス制御の許可状態、ネイティブ強制アダプター、およびフローティング ステータス サーフェス。
- ログ記録と構文チェックを備えた、制御された JavaScript ポリシー ランタイム。
- 明示的にリンクされた互換性のあるグループ用のループバック WebSocket ブリッジ ハブ。
- Vault 製品ファミリーと同じコア グループ モデルを備えた WebView エディタ。

## 開発

Swift パッケージのテストを実行します。

```bash
swift test
```

パッケージには、コア ポリシー、スケジュール、カスタム ルール、ブリッジ、インポート、および macOS コントロール テストが含まれています。

## Xcode プロジェクト

オプションの Xcode プロジェクトは、[XcodeProject/project.yml](XcodeProject/project.yml) から生成されます。

```bash
cd XcodeProject
./generate.sh
```

署名または配布ターゲットを設定する前に、[XcodeProject/README.md](XcodeProject/README.md) をお読みください。

## ドキュメントポリシー

英語の文書は正規のままです。エディター UI には完全なロケール カタログがあり、翻訳されたマニュアルは `WebAssets/manual/en.md` の横にあり、残りの保守ドキュメントの翻訳されたコピーは `i18n-docs/<locale>/` の下にあります。

法的条件とプライバシー通知は別個の法的文書のままです。この README はそれらに代わるものではありません。
