# 贡献指南

欢迎提交问题反馈和 Pull Request。讨论可以使用中文或英文。

## 问题反馈

请提供 iPaste 版本、macOS 版本、芯片架构、复现步骤，以及预期和实际行为。界面问题可附脱敏截图；快捷键和粘贴问题请说明目标应用、输入法及辅助功能授权状态。

请使用虚构内容复现，不要上传真实剪贴板数据库、密码、令牌、私密文档或本机签名资料。安全漏洞请遵循[安全问题报告说明](SECURITY.md)。

## 开发流程

1. Fork 仓库，从 `main` 新建功能分支。
2. 按[开发指南](docs/DEVELOPMENT.md)准备 Swift 和 macOS SDK。
3. 保持改动聚焦；修改行为时同步更新相关文档。
4. 执行 `./scripts/test.sh` 和 `swift build -c release`。涉及 `.app` 打包时再执行 `./scripts/build.sh`；涉及签名时执行 `./scripts/test-signing.sh`。
5. 在 PR 中描述问题、改动后行为、验证结果与尚未覆盖的环境。

界面变更请附使用虚构内容的截图或录屏，并说明检查过的系统外观和辅助功能设置。不要在个人剪贴板历史上进行删除、清空或迁移测试。

## 代码约定

- 沿用相邻 Swift 代码的风格，不引入无关格式变更。
- 数据模型与 SQLite 逻辑放在 `ClipboardCore`，AppKit / SwiftUI 交互放在 `ClipShelf`。
- 保持 macOS 13 部署目标；较新 API 使用可用性检查并提供回退。
- 测试使用 Swift Testing、临时数据库和命名剪贴板；避免触碰普通剪贴板和真实用户历史。
- 兼容已有数据库、偏好设置与签名身份；不要仅为统一命名修改 `ClipShelf` 数据目录或 `io.clipshelf.app` Bundle ID。
- 增加依赖前，请在 Issue 或 PR 中说明用途及系统框架无法满足的原因。

贡献内容按仓库的 [MIT 许可证](LICENSE)提供。
