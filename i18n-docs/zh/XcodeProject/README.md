# Mac Vault Xcode 项目

`project.yml` 是使用共享 Swift 包的 macOS 和 iOS 目标的签入 XcodeGen 规范。

## 生成项目

```bash
cd XcodeProject
./generate.sh
open macosBlocker.xcodeproj
```

更改 `project.yml`、目标、权利或源成员资格后重新生成。不要使用生成的项目文件作为规范配置。

## 当前目标家庭

- `AdamanciaVaultMac` 是 `MacBlockerAppFeature` 支持的 macOS 应用程序目标。
- `macosBlocker` 是 iOS 应用程序目标。
- iOS 项目包括设备活动、Shield 配置和 Shield Action 扩展。

当前标识符、部署目标、版本字段和功能在 `project.yml` 和引用的权利文件中定义。分发前在签名环境中查看它们。

## 签名和功能

使用属于分配帐户的团队和捆绑包标识符。确认您正在构建的目标所需的功能。切勿将签名机密、配置文件或帐户凭据添加到此存储库。

## 首先测试

在创建存档之前运行共享包测试：

```bash
cd ..
swift test
```
