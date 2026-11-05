import SwiftUI
import Combine
import AppKit
import ApplicationServices
import ServiceManagement

struct PreferencesView: View {
    @ObservedObject var store: ClipboardStore
    @ViewState<Bool> private var trusted = AXIsProcessTrusted()
    @ViewState<Bool> private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @ViewState<Bool> private var clearConfirmation = false
    @ViewState<String?> private var serviceError: String?
    @ViewState<Bool> private var recordingShortcut = false
    private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版" }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 13) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().interpolation(.high)
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("iPaste").font(.system(size: 25, weight: .semibold, design: .rounded))
                        Text("你的下一次粘贴，随手可得。  v\(appVersion)").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 6)
            }
            Section("常规") {
                Toggle("记录剪贴板", isOn: Binding(get: { !store.paused }, set: { store.paused = !$0 }))
                Picker("面板与卡片大小", selection: $store.displaySize) {
                    ForEach(ShelfDisplaySize.allCases) { size in Text(size.title).tag(size) }
                }.pickerStyle(.segmented)
                Text("同时调整面板高度、卡片尺寸和内容字号，默认使用标准尺寸。调整时自动显示实际效果，离开设置后收起预览。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("唤起快捷键")
                    Spacer()
                    ShortcutRecorder(shortcut: store.shortcut, onChange: { store.setShortcut($0) }, onRecordingChange: { recording in
                        recordingShortcut = recording
                        store.shortcutError = nil
                        store.onShortcutRecordingChange?(recording)
                    }, onValidationError: { store.shortcutError = $0 })
                        .frame(width: 200, height: 28)
                    Button("恢复默认") { store.setShortcut(.standard) }
                        .disabled(recordingShortcut || store.shortcut == .standard)
                }
                Text(recordingShortcut ? "正在录入：按下组合键，Esc 取消。" : "默认 ⌘↑ 呼出或收起，⌘↓ 关闭面板。点击上方可自定义组合键，保存后立即生效。")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = store.shortcutError { Text(error).font(.caption).foregroundStyle(.red) }
                Toggle("登录时自动启动", isOn: $launchAtLogin).onChange(of: launchAtLogin) { enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch {
                        serviceError = error.localizedDescription
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
                if SMAppService.mainApp.status == .requiresApproval {
                    Button("在系统设置中允许登录项") { SMAppService.openSystemSettingsLoginItems() }
                }
            }
            Section("直接粘贴") {
                HStack {
                    Label(trusted ? "辅助功能权限已开启" : "需要辅助功能权限", systemImage: trusted ? "checkmark.shield" : "hand.raised")
                        .foregroundStyle(trusted ? .green : .secondary)
                    Spacer()
                    Button(trusted ? "查看权限" : "开启权限") { AppDelegate.requestAccessibility() }
                }
                Text("权限用于向原来的应用发送 ⌘V。不开启也可以记录、搜索和复制内容。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("历史与隐私") {
                Picker("普通历史保留", selection: $store.retentionDays) {
                    Text("7 天").tag(7); Text("30 天").tag(30); Text("90 天").tag(90); Text("不按时间清理").tag(0)
                }
                Text("最多保留 1,000 条普通历史。收藏及分组内容不受此限制。单次复制超过 20 MB 时跳过记录。")
                    .font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 7) {
                    Text("不记录这些应用（每行一个 Bundle ID）").font(.system(size: 12))
                    TextEditor(text: $store.exclusions).font(.system(size: 11, design: .monospaced))
                        .frame(height: 72).padding(5)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.2)))
                    Button("添加当前运行的应用…") { showApplicationPicker() }.font(.caption)
                }
                Text("默认排除常见密码管理器，并跳过带有隐藏或临时标记的剪贴板。其他应用中的敏感文本仍可能被记录，可添加排除规则或暂停记录。数据仅存本机，未额外加密。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("打开数据目录") { NSWorkspace.shared.open(store.dataDirectory) }
                    Spacer()
                    Button("清空普通历史…", role: .destructive) { clearConfirmation = true }
                }
            }
            Section {
                Text("操作：⌘← / ⌘→ 循环切换分组 · ⌘↓ 关闭 · 单击选择 · 双击或回车粘贴 · 空格预览 · ⌘1–9 快速粘贴 · ⇧⌘回车粘贴纯文本 · ⌘⌫ 删除记录。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).scrollContentBackground(.hidden)
            .frame(width: 580, height: 720).background(IPastePanelBackground()).tint(IPasteStyle.accent)
            .onReceive(refreshTimer) { _ in trusted = AXIsProcessTrusted() }
            .alert("清空普通历史？", isPresented: $clearConfirmation) {
                Button("取消", role: .cancel) {}
                Button("清空", role: .destructive) { store.clearHistory() }
            } message: { Text("未收藏、未分组的记录将被删除。此操作无法撤销。") }
            .alert("无法更新登录项", isPresented: Binding(get: { serviceError != nil }, set: { if !$0 { serviceError = nil } })) {
                Button("知道了") { serviceError = nil }
            } message: { Text(serviceError ?? "") }
    }
    private func showApplicationPicker() {
        let menu = NSMenu()
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        let handler = ApplicationPickerHandler { bundle in
            var lines = store.excludedBundles
            lines.insert(bundle); store.exclusions = lines.sorted().joined(separator: "\n")
        }
        for app in apps {
            guard let bundle = app.bundleIdentifier else { continue }
            let item = NSMenuItem(title: app.localizedName ?? bundle, action: #selector(ApplicationPickerHandler.select(_:)), keyEquivalent: "")
            item.representedObject = bundle; item.target = handler; item.image = app.icon
            item.image?.size = NSSize(width: 16, height: 16)
            item.state = store.excludedBundles.contains(bundle) ? .on : .off
            menu.addItem(item)
        }
        // popUp is synchronous: keep the action target alive until the menu closes.
        _ = withExtendedLifetime(handler) { menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) }
    }
}

private final class ApplicationPickerHandler: NSObject {
    let action: (String) -> Void
    init(action: @escaping (String) -> Void) { self.action = action }
    @objc func select(_ sender: NSMenuItem) { if let bundle = sender.representedObject as? String { action(bundle) } }
}
