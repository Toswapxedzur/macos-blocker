# Mac Vaultコードマニュアル

[ユーザーマニュアル](../manual/ja.md)

## ルールの契約

ソースは関数式 `(on, v) => { ... }` 一つです。対応するのは同期JavaScriptと以下のAPIだけです。タイマー、ネットワーク、ネイティブシステムAPI、ブラウザーページへのアクセスは使えません。時間ベースのルールでは `ev.now` とイベントを使います。ブラウザールールはブラウザー拡張機能のコードマニュアルを参照します。Safariルールはブラウザーコードマニュアルを使い、Safari Vaultを含むアプリ内で実行します。

- 編集すると下書きが保存されます。**Run**でルールを有効化し、グループを有効にします。凍結中はRunできません。空のソースはルールをアンロードします。
- Runに成功するとハンドラー/パネルを置き換え、このグループのアプリブロック集合を解除しつつ`v.state`を保持します。コンパイル/登録に失敗すると前のルールが残り、タイムアウトで停止する場合があります。再起動時は最後に有効化したソースを登録し、クロージャ変数とアプリブロック集合をリセットします。
- 登録時にstateの初期化、ハンドラー登録、パネル表示、ログ記録ができます。アプリ/ファイル操作とemitはハンドラー内で行います。登録時のキューは破棄されます。
- Disableはハンドラーを停止し、パネル/アプリブロックを解除します。Enableは読み込み済みルールと保持したパネル/ブロックを再開します。Deleteはハンドラー/state/効果を削除します。終了済みアプリは再起動されず、ファイル書き込みも元に戻りません。
- イベントは通常のグループ対象に限定されません。ルール内でアプリを選んでください。操作はキューに入りdispatch後に適用されます。例外でそのハンドラーは止まりますがstate/操作はロールバックされず、後続は動く場合があります。結果イベントがあるのはファイル操作だけです。

## API

- `on(type, handler)` → boolean。`handler(ev)`を登録します。複数ハンドラーは登録順に動きます。falseは引数不正かハンドラー上限を示します。`ev = { type: string, now: number, data }`、`now`はUnixミリ秒です。
- `v.state`: イベントdispatch後に保存する変更可能なJSONオブジェクトです。既存stateを上書きせず、欠けたフィールドを初期化してください。オブジェクト以外/配列を代入すると`{}`に戻ります。シリアライズ不可/過大な更新は保存されません。
- `v.log(...values)`: このグループのLogを生成する唯一の方法です。Logs/Clearはグループごとに独立します。読み込みエラーはRun状態に表示され、ハンドラー診断はLogに入りません。
- `v.emit(type, data)`: 現在のイベント後に`data`のJSONコピーを送り、新しい`now`を付けてをグループのハンドラーにキューします。同期呼び出しではありません。
- `v.panel(id, spec)`: グループの名前付きフローティングパネルを置き換えます。null `spec`で削除します。Panelsを参照してください。
- `v.file(op, path, payload?)` → リクエストID文字列。Filesを参照してください。
- `v.block(appId, on)`: trueでアプリブロックを維持し、falseでこのグループのブロックを解除します。有効なグループ間でブロックは合成され、この呼び出しでは他グループの対象を解除できません。ブロックは通常終了を要求し、設定間隔で再試行します。プロセス起動を防いだり、アプリがQuitを受け入れる保証はありません。
- `v.quit(appId)`: 同じ保護/再試行方針に従う通常終了要求一回。継続的なブロックではありません。
- `v.open(appId)`: macOSにインストール済みアプリの起動を要求します。成功コールバックはありません。

その他の呼び出しは`undefined`を返します。アプリIDはイベントで取得できるbundle identifier（例: `com.valvesoftware.steam`）です。Block/Quitは`com.apple.*`、ブラウザー、Vaultとそのヘルパー、空のIDを無視します。パネルID/stateは表示名ではなく一つのグループに属します。

## イベント

