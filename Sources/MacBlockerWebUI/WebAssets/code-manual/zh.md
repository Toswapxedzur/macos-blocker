# Mac Vault 代码手册

[用户手册](../manual/zh.md)

## 规则契约

源代码是一个函数表达式 `(on, v) => { ... }`。只支持同步 JavaScript 和下述 API；不提供计时器、网络、原生系统 API 或浏览器页面访问。基于时间的规则使用 `ev.now` 和事件。Safari 规则使用浏览器代码手册，并在 Safari Vault 自己的宿主应用中运行。

- 编辑会保存草稿；**运行**会启用该代码并启用组。冻结组不能运行。空源代码会卸载规则。
- 成功运行会替换处理器和面板，清除该组的应用屏蔽集合，同时保留 `v.state`。编译或注册失败时保留原规则；超时可能使其停止。重启会再次注册上次启用的源代码；闭包变量和应用屏蔽集合会重置。
- 注册阶段可以初始化状态、注册处理器、显示面板和输出日志。应用、文件操作及发送事件应放在处理器中；注册阶段排队的这些操作会被丢弃。
- 停用会停止处理器，并移除面板和应用屏蔽。启用会恢复已加载的规则及其保留的面板和屏蔽。删除会移除处理器、状态和效果。之前退出的应用不会重新打开；文件写入不会撤销。
- 事件不受普通组目标限制；请在规则中选择应用。操作先进入队列，再在事件分发后执行。异常会停止该处理器，但不会回滚其状态或操作；后续处理器仍可能运行。只有文件操作有结果事件。

## API

- `on(type, handler)` → 布尔值。注册 `handler(ev)`；多个处理器按注册顺序运行。返回 false 表示参数无效或处理器数量达到上限。`ev = { type: string, now: number, data }`；`now` 是 Unix 时间戳，单位为毫秒。
- `v.state`：可修改的 JSON 对象，在事件分发后持久保存。应初始化缺失字段，而不是覆盖已有状态。赋值为非对象或数组会将其重置为 `{}`；无法序列化或超过大小限制的更新不会保存。
- `v.log(...values)`：该组日志的唯一来源。各组的日志和清除操作相互独立。加载错误显示在运行状态中；处理器诊断信息不会写入日志。
- `v.emit(type, data)`：将 `data` 的 JSON 副本排入队列，在当前事件之后交给该组的处理器，并生成新的 `now`；不是同步调用。
- `v.panel(id, spec)`：替换该组指定名称的浮动面板；`spec` 为 null 时移除面板。详见“面板”。
- `v.file(op, path, payload?)` → 请求 ID 字符串。详见“文件”。
- `v.block(appId, on)`：true 维持应用屏蔽，false 移除该组的屏蔽。所有已启用组的屏蔽共同生效；此调用不能解除另一个组的目标屏蔽。屏蔽会请求正常退出，并按设置中的间隔重试；它不会阻止进程启动，也不保证应用接受退出请求。
- `v.quit(appId)`：一次正常退出请求，遵循相同的保护和重试策略；不持续屏蔽。
- `v.open(appId)`：请求 macOS 打开已安装的应用；没有成功回调。

其他调用返回 `undefined`。应用 ID 是事件中提供的 bundle 标识符，例如 `com.valvesoftware.steam`。Block/Quit 忽略 `com.apple.*`、浏览器、Vault 及其辅助程序，以及空 ID。面板 ID 和状态属于一个组，与其显示名称无关。

## 事件

下述载荷写法用于描述类型，不是可执行代码。`?` 表示可选字段。

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

- `tick` 的间隔是近似值；请使用时间戳，而不是计数 tick。运行列表包含具有 bundle ID 的前台、菜单栏和后台 `.app` 进程，并非所有 Unix 进程。最前方应用可以为 null，也可以有空的应用 ID。
- `app` 在本次 tick 的 `tick` 事件前报告观测到的生命周期变化。只有焦点事件包含 `previousAppId`，未知时为 null。名称是显示名称，不是稳定 ID。
- `snooze` 表示用户按下了该组的暂缓按钮，本身不会实施暂停。
- 文件回复发送给请求它们的组。使用 `requestId` 关联回复，检查 `ok`，并通过 tick 设置截止时间：规则重新加载或停用时，回复可能丢失。运行后请求 ID 可能重复；待处理请求不属于持久任务。

## 面板

```text
spec = { title?: string, description?: string, controls?: Control[],
         position?: "top-left" | "top-right" | "bottom-left" | "bottom-right" | "center",
         width?: "small" | "medium" | "large" | number }
Control = { id?: string, type?: string, label?: string, value?, disabled?: boolean,
            ...type-specific fields below }
```

默认位置为右下角，宽度为 300px；small/medium/large 预设为 220/280/360px；数值宽度限制为 180–520px，并接受像素字符串。原生面板和分区纵向排列控件；浏览器布局、对齐、角色、自动聚焦和控件尺寸字段不影响原生渲染器。

