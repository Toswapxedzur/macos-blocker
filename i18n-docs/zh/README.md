# Mac 保管库

Mac Vault 是 Vault 产品系列的原生 macOS 成员。它结合了 Swift 策略引擎、WebView 编辑器、本机应用程序清单和执行适配器、自定义规则支持以及本地 Web 应用程序桥接中心。

当前的代码是事实的来源。英文应用内参考为 [Sources/MacBlockerWebUI/WebAssets/manual/en.md](Sources/MacBlockerWebUI/WebAssets/manual/en.md)。

## 实现了什么

- 选定 macOS 应用程序的默认组和高级策略规则的自定义组。
- 立即、允许和倒计时阻塞模式。
- 计划、冻结模式、暂停流程、导入/导出和持久组状态。
- 应用程序清单、设备控制权限状态、本机强制适配器和浮动状态界面。
- 受控的 JavaScript 策略运行时，具有日志记录和语法检查功能。
- 用于显式链接的兼容组的环回 WebSocket 桥集线器。
- 与 Vault 产品系列具有相同核心组模型的 WebView 编辑器。

## 发展

运行 Swift 包测试：

```bash
swift test
```

该软件包包括核心策略、时间表、自定义规则、桥接、导入和 macOS 控制测试。

##Xcode 项目

可选的 Xcode 项目是从 [XcodeProject/project.yml](XcodeProject/project.yml) 生成的：

```bash
cd XcodeProject
./generate.sh
```

在配置签名或分发目标之前，请阅读 [XcodeProject/README.md](XcodeProject/README.md)。

## 文档政策

英文文档仍然是规范的。编辑器 UI 具有完整的语言环境目录，翻译后的手册位于 `WebAssets/manual/en.md` 旁边，其余维护文档的翻译副本位于 `i18n-docs/<locale>/` 下。

法律条款和隐私声明仍然是单独的法律文件；本自述文件并不能取代它们。
