import SwiftUI

struct UpdateSettingsView: View {
    @ObservedObject var checker: UpdateChecker

    var body: some View {
        Section("软件更新") {
            HStack {
                Text("当前版本：\(checker.currentVersion)")
                Spacer()
                if checker.isChecking { ProgressView().controlSize(.small) }
                Button(checker.isChecking ? "正在检查…" : "检查更新") { checker.check() }
                    .disabled(checker.isBusy)
            }
            switch checker.state {
            case .idle:
                Text("点击检查 GitHub 上的最新正式版本。")
                    .font(.caption).foregroundStyle(.secondary)
            case .checking:
                Text("正在连接 GitHub…").font(.caption).foregroundStyle(.secondary)
            case .finished(.upToDate):
                Label("当前已是最新版本。", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            case .finished(.noRelease):
                Text("暂未找到公开的正式版本，可前往发布页面查看。")
                    .font(.caption).foregroundStyle(.secondary)
            case .finished(.available(let release)):
                Label("发现新版本 v\(release.version.description)", systemImage: "arrow.down.circle")
                    .foregroundStyle(IPasteStyle.accent)
                if !release.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    DisclosureGroup("更新说明") {
                        ScrollView {
                            Text(release.notes).font(.caption).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 120)
                    }
                }
                HStack {
                    if release.installer != nil {
                        Button("下载并安装") { checker.install(release) }.buttonStyle(.borderedProminent)
                    }
                    Link("查看此版本", destination: release.pageURL)
                }
                Text(release.installer != nil
                     ? "安装完成后，OpenPaste 会自动重新启动。"
                     : "此版本暂无适用于本机的一键安装包，请在发布页面查看安装说明。")
                    .font(.caption).foregroundStyle(.secondary)
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(.red)
            case .installing(let phase):
                HStack {
                    ProgressView().controlSize(.small)
                    Text(phase.rawValue)
                }
            case .installFailed(let release, let message):
                Text(message).font(.caption).foregroundStyle(.red)
                HStack {
                    Button("重试安装") { checker.install(release) }
                    Link("查看此版本", destination: release.pageURL)
                }
            }
            Link("GitHub 发布页面", destination: GitHubReleaseService.releasesURL).font(.caption)
            Text("检查和下载更新时会连接 GitHub，不上传剪贴板内容。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
