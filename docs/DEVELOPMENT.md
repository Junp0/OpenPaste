# 开发、构建与发布

[返回首页](../README.md)

## 环境

- macOS 开发环境，Swift 6.2+，macOS 26+ SDK（Xcode 26+ 或对应 Command Line Tools）。
- 应用部署目标为 macOS 13；源码使用的 Liquid Glass 等新 API 需要新 SDK 编译，运行时使用可用性检查与回退。
- `Package.swift` 使用 Swift 6 包清单和 Swift 5 语言模式。
- 使用系统 SQLite，不需要 Homebrew 或第三方 Swift 包。

检查当前工具链：

```sh
swift --version
xcrun --show-sdk-version
xcode-select -p
```

如安装多个 Xcode，请通过 `DEVELOPER_DIR` 选择所需工具链。自动测试需要 Swift Testing 运行库支持，建议在 macOS 14+ 开发机运行；这与应用本身的 macOS 13 部署目标不同。

## 目录结构

```text
.github/                   GitHub 工作流、Issue 和 PR 模板
Sources/
  ClipboardCore/           数据模型、SQLite 持久化
  ClipShelf/               剪贴板监测、窗口、快捷键与 SwiftUI 界面
  CSQLite/                 系统 SQLite 模块声明
Tests/
  ClipboardCoreTests/      持久化、去重、清理与迁移测试
  ClipShelfTests/          剪贴板格式、搜索、交互和状态测试
Resources/Info.plist        应用标识、版本和部署配置
scripts/                   构建、启动、测试、签名和图标生成
docs/                      使用、隐私、开发和验证文档
```

`build/` 和 `.build/` 为本机生成目录，已被 Git 忽略。`docs/assets/icon.png` 来自 `scripts/make-icon.swift` 生成的应用图标，用于 README 展示。

对外名称为 iPaste；内部模块 `ClipShelf`、Bundle ID `io.clipshelf.app`、历史目录 `ClipShelf` 保留原名，以兼容已有历史、偏好设置和授权。

## 构建与启动

在仓库根目录执行：

```sh
./scripts/build.sh        # release 编译、生成图标、打包并签名
./scripts/build.sh debug  # debug 应用包
./scripts/run.sh          # 打开 build/iPaste.app，不存在时先构建
```

`run.sh` 在应用包已存在时直接启动它，不检测源码是否更新。修改代码后请先从菜单栏退出应用，再重新构建；不会自动重启已运行的进程。

只检查编译或运行测试时不需要创建签名身份：

```sh
swift build -c release
./scripts/test.sh
```

## 本机签名

默认首次打包生成本机专用签名证书，后续复用。证书、独立钥匙串及解锁凭据存放在：

```text
~/Library/Application Support/iPaste/CodeSigning/
```

此目录位于仓库之外，只应由当前用户访问。请保留原身份；删除或更换后可能需要重新授予辅助功能权限。脚本不修改系统证书信任或辅助功能授权，签名失败不会回退到临时签名。不要将此目录上传或附在 Issue 中。

本机自签名适用于自己的 Mac，没有经过 Developer ID 公证。已有 Apple 证书时可以显式指定：

```sh
CODE_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' ./scripts/build.sh
```

独立钥匙串可通过 `CODE_SIGN_KEYCHAIN=/path/to/signing.keychain-db` 指定。更新时应继续使用兼容的签名身份。签名回归测试在临时应用副本中运行：

```sh
./scripts/test-signing.sh
```

该测试会调用签名脚本，可能创建或解锁本机专用钥匙串，不在普通 CI 中运行。

## GitHub 自动检查

[CI 工作流](../.github/workflows/ci.yml)在推送至 `main`、Pull Request 和手动触发时执行：工具链信息、Shell 语法与 plist 检查、Swift Testing 测试、release 编译。

使用 `macos-26` 运行器和只读仓库权限，不需要签名私钥，不运行应用，不创建发行包。运行器标签依据 [GitHub 官方镜像说明](https://github.com/actions/runner-images)，checkout 版本依据 [官方 action](https://github.com/actions/checkout)。远端首次执行结果需在推送后查看 Actions。

## 首次推送源码

本地仓库初始化后，可先检查待提交内容，再创建首次提交：

```sh
git status --short
git add .
git diff --cached --stat
git commit -m "chore: prepare iPaste for open source"
```

在 GitHub 创建一个空仓库，避免同时生成 README 或许可证。随后按照 GitHub 页面给出的仓库 URL 添加 `origin` 并推送 `main`。不要把 `.build/`、`build/`、用户数据库、证书或环境配置强制加入 Git。

仓库创建后，在 **Settings → Code security** 开启 Private vulnerability reporting；私下报告入口说明见[安全政策](../SECURITY.md)。

## 应用发行

当前构建脚本负责本机打包和代码签名。面向其他用户的 Developer ID hardened runtime、时间戳、公证、staple 和 Gatekeeper 验证尚未自动化；本机签名成功不能视为已完成公开发行验证。

发布前应完成：

1. 同步 `Resources/Info.plist` 的显示版本和构建号，更新[版本记录](../CHANGELOG.md)。
2. 执行自动测试、release 构建及签名回归，按[测试说明](TESTING.md)检查核心交互。
3. 使用发行专用 Developer ID 配置完成签名、公证和干净机器验证，不上传私钥。
4. 检查发行包只包含应用，标明支持的架构、系统范围与未验证项。
5. 创建对应 Git 标签并将发行包上传 GitHub Releases；源码树中保留生成脚本。

本机构建默认使用当前机器的架构，不代表通用二进制。Intel 和旧系统兼容性需要实际验证后再声明支持范围。
