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

需要准备公证的发行构建时，显式指定 `CODE_SIGN_MODE=developer-id`、`CODE_SIGN_IDENTITY` 和 `APPLE_TEAM_ID`；该模式启用 Hardened Runtime、安全时间戳，并验证 Apple Developer ID 证书链和所属团队。单独指定签名身份不等于完成公证。

独立钥匙串可通过 `CODE_SIGN_KEYCHAIN=/path/to/signing.keychain-db` 指定。更新时应继续使用兼容的签名身份。签名回归测试在临时应用副本中运行：

```sh
./scripts/test-signing.sh
```

该测试会调用签名脚本，可能创建或解锁本机专用钥匙串，不在普通 CI 中运行。

若开发机存在 `~/Library/Application Support/OpenPaste/ReleaseSigning/`，且其中包含 `OpenPaste-Release.keychain-db`、`keychain-password` 和 `certificate.pem`，默认构建会优先复用这份固定发布身份，以便与 GitHub Release 使用相同证书；显式传入的 `CODE_SIGN_IDENTITY` 优先级更高。发布身份目录存在但不完整时会报错，不回退到旧证书。该目录应仅允许当前用户访问，包含 `identity.p12`、`p12-password` 的完整备份应安全保存，不能提交到仓库。原 `iPaste/CodeSigning/` 目录保留供旧版本恢复使用，配置新的发布身份不会自动重签或替换已安装应用。

辅助功能授权通常可以跨版本保留，前提是应用保持兼容的代码签名身份（designated requirement）和 Bundle ID，并在原位置替换安装。当前自签名应用的身份绑定到证书指纹，因此必须复用原证书；新生成同名证书或改用 Developer ID 证书都不能视为相同身份，已有用户可能需要重新授权一次。用户主动撤销授权、重置隐私设置或系统行为变化也可能导致重新授权，不能保证所有机器永远免授权。签名回归测试验证不同内容的两个版本相互满足签名要求，不会修改真实辅助功能授权，也不替代实际升级测试。身份规则参见 [Apple TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements/)。

## GitHub 自动检查

[CI 工作流](../.github/workflows/ci.yml)在推送至 `main`、Pull Request 和手动触发时执行：工具链信息、Shell 语法与 plist 检查、Swift Testing 测试、公证流程的模拟失败回归、release 编译。公证回归可用 `python3 scripts/test-notarization.py` 单独运行，不需要 Apple 凭据，也不访问公证服务。

