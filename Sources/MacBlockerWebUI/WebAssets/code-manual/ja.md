# Adamancia Vault — Mac 版コードマニュアル

[ユーザーマニュアル](../manual/ja.md)

## ルールの契約

ソースは関数式 `(on, v) => { ... }` 一つです。対応するのは同期JavaScriptと以下のAPIだけです。JavaScriptのスケジューリングコールバック、ネットワーク、ネイティブシステムAPI、ブラウザーページへのアクセスは使えません。時間ベースのルールでは、以下の管理タイマーやトラッカー、または `ev.now` とイベントを使います。ブラウザールールはブラウザー拡張機能のコードマニュアルを参照します。Safariルールはブラウザーコードマニュアルを使い、Safari Vaultを含むアプリ内で実行します。

- 編集すると下書きが保存されます。**Run**でルールを有効化し、グループを有効にします。凍結中はRunできません。空のソースはルールをアンロードします。
- Runに成功するとハンドラー/パネルを置き換え、このグループのアプリブロック集合を解除しつつ`v.state`を保持します。コンパイル/登録に失敗すると前のルールが残り、タイムアウトで停止する場合があります。再起動時は最後に有効化したソースを登録し、クロージャ変数とアプリブロック集合をリセットします。
- 登録時にstateの初期化、ハンドラー登録、パネル表示、ログ記録ができます。アプリ/ファイル操作とemitはハンドラー内で行います。登録時のキューは破棄されます。
- Disableはハンドラーを停止し、パネル/アプリブロックを解除します。Enableは読み込み済みルールと保持したパネル/ブロックを再開します。Deleteはハンドラー/state/効果を削除します。終了済みアプリは再起動されず、ファイル書き込みも元に戻りません。
- イベントは通常のグループ対象に限定されません。ルール内でアプリを選んでください。操作はキューに入りdispatch後に適用されます。例外でそのハンドラーは止まりますがstate/操作はロールバックされず、後続は動く場合があります。結果イベントがあるのはファイル操作だけです。

## 管理タイマーとローリング使用量

`v.timer(id, {direction:"down", durationMs:300000})` は名前付きのカウントダウンを作成するか、既存のものを返します。初期状態は一時停止です。カウントアップには `{direction:"up"}` を使います。ハンドルには `start()`、`pause()`、`resume()`、`reset()`、`snapshot()` があります。開始と再開は何度呼んでも同じ効果になり、リセットすると経過時間ゼロの一時停止状態に戻ります。スナップショットには `ready`、`error`、`elapsedMs`、`remainingMs`（カウントアップではnull）、`running`、`completed` が含まれます。

実行中のタイマーは、アプリやブラウザーを閉じた間やルールを無効にした間も実時間に従って進みます。完了したカウントダウンは、各メンバーのルールが次に動くときに、タイマーのインカーネーションと世代ごとに一度だけ、`timerEnded` を `{id, direction, durationMs, generation, incarnation}` とともに配信します。Runでは再配信されません。配信はホストのイベントに依存し、リアルタイムのアラームではありません。パネルに `{type:"timer", timerId:"focus", label:"Focus"}` を入れると、既存のテキストコントロールを通じて表示できます。

`v.rolling(id, {windowMs:3600000, limitMs:600000})` は名前付きの実使用トラッカーを作成するか、既存のものを返します。`assign({websites:["youtube.com","reddit.com"], apps:[]})` はこのメンバーの対象割り当てを置き換えます。ネイティブルールでは代わりにプラットフォームのアプリIDを割り当てられます。ドメインはサブドメインを含みます。一つのトラッカーは対象の使用量を合算し、別のIDには独立した利用枠があります。`snapshot()` は `ready`、`error`、`usedMs`、`remainingMs`、`available`、`nextReturnAtMs`（記録済み使用量のいずれかが次に期限切れになる時刻、ミリ秒単位）を返します。`available(target?)` は対象が指定されると割り当ても確認します。`reset()` はこのオブジェクトの履歴を消去します。

