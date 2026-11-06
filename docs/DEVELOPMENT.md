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

对外名称为 OpenPaste；内部模块 `ClipShelf`、Bundle ID `io.clipshelf.app`、历史目录 `ClipShelf` 及原有 `iPaste` 本机签名目录和证书保留，以兼容已有历史、偏好设置和授权。源码仓库地址暂沿用 `Junp0/iPaste`。

## 运行进程与内存边界

同一个签名可执行文件按角色运行，不增加新的应用标识或网络服务：

| 角色 | 生命周期 | 职责 |
| --- | --- | --- |
| `ResidentAppDelegate` / `ClipboardMonitor` | 应用启动到退出 | 菜单栏、全局快捷键、检查剪贴板变化和任务调度；不加载历史列表或原始剪贴板数据 |
| `AppDelegate`，`--shelf-interface` | 有用户窗口或粘贴任务时 | 原有 SwiftUI 界面、设置、预览、搜索及粘贴；所有窗口关闭后握手退出 |
| `CaptureWorker`，`--capture-worker` | 一次捕获 | 读取剪贴板快照、过滤敏感标记、生成缩略图并保存 SQLite，然后退出 |

控制消息仅通过继承的匿名管道传输，剪贴板载荷直接写入本机数据库。快捷键注册仍由常驻进程拥有；剪贴板恢复先等待常驻进程暂停捕获的确认，写入后同步 change count，避免把恢复的内容当成外部新复制。通过进程 ID 和 Bundle ID 一起排除应用自身的搜索、设置字段。

捕获任务串行运行；有新变化时只保留最新待处理快照，源应用和 change count 在读取前后校验。未响应的任务五秒后终止，防止挂起的 promised flavor 长期保留进程。UI 和捕获任务不应改为常驻缓存：系统框架与剪贴板缓存即使释放 Swift 对象，也可能继续占用内存。

后台预算适用于所有用户窗口关闭、捕获完成后的空闲状态，须把所有存活 OpenPaste 进程的 physical footprint 合计。窗口打开和大内容处理期间的峰值不受 30 MiB 目标约束。

开发时可直接启动后台模式；先退出已有主实例：

```sh
build/OpenPaste.app/Contents/MacOS/OpenPaste --background
```

加 `--verify-background-memory` 会仅在启动时通过隐藏窗口加载并关闭真实面板和设置，验证匿名管道及界面退出生命周期，不显示窗口、不激活应用；验证后继续正常后台监测，之后快捷键仍会显示正常界面。

```sh
build/OpenPaste.app/Contents/MacOS/OpenPaste --background --verify-background-memory
./scripts/measure-runtime-memory.sh
./scripts/measure-capture-memory.sh
```

## 构建与启动

在仓库根目录执行：

```sh
./scripts/build.sh        # release 编译、生成图标、打包并签名
./scripts/build.sh debug  # debug 应用包
./scripts/run.sh          # 打开 build/OpenPaste.app，不存在时先构建
./scripts/package-release.sh # 将已签名的 build/OpenPaste.app 打包到 release/，生成 app、ZIP 和 DMG
```

`run.sh` 在应用包已存在时直接启动它，不检测源码是否更新。修改代码后请先从菜单栏退出应用，再重新构建；不会自动重启已运行的进程。

分发包统一放在 `release/`，`build/` 保留本机构建产物。DMG 内含 `OpenPaste.app` 和指向 `/Applications` 的“应用程序”快捷入口，提供中英文系统均可读取的固定 Finder 图标布局、中文拖拽安装说明、1×/2× 高清背景及自定义磁盘图标，使用只读 UDZO 压缩。只需重新打包现有应用时，直接运行 `package-release.sh`，不必重新编译，也不修改运行中的应用。

打包需要 Xcode 命令行工具及 Python 3；首次运行会在 `build/dmg-tools/` 创建隔离环境并安装 `scripts/requirements-dmg.txt` 中锁定的两个 Finder 元数据依赖，应用本身不依赖 Python。背景由 `scripts/make-dmg-background.swift` 生成，窗口尺寸和图标位置由 `scripts/configure-dmg.py` 维护。

可显式指定其他已签名应用包作为打包来源：

```sh
./scripts/package-release.sh release/OpenPaste.app
```

脚本检查应用签名及 DMG 校验和，并重新只读挂载成品，验证应用内容与来源一致、快捷入口、背景及图标布局；检查通过后才替换 `release/` 中的 DMG，同时生成 DMG、ZIP 对应的 `SHA256SUMS.txt`。DMG 包装不代表完成 Developer ID 签名或 Apple 公证。

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
git commit -m "chore: prepare OpenPaste for open source"
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
