import AppKit
import CryptoKit
import Darwin
import Security

enum UpdateInstallError: LocalizedError, Equatable {
    case unwritableLocation, missingChecksum, invalidDownload, invalidBundle, incompatibleSystem
    case invalidSignature, cannotStartHelper, unconfirmedHandoff, quitTimeout, launchFailed, rollbackFailed(String)

    var errorDescription: String? {
        switch self {
        case .unwritableLocation: return "无法在当前位置安装更新。请从可写的“应用程序”目录运行 OpenPaste。"
        case .missingChecksum: return "发布中缺少此安装包的 SHA-256 校验值。"
        case .invalidDownload: return "安装包下载失败或校验不一致，请重试。"
        case .invalidBundle: return "安装包中的应用与预期版本不一致。"
        case .incompatibleSystem: return "新版应用不支持当前 macOS 版本。"
        case .invalidSignature: return "安装包的代码签名与当前应用不兼容。请从 GitHub 发布页面查看安装说明。"
        case .cannotStartHelper: return "无法启动更新程序，请重试。"
        case .unconfirmedHandoff: return "未收到更新程序的确认，请查看 OpenPaste 是否已重新启动。"
        case .quitTimeout: return "旧版 OpenPaste 未能退出，已取消更新。"
        case .launchFailed: return "新版无法启动，已恢复旧版。"
        case .rollbackFailed(let path): return "无法自动恢复旧版。旧版副本保留在 \(path)。"
        }
    }
}

enum UpdateInstaller {
    static let maximumArchiveSize: Int64 = 256 * 1024 * 1024
    private static let bundleIdentifier = "io.clipshelf.app"

    static func sha256Digest(_ value: String) -> String? {
        guard let digest = value.split(separator: ":", omittingEmptySubsequences: false).last,
              value.hasPrefix("sha256:"), value.utf8.count == 71,
              digest.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
        return digest.lowercased()
    }