条件を満たす観測済み使用量は、利用枠を超えた分もすべて計上されます。トラッカー自体はページやアプリをブロックしません。重複する可視ページの時間区間は一度だけ数え、ネイティブアプリでは観測された前面使用時間を数えます。無効なルールは使用量を加算しませんが、履歴は区間の境界で正確に期限切れになります。残る履歴が上限を下回って初めて利用可能に戻ります。ハートビートのサンプルは最大5秒に制限され、終了中や無効中の空白から活動が作られることはありません。ユーザーが送出したイベントは使用量を加算しません。

リンクしたカスタムグループ内の同じオブジェクトIDは、一つのローカルネイティブハブを権威として共有します。リンク時にはトラッカーの履歴と割り当てを統合し、開始側のタイマー状態を保持します。互換性のない設定ではリンクを拒否します。各メンバーは自身の完了イベントを受け取ります。切断中は共有トラッカーが利用不能になり、最新の権威が戻るまでタイマー操作を拒否します。リンク解除時には、各メンバーが最終の共有使用量とタイマー状態を保持し、自分の対象を復元して、古いリンクのコマンドを破棄します。ハブは、戻ってきたメンバーが最終スナップショットを保存して確認応答するまで保持します。保留中の引き継ぎが完了してから新しいリンクが利用可能になります。

名前付きオブジェクトは予約済みの `v.state.$vaultTime` に保存され、Runと再起動をまたいで保持されます。このフィールドを直接編集しないでください。削除には明示的に `v.removeTime(id)` を使います。IDは1～80文字のASCII英字、数字、`_`、`-` で、予約済みのプロパティ名は拒否されます。最大32個のオブジェクトがルールの64 KiB UTF-8状態上限を共有します。期間は最大365日の整数ミリ秒です。ローリング履歴は1024個の分単位バケットと2048個の結合済み区間が上限です。履歴容量エラーが起きると、明示的にリセットするまでトラッカーは利用不能になります。無効な設定や過大な保存はエラーを報告し、保存済みデータを消去しません。

```js
(on, v) => {
  const timer = v.timer("focus", {durationMs: 300000});
  v.panel("focus", {controls: [
    {type: "timer", timerId: "focus", label: "Focus"},
    {id: "start", type: "button", label: "Start"},
    {id: "pause", type: "button", label: "Pause"},
    {id: "reset", type: "button", label: "Reset"}
  ]});
  on("panel", ev => {
    if (ev.data.eventName !== "click") return;
    if (ev.data.controlId === "start") timer.start();
    if (ev.data.controlId === "pause") timer.pause();
    if (ev.data.controlId === "reset") timer.reset();
  });
  on("timerEnded", ev => v.log("Finished", ev.data.id));
}
```

## API

- `on(type, handler)` → boolean。`handler(ev)` を登録し、複数のハンドラーは登録順に実行されます。false は引数不正またはハンドラー上限を示します。`ev = { type: string, now: number, origin: "host" | "user" | "rule", data }`。`now` は Unix ミリ秒です。ネイティブパネル入力の origin は `origin: "user"`、`v.emit` の origin は `origin: "rule"` です。
- `v.state`: イベントdispatch後に保存する変更可能なJSONオブジェクトです。既存stateを上書きせず、欠けたフィールドを初期化してください。オブジェクト以外/配列を代入すると`{}`に戻ります。シリアライズ不可/過大な更新は保存されません。
- `v.log(...values)`: このグループのLogに追記します。実行と配信の失敗は、同じフィードに明示的なエラー項目として表示されます。Logs/Clearはグループごとに独立しています。読み込みエラーはRun状態にも表示されます。途中まで実行されたイベントは自動再実行されません。
- `v.emit(type, data)`: 現在のイベント後に`data`のJSONコピーを送り、新しい`now`を付けてをグループのハンドラーにキューします。同期呼び出しではありません。
- `v.panel(id, spec)`: グループの名前付きフローティングパネルを置き換えます。null `spec`で削除します。Panelsを参照してください。
- `v.file(op, path, payload?)` → リクエストID文字列。Filesを参照してください。
- `v.store(request)` → request ID 文字列。「グループレコード」を参照してください。
- `v.block(appId, on)`: trueでアプリブロックを維持し、falseでこのグループのブロックを解除します。有効なグループ間でブロックは合成され、この呼び出しでは他グループの対象を解除できません。ブロックは通常終了を要求し、設定間隔で再試行します。プロセス起動を防いだり、アプリがQuitを受け入れる保証はありません。
- `v.quit(appId)`: 同じ保護/再試行方針に従う通常終了要求一回。継続的なブロックではありません。
- `v.open(appId)`: macOSにインストール済みアプリの起動を要求します。成功コールバックはありません。

