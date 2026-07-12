# Mac Vault 发布指南

本指南遵循签入的构建脚本。它故意不包含个人签名身份、公证资料、密码或帐户数据。

## 发布之前

1. 从存储库根运行`swift test`。
2. 在受控项目/构建配置中设置发布版本和构建号。
3.审查英文手册、本地化手册以及编辑翻译审核。
4. 在发布工件之前验证发布分支、标签和里程碑策略。

## 网站 DMG 管道

脚本位于`scripts/release/`。它们的默认值可以用环境变量覆盖，包括`APP_NAME`、`BUNDLE_ID`、`TEAM_ID`、`SIGNING_IDENTITY`、`NOTARY_PROFILE`、`VERSION` 和`BUILD_NUMBER`。

仅在配置的签名机器上运行完整的管道：

```bash
VERSION=<version> BUILD_NUMBER=<build> scripts/release/full_release_dmg.sh
```

该管道由现有的构建、签名、DMG、公证和验证脚本组成。将其输出视为候选版本，直到验证步骤成功。

## Xcode 分发目标

从`XcodeProject/project.yml`生成Xcode项目，在批准的环境中配置适当的签名团队和功能，然后归档相关目标。不要提交生成的凭据、配置文件或公证配置文件。

## 发布后

1. 根据发布管理策略创建不可变版本标签和永久发布分支。
2. 发布发布工件和校验和。
3. 仅在工件 URL 最终确定后才更新公开发布注册表。
4. 保留英文版本说明，除非提供经过审查的本地化版本说明。