    static func checksum(for filename: String, in text: String) -> String? {
        let values = text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, fields[1] == filename || fields[1] == "*\(filename)" else { return nil }
            return String(fields[0])
        }
        guard values.count == 1 else { return nil }
        return sha256Digest("sha256:" + values[0])
    }

    private static var installedApp: URL { Bundle.main.bundleURL.resolvingSymlinksInPath() }
    private static func stagingDirectory(id: UUID, beside app: URL) -> URL {
        app.deletingLastPathComponent().appendingPathComponent(".openpaste-update-\(id.uuidString)", isDirectory: true)
    }

    static func removeStage(id: UUID) {
        try? FileManager.default.removeItem(at: stagingDirectory(id: id, beside: installedApp))
    }

    static func prepare(id: UUID, asset: UpdateAsset, version: ReleaseVersion,
                        verifying: @MainActor () -> Void) async throws {
        let app = installedApp
        let files = FileManager.default
        guard Bundle.main.bundleIdentifier == bundleIdentifier, app.pathExtension == "app",
              files.isWritableFile(atPath: app.deletingLastPathComponent().path) else {
            throw UpdateInstallError.unwritableLocation
        }
        let stage = stagingDirectory(id: id, beside: app)
        do {
            try files.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch { throw UpdateInstallError.unwritableLocation }

        do {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 300
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let expectedHash: String
            if let digest = asset.digest {
                expectedHash = digest
            } else {
                guard let url = asset.checksumsURL else { throw UpdateInstallError.missingChecksum }
                let (data, response) = try await session.data(from: url)
                guard validDownload(response), data.count <= 64 * 1024,
                      let checksums = String(data: data, encoding: .utf8),
                      let digest = checksum(for: asset.url.lastPathComponent, in: checksums) else {
                    throw UpdateInstallError.missingChecksum
                }
                expectedHash = digest
            }

            let (archive, response) = try await session.download(from: asset.url)
            defer { try? files.removeItem(at: archive) }
            guard validDownload(response),
                  try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) == asset.size else {
                throw UpdateInstallError.invalidDownload
            }
            try Task.checkCancellation()
            await verifying()
            guard try hash(archive) == expectedHash else { throw UpdateInstallError.invalidDownload }
            // bsdtar refuses path traversal and symlink escapes by default.
            try runTool("/usr/bin/tar", ["-xf", archive.path, "-C", stage.path])
            try validate(candidate: stage.appendingPathComponent("OpenPaste.app"), replacing: app, version: version)
            try Task.checkCancellation()
        } catch {
            try? files.removeItem(at: stage)
            throw error
        }
    }

    private static func validDownload(_ response: URLResponse) -> Bool {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url?.scheme == "https", let host = response.url?.host else { return false }
        return host == "github.com" || host.hasSuffix(".githubusercontent.com")
    }

    static func hash(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func validate(candidate: URL, replacing installed: URL, version: ReleaseVersion) throws {
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures)
        var currentCode: SecStaticCode?
        var candidateCode: SecStaticCode?
        var requirement: SecRequirement?
        var signingInfo: CFDictionary?
        guard candidate.resolvingSymlinksInPath().path == candidate.path,
              SecStaticCodeCreateWithPath(installed as CFURL, [], &currentCode) == errSecSuccess,
              let currentCode,
              SecStaticCodeCheckValidity(currentCode, flags, nil) == errSecSuccess,
              SecCodeCopySigningInformation(currentCode, SecCSFlags(rawValue: kSecCSSigningInformation), &signingInfo) == errSecSuccess,
              let certificates = (signingInfo as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate],
              !certificates.isEmpty,
              SecCodeCopyDesignatedRequirement(currentCode, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCreateWithPath(candidate as CFURL, [], &candidateCode) == errSecSuccess,
              let candidateCode,
              SecStaticCodeCheckValidity(candidateCode, flags, requirement) == errSecSuccess else {
            throw UpdateInstallError.invalidSignature
        }

        guard let old = Bundle(url: installed), old.bundleIdentifier == bundleIdentifier,
              let oldVersion = old.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let current = ReleaseVersion(oldVersion), version > current,
              let next = Bundle(url: candidate), next.bundleIdentifier == bundleIdentifier,
              next.executableURL?.lastPathComponent == "OpenPaste",
              next.executableArchitectures?.contains(NSNumber(value: CPU_TYPE_ARM64)) == true,
              let newVersion = next.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              ReleaseVersion(newVersion) == version,
              let minimum = next.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String else {
            throw UpdateInstallError.invalidBundle
        }
        var components = minimum.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard (1...3).contains(components.count) else { throw UpdateInstallError.invalidBundle }
        while components.count < 3 { components.append("0") }
        guard let parsed = ReleaseVersion(components.joined(separator: ".")) else {
            throw UpdateInstallError.invalidBundle
        }
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: parsed.major, minorVersion: parsed.minor, patchVersion: parsed.patch)
        ) else { throw UpdateInstallError.incompatibleSystem }
    }

    static func startHelper(id: UUID, version: ReleaseVersion, childPIDs: [pid_t]) throws {
        guard let executable = Bundle.main.executableURL else { throw UpdateInstallError.cannotStartHelper }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--install-update", id.uuidString, version.description, String(getpid())]
            + childPIDs.map { String($0) }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { throw UpdateInstallError.cannotStartHelper }
    }

    @MainActor static func runHelper(arguments: [String]) {
        guard arguments.count >= 3, let id = UUID(uuidString: arguments[0]),
              let version = ReleaseVersion(arguments[1]) else { return }
        let pids = arguments.dropFirst(2).compactMap { pid_t($0) }
        guard pids.count == arguments.count - 2, pids.allSatisfy({ $0 > 1 && $0 != getpid() }) else { return }

        let app = installedApp
        let stage = stagingDirectory(id: id, beside: app)
        let stagedApp = stage.appendingPathComponent("OpenPaste.app")
        var preserveBackup = false
        defer { if !preserveBackup { try? FileManager.default.removeItem(at: stage) } }
        do {
            let deadline = ProcessInfo.processInfo.systemUptime + 15
            while pids.contains(where: { kill($0, 0) == 0 || errno == EPERM }) {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw UpdateInstallError.quitTimeout }
                Thread.sleep(forTimeInterval: 0.05)
            }

            do {
                try validate(candidate: stagedApp, replacing: app, version: version)
                try swap(stagedApp, app)
            } catch {
                try? runTool("/usr/bin/open", [app.path])
                throw error
            }

            do {
                try runTool("/usr/bin/open", ["-n", app.path])
            } catch {
                do { try swap(stagedApp, app) }
                catch {
                    preserveBackup = true
                    throw UpdateInstallError.rollbackFailed(stagedApp.path)
                }
                try? runTool("/usr/bin/open", [app.path])
                throw UpdateInstallError.launchFailed
            }
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "无法完成 OpenPaste 更新"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "知道了")
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    private static func swap(_ first: URL, _ second: URL) throws {
        let result = first.path.withCString { firstPath in
            second.path.withCString { secondPath in
                renameatx_np(AT_FDCWD, firstPath, AT_FDCWD, secondPath, UInt32(RENAME_SWAP))
            }
        }
        guard result == 0 else {
            let code = errno
            if code == EACCES || code == EPERM || code == EROFS { throw UpdateInstallError.unwritableLocation }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
    }

    private static func runTool(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw UpdateInstallError.invalidBundle
        }
    }
}