その他の呼び出しは `undefined` を返します。アプリIDはイベントで取得できるbundle identifier（例: `com.valvesoftware.steam`）です。Block/QuitはAppleのアプリとブラウザー全体を対象にできます。Vaultのbundle identifierとそのヘルパー（同じIDを共有する別のアプリを含む）、および空のIDは無視します。パネルID/stateは表示名ではなく一つのグループに属します。

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
record: { requestId: string, ok: boolean, op?: string, key?: string,
          record?: Record | null, entries?: Header[], next?: string | null,
          deleted?: number, error?: string }
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

## グループレコード

`v.store(request)` はハンドラー内で非同期の JSON レコード操作を開始します。レコードはグループ専用で、Run や再起動後も保持され、グループ削除時に削除されます。リンク済みグループのストアは別々です。キー、値、バージョン、キャッシュ無効化、フィードバックの優先順位はルールが決めます。Mac とブラウザーのルールは同じ API を使いますが、アプリ/ブラウザーごとにストアは別です。

| Request | Result |
|---|---|
| `{op:"get", key}` | `record` または `null` |
| `{op:"put", key, value, version?, ifRevision?}` | 保存された `record` |
| `{op:"delete", key, ifRevision?}` | `record: null` |
| `{op:"list", prefix?, after?, limit?}` | ソート済み `entries` と `next` |
| `{op:"clear", prefix?}` | `deleted` 件数 |

レコードは `{value, revision, version, updatedAt}` です。不透明な revision は実際の書き込みで変わります。`version` は呼び出し側のメタデータです。`list` は値を含まないヘッダーを返します。1件の読み出しには `get`、次ページには `after: next` を使います。`put`/`delete`, `ifRevision` 省略時の put/delete は無条件です。`null` はキーが存在しないこと、revision 文字列は完全一致を条件にします。不一致は `ok:false`、`error:"store-conflict"`、現在の `record` を返します。遅延した自動応答がユーザーのフィードバックを上書きするのを防げます。`v.context.revision` はルール設定の不透明なマーカーで、ルール独自のバージョンに含められます。フレームワークはキャッシュ方針を定めません。

上限: キー1～2048文字、version ≤128、JSON値 ≤64KiB、深さ≤32、グループあたり10000キー、レコード文書全体16MiB。`list` は1ページあたり最大100ヘッダー、96KiB。グループあたり32要求、全体で毎秒128開始まで。過負荷時はグループごとに毎秒1回 `store-busy` を返し、残りを破棄します。ストレージエラーは `ok:false`。将来形式または不正な文書は保持して `store-unavailable` を報告します。自動再試行/削除はありません。期限には ticks を使います。

## 上限

イベント/グループごとにキュー操作256件、log呼び出し200回、emit64回。超過分は破棄されます。ルールごとにハンドラー1000個、パネル24個。各コントロールリストは32項目、各選択コントロールは64個の選択肢を持ち、超過分は無視または切り詰められます。emit連鎖は16世代で停止します。シリアライズした状態の上限は65536 UTF-8バイトです。登録と各イベントのハンドラーの合計実行時間を1秒未満にしてください。超過が繰り返された場合や強制タイムアウト時は、Runまでルールを停止します。Logはグループごとに200件を保持します。タイミングと応答はベストエフォートで、リアルタイム保証はありません。

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


## 実行中のルールからの AI 呼び出し

各 `v.ai` 呼び出しでは接続とモデルを指定します。グループ既定値はありません。**AI calls** からモデル ID をコピーするか、Vault のルール AI モデルツールで認証情報不要の一覧を確認します。推論の強さは呼び出しごとに選びます。ブラウザー要求にはデスクトップ Vault への接続が必要で、プロバイダー認証情報はそこに保持されます。リンクしたグループは任意の日次上限を共有します。空欄ならグループ上限はなく、アカウント上限は適用されます。上限は UTC 日単位で、再起動後も保持され、失敗を含む送信試行を数えます。リンク時に既存使用量を合算し、解除後も保持します。