使用 `macos-26` 运行器和只读仓库权限，不需要签名私钥，不运行应用，不创建发行包。运行器标签依据 [GitHub 官方镜像说明](https://github.com/actions/runner-images)，checkout 版本依据 [官方 action](https://github.com/actions/checkout)。远端首次执行结果需在推送后查看 Actions。

## GitHub 标签自动发布

[Release 工作流](../.github/workflows/release.yml)在推送 `v*` 标签时触发，只接受 `v主版本.次版本.修订号`（如 `v0.6.1`），并要求标签版本与 `Resources/Info.plist` 的 `CFBundleShortVersionString` 一致。普通分支推送仍由 CI 检查，不发布 Release。

工作流使用 `macos-26` 的 Apple Silicon 运行器，依次执行：

1. 校验版本、发布模式和所需 Secrets，运行自动测试。
2. 导入配置的固定签名证书，校验它与 `CODE_SIGN_IDENTITY` 匹配；不生成新的临时身份。
3. 签名构建并验证跨版本身份兼容性。
4. 生成 DMG 和 ZIP，验证签名、挂载后的应用内容及最终 SHA-256 校验和。
5. 创建正式 GitHub Release 并上传附件，说明签名与公证状态。

**默认使用固定自签名模式**，只需要原来的三个签名 Secrets，不需要付费 Apple 账号。持续复用同一份 `.p12` 和签名身份，保持 Bundle ID 和兼容的签名要求，不要为每次发布重新生成证书。首次从互联网下载时可能出现 Gatekeeper 提示，用户可按 [README 安装说明](../README.md#快速开始)选择“仍要打开”。

发布模式由 Repository Variable **`RELEASE_SIGNING_MODE`** 控制。在 **Settings → Secrets and variables → Actions → Variables** 设置：

| 值 | 行为 |
| --- | --- |
| 未设置或 `self-signed` | 固定自签名，使用三个签名 Secrets，跳过 Apple 公证。 |
| `developer-id` | 使用 Developer ID 签名和 Apple 公证，需要六项 Secrets。 |

变量只接受这两个值，拼写错误会停止发布。启用公证模式后，公证或凭据失败会停止发布，不会降级为自签名。

最终附件为：

- `OpenPaste-<版本>.dmg`
- `OpenPaste-<版本>.zip`
- `SHA256SUMS.txt`

产物仅包含 arm64 架构，部署目标为 macOS 13+；Intel 和旧系统兼容性仍需实际验证。自签名模式的 Release 会明确注明未公证，并链接“仍要打开”的安装说明。

### 可选：启用 Developer ID 和 Apple 公证

先准备以下 Apple 账号、证书及六项 Secrets，再将 `RELEASE_SIGNING_MODE` 设为 `developer-id`。公证模式会从 [Apple PKI](https://www.apple.com/certificateauthority/) 加载 Developer ID 中间证书，验证有效 Apple 证书链和 Team ID，并启用 Hardened Runtime 与安全时间戳。随后先公证应用并附加票据，再从带票据的应用生成 ZIP 和 DMG；最后签名、公证和附加 DMG 票据，重新计算最终校验和。只有应用和 DMG 的签名、票据及 Gatekeeper 检查全部通过后才会发布。

本流程采用 **Apple ID + App 专用密码** 认证，不需要 App Store Connect API Key：

1. 准备已启用双重认证、且已加入有效 **Apple Developer Program** 开发团队的 Apple 账号。免费开发账号不能签发本流程需要的 Developer ID 证书。普通 GitHub Releases 分发不要求提交 Mac App Store 审核，也不需要创建商店 App 记录。
2. 由团队的 **Account Holder** 在 [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/certificates/list) 创建 **Developer ID Application** 证书。在持有私钥的 Mac 上生成 CSR，上传 CSR、下载并安装 Apple 签发的 `.cer`，然后从“钥匙串访问 → 我的证书”将该证书和关联私钥一起导出为带非空密码的 `.p12`。不要选择 Developer ID Installer、Apple Development、Mac App Distribution 或自签名证书。[Apple 证书说明](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)
3. 在 Apple Developer 的账号 Membership details 中找到 10 位 **Team ID**；它必须与签名证书所属团队一致，不是 App Store Connect 的数字 Provider ID。
4. 在 [Apple 账号](https://account.apple.com/)的“登录与安全 → App 专用密码”生成一个供 OpenPaste 公证使用的专用密码。公证账号必须有相应开发团队权限；不要填写 Apple 账号的主密码或双重认证验证码。

当前 OpenPaste 的应用标识仍为 `io.clipshelf.app`，无需为了公证更换 Bundle ID；现有功能也不需要额外的 provisioning profile 或 Developer ID Installer 证书。公证要求及认证方式参考 [Apple 公证准备指南](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)和[自定义公证流程](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)。

### 配置 Secrets

在 GitHub 仓库的 **Settings → Secrets and variables → Actions** 配置 Repository Secrets。**默认自签名模式只需要前三项，继续使用现有值即可。** 以后启用公证时，再把前三项整组替换为 Apple Developer ID 证书资料，并补充后三项：

| Secret 名称 | 内容 |
| --- | --- |
| `BUILD_CERTIFICATE_BASE64` | 固定签名证书及私钥导出的 `.p12` 文件的 Base64；公证模式必须使用 **Developer ID Application** 证书。 |
| `P12_PASSWORD` | 导出该 `.p12` 时设置的非空密码。 |
| `CODE_SIGN_IDENTITY` | 对应证书的完整名称或 SHA-1 指纹；不能填 `-`。 |
| `APPLE_ID` | 仅公证模式需要：具有开发团队公证权限的 Apple 账号登录邮箱。 |
| `APPLE_TEAM_ID` | 仅公证模式需要：签名证书所属团队的 10 位大写字母/数字 Team ID。 |
| `APPLE_APP_SPECIFIC_PASSWORD` | 仅公证模式需要：Apple 账号生成的 App 专用密码，不是账号主密码。 |

启用公证时，可用 `security find-identity -v -p codesigning` 查看有效签名身份，选择与导出的 `.p12` 相对应的 `Developer ID Application: ...` 行，并把名称或 40 位 SHA-1 指纹填入 `CODE_SIGN_IDENTITY`。确保同时备份 `.p12` 及其导出密码；只有 `.cer` 文件不足以在 GitHub 上签名。

此前准备在 `~/Library/Application Support/OpenPaste/GitHubReleaseSecrets/` 中的文件可继续用于固定自签名发布。未来接入 Apple 公证时，需要按上述流程申请 Developer ID 证书；自签名证书不能转成 Apple Developer ID 证书。切换工作流模式不会自动替换本地证书或已安装应用。

需要更换证书时，将导出的文件转换为 Base64 并复制到剪贴板，然后粘贴到 `BUILD_CERTIFICATE_BASE64`：

```sh
base64 -i /absolute/path/OpenPaste-Developer-ID.p12 | pbcopy
```

临时钥匙串密码由工作流随机生成，不需要 `KEYCHAIN_PASSWORD` Secret。Release 上传使用 GitHub 自动提供的 `github.token` 和工作流声明的 `contents: write` 权限，不需要设置个人访问令牌或额外的 `GH_TOKEN` Secret。证书导入参考 [GitHub 官方指南](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)，Release 创建参考 [GitHub CLI 文档](https://cli.github.com/manual/gh_release_create)。

工作流缺少 Secrets 或签名失败时会停止，不会回退到新生成的本机证书；结束时始终尝试删除临时证书和钥匙串。

签名构建后还会运行 `test-signing.sh`，验证内容不同的两个版本能相互满足 designated requirement，并拒绝临时签名或无效身份。

### 公证日志与超时

`scripts/notarize-release.py` 先提交并保存 submission ID，再等待结果。应用和 DMG 各默认等待 20 分钟，工作流总时限为 60 分钟。Apple 超时后可能继续处理；脚本会保留提交 ID，停止后续打包或发布，不能把 `In Progress` 当成成功。

每次响应和完整公证日志位于 `build/notarization/`，日志也会打印在 Actions 中。若 Apple 拒绝，会显示具体问题；签名、票据或 Gatekeeper 验证失败同样会阻止 Release。首次公证或 Apple 服务繁忙时可能需要更久，可按需设置步骤的 `NOTARIZATION_TIMEOUT`（例如 `40m`），同时提高工作流总时限；重跑前先用提交 ID 检查 Apple 上一次的处理状态，避免频繁重复提交。可在本机执行 `xcrun notarytool store-credentials OpenPaste-Notary --apple-id <邮箱> --team-id <TeamID>`，按安全提示输入专用密码后，用 `xcrun notarytool info <提交ID> --keychain-profile OpenPaste-Notary` 查询。

### 发布版本

1. 更新 `Resources/Info.plist` 的显示版本和构建号，更新 `CHANGELOG.md`，将这些变更与 Release 工作流提交并推送。
2. 为该提交创建版本标签并单独推送，例如下一个应用版本为 `0.6.2` 时：

   ```sh
   git tag -a v0.6.2 -m "OpenPaste 0.6.2"
   git push origin v0.6.2
   ```

3. 在 GitHub 的 **Actions → Release** 查看运行结果，完成后可在 **Releases** 下载附件。

不支持 `v0.6.1-beta.1` 等预发布标签。版本不匹配时应先修正版本并提交，再创建新的对应标签。发布前失败且没有创建 Release 时，可在 Actions 中选择 **Re-run failed jobs**；若上传中断并留下同标签的草稿 Release，应先检查并删除该草稿后再重跑。已发布的版本应通过新版本号发布更新，不覆盖现有 Release。请直接从本机推送标签；其他工作流用默认 `GITHUB_TOKEN` 推送标签不会触发此发布工作流。

已经发布的 `0.6.1` 使用固定自签名证书，后续自签名发布继续复用这一身份。未来迁移 Developer ID 时应使用新版本号发布，已有用户可能需要重新授予一次辅助功能权限；后续保持兼容身份和安装位置，正常升级通常会保留授权。本机开发包若仍使用不同的自签名身份，反复与正式版互相替换也可能重新触发授权。

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

本机构建和标签 Release 默认使用固定自签名。可通过 `RELEASE_SIGNING_MODE=developer-id` 启用 Developer ID、Hardened Runtime、安全时间戳、公证、staple 和 Gatekeeper 验证；需要先准备有效 Apple 账号、证书及六项 Secrets。真实 Apple 服务验证必须在凭据就绪后完成，模拟测试不能代替首次真实公证和干净机器安装测试。

发布前应完成：

1. 同步 `Resources/Info.plist` 的显示版本和构建号，更新[版本记录](../CHANGELOG.md)。
2. 执行自动测试、release 构建及签名回归，按[测试说明](TESTING.md)检查核心交互。
3. 自签名模式保留固定身份并检查“仍要打开”的安装体验；公证模式使用发行专用 Developer ID 配置完成公证和干净机器验证，不上传私钥。
4. 检查发行包只包含应用，标明支持的架构、系统范围与未验证项。
5. 配置所选模式及对应 Secrets，创建 Git 标签并推送，由 Release 工作流签名、按模式公证、打包并上传 GitHub Releases；源码树中保留生成脚本。

本机构建默认使用当前机器的架构，不代表通用二进制。Intel 和旧系统兼容性需要实际验证后再声明支持范围。
