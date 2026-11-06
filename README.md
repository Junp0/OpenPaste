<p align="center">
  <img src="docs/assets/icon.png" alt="iPaste 图标" width="96" height="96">
</p>

<h1 align="center">iPaste</h1>

<p align="center">原生、离线的 macOS 剪贴板管理工具。<br>Native, offline clipboard history for macOS.</p>

<p align="center">SwiftUI + AppKit · SQLite · 无第三方依赖 · MIT</p>

iPaste 在屏幕底部展示剪贴板历史，帮助你查找、收藏、分组和再次粘贴复制过的内容。数据保存在本机，无账号、遥测或云同步。

## 功能

- **多种内容**：文本、链接、图片和文件引用，保留受支持的原始剪贴板格式。
- **快速检索**：按内容、来源应用及类型搜索，支持中英文类型关键词。
- **收藏与分组**：星标收藏、自定义图标分组，拖拽卡片即可归类。
- **键盘操作**：自定义全局快捷键、方向键导航、快速粘贴、空格预览与纯文本粘贴。
- **原生界面**：底部全宽面板、三档显示大小；macOS 26+ 使用 Liquid Glass，较旧系统回退至系统材质。
- **记录控制**：暂停记录、按应用排除、敏感剪贴板标记过滤、历史保留期限和条数限制。

当前应用版本为 **0.6.0**，仍处于早期开发阶段。部署目标为 **macOS 13+**；已在本机 Apple Silicon 环境验证，旧系统及 Intel 兼容性仍待验证。

## 从源码运行

构建需要 **Swift 6.2+ 和 macOS 26+ SDK**（Xcode 26+ 或相应 Command Line Tools）。构建工具要求与应用最低运行系统不同。

下载或克隆本仓库，在仓库目录执行：

```sh
./scripts/build.sh
./scripts/run.sh
```

生成的应用位于 `build/iPaste.app`。首次构建会在用户的 Application Support 目录创建并复用本机签名身份，详见[构建与签名](docs/DEVELOPMENT.md)。源码仓库不包含预编译应用。

应用驻留菜单栏，不显示 Dock 图标。复制内容后按 **⌘↑** 打开历史，选中卡片后按回车粘贴。

| 操作 | 默认快捷键 |
| --- | --- |
| 打开 / 收起面板 | ⌘↑ |
| 收起面板 | ⌘↓ / Esc |
| 切换分组 | ⌘← / ⌘→ |
| 选择卡片 | 方向键 |
| 粘贴 / 纯文本粘贴 | 回车 / ⇧⌘回车 |
| 快速粘贴前九条 | ⌘1–9 |
| 预览 | 空格 |
| 搜索 / 设置 | ⌘F / ⌘, |

自动粘贴需要在 **系统设置 → 隐私与安全性 → 辅助功能** 中允许 iPaste。未授权时仍能记录、搜索和复制，再手动按 ⌘V 粘贴。长期使用前，建议退出应用，将其移到固定的应用程序目录后再启动并授权。

完整快捷键、搜索语法和交互说明见[使用指南](docs/USAGE.md)。

## 隐私与限制

剪贴板数据存储于 `~/Library/Application Support/ClipShelf/history.sqlite`，**没有额外加密**。默认排除部分密码管理器并忽略常见敏感标记，但不能识别所有密码或敏感文本。

单次受支持格式合计超过 20 MB 时跳过；最多保留 1,000 条普通历史，收藏及分组内容不自动清理。文件仅保存路径引用。当前没有跨设备同步、OCR 或自动更新。

数据路径、权限和完整边界见[隐私说明](docs/PRIVACY.md)。

## 开发与贡献

```sh
./scripts/test.sh       # Swift Testing 自动测试
swift build -c release  # 编译可执行文件，不创建签名身份
```

- [开发指南](docs/DEVELOPMENT.md)：目录结构、构建、签名与发布。
- [测试说明](docs/TESTING.md)：自动测试、手动验证范围与已知缺口。
- [贡献指南](CONTRIBUTING.md)：问题反馈和 Pull Request。
- [版本记录](CHANGELOG.md) · [安全问题](SECURITY.md)。

## 许可证

本项目采用 [MIT License](LICENSE)。iPaste 是独立项目，与 Paste 无隶属或合作关系。
