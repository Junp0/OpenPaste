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

对外名称为 OpenPaste；内部模块 `ClipShelf`、Bundle ID `io.clipshelf.app`、历史目录 `ClipShelf` 及原有 `iPaste` 本机签名目录和证书保留，以兼容已有历史、偏好设置和授权。源码仓库为 [Junp0/OpenPaste](https://github.com/Junp0/OpenPaste)。

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

若开发机存在 `~/Library/Application Support/OpenPaste/ReleaseSigning/`，且其中包含 `OpenPaste-Release.keychain-db`、`keychain-password` 和 `certificate.pem`，默认构建会优先复用这份固定发布身份，以便与 GitHub Release 使用相同证书；显式传入的 `CODE_SIGN_IDENTITY` 优先级更高。发布身份目录存在但不完整时会报错，不回退到旧证书。该目录应仅允许当前用户访问，包含 `identity.p12`、`p12-password` 的完整备份应安全保存，不能提交到仓库。原 `iPaste/CodeSigning/` 目录保留供旧版本恢复使用，配置新的发布身份不会自动重签或替换已安装应用。

辅助功能授权通常可以跨版本保留，前提是应用保持兼容的代码签名身份（designated requirement）和 Bundle ID，并在原位置替换安装。当前自签名应用的身份绑定到证书指纹，因此必须复用原证书；新生成同名证书或改用 Developer ID 证书都不能视为相同身份，已有用户可能需要重新授权一次。用户主动撤销授权、重置隐私设置或系统行为变化也可能导致重新授权，不能保证所有机器永远免授权。签名回归测试验证不同内容的两个版本相互满足签名要求，不会修改真实辅助功能授权，也不替代实际升级测试。身份规则参见 [Apple TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements/)。

## GitHub 自动检查

[CI 工作流](../.github/workflows/ci.yml)在推送至 `main`、Pull Request 和手动触发时执行：工具链信息、Shell 语法与 plist 检查、Swift Testing 测试、release 编译。

使用 `macos-26` 运行器和只读仓库权限，不需要签名私钥，不运行应用，不创建发行包。运行器标签依据 [GitHub 官方镜像说明](https://github.com/actions/runner-images)，checkout 版本依据 [官方 action](https://github.com/actions/checkout)。远端首次执行结果需在推送后查看 Actions。

## GitHub 标签自动发布

[Release 工作流](../.github/workflows/release.yml)在推送 `v*` 标签时触发，只接受 `v主版本.次版本.修订号`（如 `v0.6.1`），并要求标签版本与 `Resources/Info.plist` 的 `CFBundleShortVersionString` 一致。普通分支推送仍由 CI 检查，不发布 Release。

工作流使用 `macos-26` 的 Apple Silicon 运行器，依次执行版本及 Secrets 校验、自动测试、固定证书导入、签名构建、DMG/ZIP 打包及校验，最后创建正式 GitHub Release，自动生成更新说明并上传：

- `OpenPaste-<版本>.dmg`
- `OpenPaste-<版本>.zip`
- `SHA256SUMS.txt`

产物仅包含 arm64 架构，部署目标为 macOS 13+；Intel 和旧系统兼容性仍需实际验证。当前流程不执行 Apple 公证；Release 说明也会标明架构与未公证状态，不能据此宣称已通过 Gatekeeper 的公开分发验证。

### 配置 Secrets

在 GitHub 仓库的 **Settings → Secrets and variables → Actions → New repository secret** 添加以下三个 Secrets：

| Secret 名称 | 内容 |
| --- | --- |
| `BUILD_CERTIFICATE_BASE64` | 固定代码签名证书及其私钥导出的 `.p12` 文件的 Base64 内容。 |
| `P12_PASSWORD` | 导出该 `.p12` 时设置的非空密码。 |
| `CODE_SIGN_IDENTITY` | 该证书的完整名称，例如 `Developer ID Application: Your Name (TEAMID)`，或证书的 SHA-1 指纹；不能填 `-`。 |

在“钥匙串访问”的“我的证书”中选择证书及关联私钥，导出为带密码的 `.p12`。可用 `security find-identity -v -p codesigning` 查看有效签名身份；推荐为公开发行使用 Developer ID Application 证书。若继续使用本机自签名证书，应导出并复用原证书及私钥，不要为每次发布重新生成身份。自签名证书不具备 Apple 的分发信任。

注意：当前 `sign-app.sh` 创建本机身份时使用 `security import -x`，私钥被设为不可导出；原始临时 `.p12` 和私钥文件随后会删除。若只有这种钥匙串身份且没有原始 `.p12` 备份，就无法生成 `BUILD_CERTIFICATE_BASE64` 和配套 `P12_PASSWORD`。不能只上传 `certificate.pem` 代替含私钥的 `.p12`。保留原签名身份时，需要在持有私钥的 Mac 上签名（例如专用自托管运行器）；云端签名则需要另一份可导出的固定身份，迁移时可能需要现有用户重新授权。仅修改脚本中的 `-x` 无法让已存在的私钥变得可导出。

将导出的文件转换为 Base64 并复制到剪贴板，然后粘贴到 `BUILD_CERTIFICATE_BASE64`：

```sh
base64 -i /absolute/path/OpenPaste-signing.p12 | pbcopy
```

临时钥匙串密码由工作流随机生成，不需要 `KEYCHAIN_PASSWORD` Secret。Release 上传使用 GitHub 自动提供的 `github.token` 和工作流声明的 `contents: write` 权限，不需要设置个人访问令牌或额外的 `GH_TOKEN` Secret。当前应用不需要 provisioning profile；此流程也不使用 Apple ID 或公证凭据。证书导入参考 [GitHub 官方指南](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)，Release 创建参考 [GitHub CLI 文档](https://cli.github.com/manual/gh_release_create)。

工作流缺少 Secrets 或签名失败时会停止，不会回退到新生成的本机证书；结束时始终尝试删除临时证书和钥匙串。

签名构建后还会运行 `test-signing.sh`，验证内容不同的两个版本能相互满足 designated requirement，并拒绝临时签名或无效身份。

### 发布版本

1. 更新 `Resources/Info.plist` 的显示版本和构建号，更新 `CHANGELOG.md`，将这些变更与 Release 工作流提交并推送。
2. 为该提交创建版本标签并单独推送，例如应用版本为 `0.6.1` 时：

   ```sh
   git tag -a v0.6.1 -m "OpenPaste 0.6.1"
   git push origin v0.6.1
   ```

3. 在 GitHub 的 **Actions → Release** 查看运行结果，完成后可在 **Releases** 下载附件。

不支持 `v0.6.1-beta.1` 等预发布标签。版本不匹配时应先修正版本并提交，再创建新的对应标签。发布前失败且没有创建 Release 时，可在 Actions 中选择 **Re-run failed jobs**；若上传中断并留下同标签的草稿 Release，应先检查并删除该草稿后再重跑。已发布的版本应通过新版本号发布更新，不覆盖现有 Release。请直接从本机推送标签；其他工作流用默认 `GITHUB_TOKEN` 推送标签不会触发此发布工作流。

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
5. 配置上述 Secrets，创建对应 Git 标签并推送，由 Release 工作流打包上传 GitHub Releases；源码树中保留生成脚本。需要公证的公开发行应先扩展工作流完成第 3 步。

本机构建默认使用当前机器的架构，不代表通用二进制。Intel 和旧系统兼容性需要实际验证后再声明支持范围。