ID 会标准化为 ASCII 字母、数字、`_`、`-`，最长 80；请选择唯一且稳定的 ID。省略控件 ID 时使用 `control-N`，省略或未知的类型使用 text。省略的文本和列表为空；disabled 默认为 false。每次调用替换整个规范。显式 `value` 覆盖已保存的输入；省略值时使用上次事件值，再进行类型标准化。原生事件提供字符串：重新渲染更新后的面板前，应将其解析为声明的值类型。未知字段会被丢弃；面板颜色、字体和 CSS 由 Vault 控制。

控件字段和初始值：

- `text`：`text` 字符串，默认为标签。`html`：`html` 字符串，经过清理后在 Mac 上显示为纯文本。
- `button`：`label`，可选 `action: "submit" | "cancel" | "close"`。点击值为操作字符串或空字符串。操作不会自动提交或关闭任何内容。
- `checkbox`、`toggle`：布尔 `value`，默认为 false；事件值为 `"true"`/`"false"`。
- `select`、`radio`：`options: (string | { value: string, label?: string })[]`；字符串值，默认为空。空选项值会被移除；标签默认使用值。选择后应更新面板的类型化值。
- `textInput`、`textarea`：字符串值，默认为空；textInput 的 `placeholder`；textarea 的 `rows` 为 1–12，默认 3。原生 textarea 忽略 placeholder。
- `numberInput`、`range`：数值，默认为 0；`min`、`max`、正数 `step`。更新面板时将值限制在边界内；未设置的标准化边界为 −1000000…1000000。原生 numberInput 是文本输入：请自行验证 `Number(event.value)`；min/max/step 不限制键入。原生 range 默认范围为 0…100，步长为 1。
- `date`、`time`：文本输入；初始值格式为 `YYYY-MM-DD`、`HH:MM`/`HH:MM:SS`，无效初始格式变为空。请自行验证修改。`color`：`#RRGGBB`，默认为 `#000000`。
- `pin`：数字字符串；`length` 为 3–12，默认 6；`masked` 默认为 true；`autoSubmit` 默认为 false。`section`：`text`、`controls`；深度为 3 的子分区没有子项，根控件深度为 0。

面板事件：普通输入发送 `change`；按钮只发送 `click`；PIN 发送 `change`，并在 autoSubmit 填满时发送 `submit`。没有原生挂载、卸载、聚焦或按键事件。值都是字符串，包括数字和布尔值。`values` 包含已渲染快照的输入值，可能落后于触发事件的修改；`value` 标识该次修改。将其保存到 `v.state`，并渲染类型化值，以实现可靠的表单。非点击事件会按每个控件在 100ms 内合并；不要将事件数当作按键次数。

文本限制：title/label 为 240；description/text 为 1000；HTML 为 20000；placeholder 为 500；输入文本为 2000；其他值字符串为 512；选项 value/label 为 256。超出部分会被截断。

## 文件

`op`：`"read"`、`"write"`、`"append"`、`"list"`、`"exists"`。需要在设置中选择**自定义规则文件夹**并授予权限。

- `path` 是相对路径，以 `/` 分隔目录。各段允许 ASCII 字母、数字、空格及 `_.,@()-`；不允许以点开头、`.`/`..`、绝对路径或 URL。文件后缀为 `.txt`、`.csv`、`.json`，不区分大小写。List 路径为目录；`""` 表示列出所选根目录。任何超出所选文件夹范围的路径（包括通过符号链接超出的路径）都会被拒绝。
- Read 返回 UTF-8 文本。Write 替换或创建文件；append 创建或追加，不会自动添加换行。写入时会创建父目录。字符串载荷原样写入；其他 JSON 载荷会序列化；null 或省略表示空文本。JSON/CSV 解析由规则负责。文件最大为 1048576 个 UTF-8 字节。
- List 返回直接下级的可见子目录和受支持文件。条目格式：`{ name: string, path: string, kind: "directory" | "file", extension?: string }`；文件的 extension 包含点。Exists 对受支持的文件路径返回布尔值。

```text
file.data = { requestId: string, op: string, path: string, ok: boolean,
              text: string | null, entries: Entry[] | null,
              exists: boolean | null, error: string }
```

未使用的结果字段为 null；成功时 error 为空。失败包括 invalid-path、unsupported-file-type、文件夹不可用、文件不存在及 file-too-large。将 error 视为字符串，不要当作固定且完整的枚举。没有事务 API；请对每个路径的读取、修改、写入操作进行串行处理。

## 限制

每组每事件最多排队 256 个操作、200 次日志调用、64 次发送事件；超出部分会被丢弃。每条规则最多 1000 个处理器、24 个面板；每个控件列表最多 32 项，每个选择控件最多 64 个选项；超出部分会被忽略或截断。事件发送链在 16 代后停止。序列化状态最多 65536 个 JavaScript 字符串字符。注册和每个事件的全部处理器合计应在 1 秒内完成；反复超时或硬超时会停止规则，直至再次运行。日志为每个组保留 200 条。计时和回复尽力执行，不保证实时性。

## 完整规则

除由暂缓按钮或面板按钮触发的五分钟暂停期间外，屏蔽 Steam：

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