以下のペイロード表記は型を説明するもので、実行可能コードではありません。`?`は省略可能なフィールドです。

```text
tick (~1 second): { frontmost: App | null, running: App[] }
app: { kind: "launch" | "quit" | "focus" | "blur" | "hide" | "unhide",
       appId: string, name: string, previousAppId?: string | null }
snooze: {}
panel: { panelId: string, controlId: string, eventName: string,
         value: string, values: { [controlId: string]: string } }
file: see Files
App = { appId: string, name: string }
```

- `tick`は概算です。回数ではなくタイムスタンプを使います。Runningにはbundle IDを持つ前面、メニューバー、バックグラウンドの`.app`プロセスが含まれます。すべてのUnixプロセスではありません。Frontmostはnullまたは空のアプリIDの場合があります。
- `app`はそのtickの`tick`イベントの前に観測されたライフサイクル変更を報告します。focusだけが`previousAppId`を含みます（不明ならnull）。名前は表示名で、固定IDではありません。
- `snooze`はグループのSnoozeボタンが押されたことを示します。それだけで一時停止にはなりません。
- ファイル応答は要求元グループに届きます。`requestId`を照合し、`ok`を確認してtickで期限を設定します。ルール再読み込み/無効化で応答が失われる場合があります。Run後にIDが再利用される場合があり、保留中の要求は永続作業ではありません。

## パネル

```text
spec = { title?: string, description?: string, controls?: Control[],
         position?: "top-left" | "top-right" | "bottom-left" | "bottom-right" | "center",
         width?: "small" | "medium" | "large" | number }
Control = { id?: string, type?: string, label?: string, value?, disabled?: boolean,
            ...type-specific fields below }
```

既定値: 右下、幅300px。small/medium/largeプリセットは220/280/360px。数値幅は180～520pxに制限され、ピクセル文字列も指定できます。ネイティブパネル/セクションはコントロールを縦に並べます。ブラウザーのlayout、alignment、role、autofocus、コントロール寸法はネイティブ表示に影響しません。

IDはASCII英数字/`_`/`-`に正規化されます（最大80）。一意で安定したIDを選びます。省略したコントロールIDは`control-N`、省略/不明な型はtextになります。省略したテキスト/リストは空、disabledはfalseです。各呼び出しでspec全体を置き換えます。明示した`value`は保存済み入力に優先し、省略時は最後のイベント値を型に応じて正規化します。ネイティブイベントは文字列を渡すため、更新パネルの表示前に宣言した値型へ解析します。不明なフィールドは破棄され、パネル色/フォント/CSSはVaultが管理します。

コントロールのフィールドと初期値:

- `text`: string型`text`、既定はlabel。`html`: string型`html`。Macではサニタイズ後にプレーンテキストで表示されます。
- `button`: `label`、任意の`action: "submit" | "cancel" | "close"`。クリック値はaction文字列か空です。actionだけでは送信/終了しません。
- `checkbox`, `toggle`: boolean型`value`（既定false）。イベント値は`"true"`/`"false"`。
- `select`, `radio`: `options: (string | { value: string, label?: string })[]`、string型value（既定空）。空のoption valueは除去、labelはvalueが既定です。選択後は型付きパネル値を更新します。
- `textInput`, `textarea`: string型value（既定空）、`placeholder`。textareaの`rows`は1～12（既定3）。ネイティブtextareaはplaceholderを無視します。
- `numberInput`, `range`: 数値value（既定0）、`min`、`max`、正の`step`。パネル更新時に範囲へ収めます。未指定の正規化範囲は−1000000～1000000。ネイティブnumberInputはテキスト入力です。`Number(event.value)`を自分で検証してください。min/max/stepは入力を制限しません。ネイティブrangeの既定範囲は0～100、stepは1です。
- `date`, `time`: テキスト入力。初期形式は`YYYY-MM-DD`、`HH:MM`/`HH:MM:SS`（不正なら空）。編集値は自分で検証します。`color`: `#RRGGBB`（既定`#000000`）。
- `pin`: 数字文字列。`length`は3～12（既定6）、`masked`は既定true、`autoSubmit`はfalse。`section`: `text`、`controls`。depth 3の子sectionに子はありません（root controlsはdepth 0）。

