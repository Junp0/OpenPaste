import Foundation
import Combine

/// Release tags follow the same MAJOR.MINOR.PATCH format as release.yml.
struct ReleaseVersion: Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ value: String) {
        let value = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  part.count == 1 || part.first != "0" else { return nil }
            return Int(part)
        }
        guard numbers.count == 3 else { return nil }
        major = numbers[0]; minor = numbers[1]; patch = numbers[2]
    }

    var description: String { "\(major).\(minor).\(patch)" }
    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

struct AppRelease: Equatable {
    let version: ReleaseVersion
    let notes: String
    let pageURL: URL
    let installer: UpdateAsset?
}

struct UpdateAsset: Equatable {
    let url: URL
    let size: Int64
    let digest: String?
    let checksumsURL: URL?
}

enum UpdateResult: Equatable {
    case available(AppRelease)
    case upToDate
    case noRelease
}

enum UpdateCheckError: LocalizedError {
    case unknownCurrentVersion, invalidRelease, rateLimited, httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .unknownCurrentVersion: return "无法识别当前应用版本，请在 GitHub 发布页面查看新版。"
        case .invalidRelease: return "GitHub 返回的版本信息无效，请稍后重试或查看发布页面。"
        case .rateLimited: return "GitHub 请求过于频繁，请稍后重试。"
        case .httpStatus(let status): return "GitHub 暂时无法提供版本信息（HTTP \(status)），请稍后重试。"
        }
    }
}

struct GitHubReleaseService {
    static let releasesURL = URL(string: "https://github.com/Junp0/OpenPaste/releases/latest")!
    static let apiURL = URL(string: "https://api.github.com/repos/Junp0/OpenPaste/releases/latest")!
    typealias Fetch = (URLRequest) async throws -> (Data, URLResponse)
    private let fetch: Fetch
    private let supportsDownload: Bool

    init(supportsDownload: Bool = GitHubReleaseService.isAppleSilicon,
         fetch: @escaping Fetch = GitHubReleaseService.fetchRelease) {
        self.supportsDownload = supportsDownload
        self.fetch = fetch
    }

    static var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    private static func fetchRelease(_ request: URLRequest) async throws -> (Data, URLResponse) {
        // Created only on explicit checks in the short-lived interface process.
        // Do not persist cookies or a cache, or initialize networking in the resident.
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        return try await session.data(for: request)
    }

    func check(currentVersion: String) async throws -> UpdateResult {
        guard let current = ReleaseVersion(currentVersion) else { throw UpdateCheckError.unknownCurrentVersion }
        var request = URLRequest(url: Self.apiURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("OpenPaste/\(current)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await fetch(request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw UpdateCheckError.invalidRelease }
        switch response.statusCode {
        case 200: break
        case 404: return .noRelease
        case 429: throw UpdateCheckError.rateLimited
        case 403 where response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
            || response.value(forHTTPHeaderField: "Retry-After") != nil:
            throw UpdateCheckError.rateLimited
        default: throw UpdateCheckError.httpStatus(response.statusCode)
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: data),
              !release.draft, !release.prerelease, let version = ReleaseVersion(release.tagName) else {
            throw UpdateCheckError.invalidRelease
        }
        guard version > current else { return .upToDate }
        // Derive the page from our repository and validated tag, rather than
        // opening arbitrary URLs supplied in release metadata.
        let page = URL(string: "https://github.com/Junp0/OpenPaste/releases/tag/\(release.tagName)")!
        let base = URL(string: "https://github.com/Junp0/OpenPaste/releases/download/\(release.tagName)/")!
        func uploadedAsset(_ filename: String) -> Asset? {
            release.assets.first {
                $0.name == filename && $0.state == "uploaded" && $0.size > 0
                    && $0.browserDownloadURL == base.appendingPathComponent(filename)
            }
        }
        let checksums = uploadedAsset("SHA256SUMS.txt")?.browserDownloadURL
        let archive = uploadedAsset("OpenPaste-\(version).zip")
        let installer = archive.flatMap { asset -> UpdateAsset? in
            let digest = asset.digest.flatMap(UpdateInstaller.sha256Digest)
            guard supportsDownload, asset.size <= UpdateInstaller.maximumArchiveSize,
                  digest != nil || checksums != nil else { return nil }
            return UpdateAsset(url: asset.browserDownloadURL, size: asset.size, digest: digest, checksumsURL: checksums)
        }
        return .available(AppRelease(version: version, notes: release.body ?? "", pageURL: page,
                                     installer: installer))
    }

    private struct Release: Decodable {
        let tagName: String
        let body: String?
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case body, draft, prerelease, assets
        }
    }
    private struct Asset: Decodable {
        let name: String
        let state: String
        let size: Int64
        let digest: String?
        let browserDownloadURL: URL
        enum CodingKeys: String, CodingKey {
            case name, state, size, digest
            case browserDownloadURL = "browser_download_url"
        }
    }
}

@MainActor final class UpdateChecker: ObservableObject {
    enum State: Equatable {
        case idle, checking, finished(UpdateResult), failed(String)
        case installing(InstallPhase), installFailed(AppRelease, String)
    }
    enum InstallPhase: String, Equatable {
        case downloading = "正在下载更新…"
        case verifying = "正在验证安装包…"
        case restarting = "正在安装并重新启动…"
    }
    @Published private(set) var state: State = .idle
    let currentVersion: String
    private let service: GitHubReleaseService
    private var task: Task<Void, Never>?

    init(currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版",
         service: GitHubReleaseService = GitHubReleaseService()) {
        self.currentVersion = currentVersion
        self.service = service
    }

    var isChecking: Bool { state == .checking }
    var isBusy: Bool { task != nil }
    var handoff: ((UUID, ReleaseVersion) throws -> Void)?

    @discardableResult func check() -> Task<Void, Never>? {
        guard task == nil else { return nil }
        state = .checking
        task = Task { [weak self] in
            do {
                guard let service = self?.service, let version = self?.currentVersion else { return }
                let result = try await service.check(currentVersion: version)
                guard !Task.isCancelled else { return }
                self?.task = nil
                self?.state = .finished(result)
            } catch {
                guard !Task.isCancelled else { return }
                self?.task = nil
                self?.state = .failed("检查更新失败：\(error.localizedDescription)")
            }
        }
        return task
    }

    func install(_ release: AppRelease) {
        guard task == nil, let asset = release.installer, let handoff else { return }
        state = .installing(.downloading)
        task = Task { [weak self] in
            let id = UUID()
            var prepared = false
            do {
                try await UpdateInstaller.prepare(id: id, asset: asset, version: release.version) {
                    if !Task.isCancelled { self?.state = .installing(.verifying) }
                }
                prepared = true
                try Task.checkCancellation()
                self?.state = .installing(.restarting)
                try handoff(id, release.version)
                // The helper owns the prepared bundle after the resident accepts it.
                return
            } catch {
                // An unconfirmed handoff may already have started the helper.
                if prepared, (error as? UpdateInstallError) != .unconfirmedHandoff {
                    UpdateInstaller.removeStage(id: id)
                }
                guard !Task.isCancelled else { return }
                self?.task = nil
                self?.state = .installFailed(release, error.localizedDescription)
            }
        }
    }

    func cancel() {
        if state == .installing(.restarting) { return }
        task?.cancel(); task = nil
        if isChecking { state = .idle }
        if case .installing = state { state = .idle }
    }
    deinit { task?.cancel() }
}