任意の保存済み prompt と context はリンク済みグループで共有され、再起動後も残ります。ハンドラー内では `v.context.ai.prompt` と `v.context.ai.context` として利用できますが、Vault は自動送信しません。各 `v.ai` 呼び出しに何を含めるかはルールが決めます。どちらかを編集すると旧設定の応答は無効になります。

`conversation` は任意の名前です。指定しなければ呼び出しは状態を保持しません。指定するとデスクトップ Vault はユーザー/アシスタントの完全な会話記録をローカル保存し、次回に最新メッセージの最大16KBを含めます。同じ会話でモデルを切り替えられますが、新モデルに渡るのは移植可能なテキストだけです。名前はこの端末のすべてのルールとグループで共有されます。グループを削除またはリンク解除しても名前付き会話は残ります。ローカル記録の合計上限は既定1 GBで、Vault 設定から変更できます。満杯になると最も長く使われていない会話を削除します。以前の非公開ビルドがグループごとに同名の履歴を保存していた場合、Vault は別名で読み込み、変更名を `preservedConversations` として報告します。

共有会話を明示的に削除するには `v.ai({op:"delete", conversation:"name"})` を呼びます。応答は `ai` イベントで届きます。同名の呼び出しが実行中なら `ai-conversation-busy` が返るので、応答後に再試行します。保存失敗は成功応答を黙って失う代わりにエラーとして通知されます。会話のテキストは通常のルール状態へ自動追加されません。

`v.ai({ model, reasoningEffort?, conversation?, prompt, input? })` は直ちに要求 ID を返します。ルール登録時ではなくハンドラー内で呼び出してください。`model` は利用可能なモデル ID です。effort を省略すると `default`、対応時は `low`、`medium`、`high` を指定できます。`input` は任意の JSON 値で、prompt/input は各20KBまでです。応答は `ai` イベント `{requestId, ok, text, citations,
error, preservedConversations?}` 成功時のテキストは最大48KBです。引用の形式は`{url,title}`です。.
Web 検索に基づく回答を表示する場合、出典リンクを見える状態かつクリック可能にしてください。モデルは常に検索できます。生成要求にアプリ側の固定期限はありません。複数の名前付き会話を並行実行でき、同名の呼び出しは順番に処理されます。続きは `ai` イベントから呼び出します。Vault はまだ遅延呼び出しをスケジュールしません。プロバイダーの容量や上限により待機または拒否されることがあります。別プロバイダーへの切替や自動再試行はありません。応答はデータであり JavaScript として実行されません。実行する既存アクションはルールが決めます。

`ask` ボタンと `note` フィールドのあるパネルでは:

```javascript
(on, v) => {
  let pending = null;
  on("panel", ({ data }) => {
    if (data.controlId !== "ask" || pending) return;
    pending = v.ai({ model: "chatgpt:MODEL_ID", conversation: "notes", prompt: v.context.ai.prompt || "Summarize this text.", input: {context:v.context.ai.context, note:data.values?.note ?? ""} });
  });
  on("ai", ({ data }) => {
    if (data.requestId !== pending) return;
    pending = null;
    if (!data.ok) { v.log("AI request failed:", data.error); return; }
    v.log(data.text, data.citations);
  });
}
```

保留中の呼び出しは再起動後に再実行されません。Run、無効化/再有効化、削除は古い応答を破棄します。切断されたブラウザーは `ai-unavailable` を報告します。その他のエラーは `ai-not-configured`、`ai-invalid-input`、`ai-daily-limit`、`ai-request-failed`、`ai-usage-storage-unavailable`、`ai-conversation-storage-unavailable` です。失敗した呼び出しはルールが保持していた結果を上書きしません。ルール状態の上限は引き続き64KBです。

認証情報不要の候補は Mac の `rule_ai_models` またはブラウザーの `settings-rule-ai-models` で調べ、既存の set-group 経由で `ruleAI` を設定できます。項目は `dailyRequestLimit`（null または1–100000）、`prompt`、`context`（任意の文字列、各最大16KB）です。モデルと effort は毎回指定し、グループ既定値は保存されません。返された候補を使い、キーやプロバイダー URL をルールソースに記述しないでください。