パネルイベント: 通常の入力は`change`を送り、ボタンは`click`のみ、PINは`change`とautoSubmit完了時の`submit`を送ります。ネイティブmount/unmount/focus/keyイベントはありません。数値/真偽値を含め、値は文字列です。`values`には表示中snapshotの入力値が入り、きっかけとなった編集より遅れる場合があります。`value`がその編集を示します。信頼できるフォームには`v.state`に保存し、型付き値を描画してください。クリック以外のイベントはコントロールごとに100ms内でまとめられ、キー入力数とは一致しません。

テキスト上限: title/label 240、description/text 1000、HTML 20000、placeholder 500、入力テキスト2000、その他の値文字列512、option value/label 256。超過分は切り詰められます。

## ファイル

`op`: `"read"`、`"write"`、`"append"`、`"list"`、`"exists"`。設定の**カスタムルールフォルダー**とその権限が必要です。

- `path`は相対パスです。`/`でディレクトリを区切ります。使用可能な文字はASCII英数字、空白、`_.,@()-`です。先頭ドット、`.`/`..`、絶対パス、URLは不可です。拡張子は`.txt`、`.csv`、`.json`（大文字小文字を区別しません）。Listのpathはディレクトリで、`""`は選択したルートを列挙します。シンボリックリンク経由も含め、選択フォルダー外へのpathは拒否されます。
- ReadはUTF-8テキストを返します。Writeは置換/作成、appendは自動改行なしで追記/作成します。書き込み時に親ディレクトリを作成します。string payloadはそのまま書き、その他のJSON payloadはシリアライズします。null/省略は空テキストです。JSON/CSV解析はルールの役割です。最大サイズは1048576 UTF-8バイトです。
- Listは直下の表示可能なサブディレクトリと対応ファイルを返します。項目: `{ name: string, path: string, kind: "directory" | "file", extension?: string }`。ファイルのextensionにはドットが含まれます。Existsは対応ファイルpathの真偽値を返します。

```text
file.data = { requestId: string, op: string, path: string, ok: boolean,
              text: string | null, entries: Entry[] | null,
              exists: boolean | null, error: string }
```

未使用の結果フィールドはnull、成功時errorは空です。失敗にはinvalid-path、unsupported-file-type、フォルダー利用不可、ファイルなし、file-too-largeがあります。errorは固定の網羅的enumではなく文字列として扱います。トランザクションAPIはありません。pathごとにread-modify-writeを直列化してください。

## 上限

イベント/グループごとにキュー操作256件、log呼び出し200回、emit 64回。超過分は破棄されます。ルールごとにhandler 1000個、panel 24個、コントロールリスト32項目、選択肢64個。超過分は無視/切り詰められます。Emit連鎖は16世代で停止します。シリアライズstate上限はJavaScript文字列65536文字。登録と各イベントの合計handlerを1秒未満に保ちます。繰り返し超過または強制タイムアウトでRunまでルールを停止します。Logはグループごとに200件保持します。タイミング/応答はベストエフォートで、リアルタイム保証ではありません。

## 完全なルール

Snoozeまたはパネルボタンで起動する5分間の一時停止中を除き、Steamはブロックされます:

```javascript
(on, v) => {
  v.state.pauseUntil ??= 0;
  const pause = ev => { v.state.pauseUntil = ev.now + 300000; };
  v.panel("pause", { controls: [{ id: "pause", type: "button", label: "Pause 5 min" }] });
  on("snooze", pause);
  on("panel", ev => {
    if (ev.data.panelId === "pause" && ev.data.controlId === "pause" && ev.data.eventName === "click") pause(ev);
  });
  on("tick", ev => v.block("com.valvesoftware.steam", ev.now >= v.state.pauseUntil));
}
```
