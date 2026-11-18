import Foundation
import Testing
@testable import ClipShelf

@Suite struct UpdateCheckerTests {
    private let digest = String(repeating: "a", count: 64)

    private func response(_ status: Int = 200, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: GitHubReleaseService.apiURL, statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    private func release(tag: String = "v0.6.4", draft: Bool = false, prerelease: Bool = false,
                         assets: [[String: Any]]? = nil, notes: Any = "更新说明") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "tag_name": tag, "draft": draft, "prerelease": prerelease, "body": notes,
            "assets": assets ?? [["name": "OpenPaste-0.6.4.zip", "state": "uploaded", "size": 2048, "digest": "sha256:\(digest)",
                                   "browser_download_url": "https://github.com/Junp0/OpenPaste/releases/download/v0.6.4/OpenPaste-0.6.4.zip"]]
        ])
    }

    @Test func versionComparisonUsesNumbersAndRejectsUnsupportedTags() throws {
        #expect(try #require(ReleaseVersion("0.6.9")) < #require(ReleaseVersion("v0.6.10")))
        #expect(try #require(ReleaseVersion("0.9.99")) < #require(ReleaseVersion("0.10.0")))
        #expect(try #require(ReleaseVersion("0.99.99")) < #require(ReleaseVersion("1.0.0")))
        #expect(ReleaseVersion("v0.6.3") == ReleaseVersion("0.6.3"))
        for invalid in ["", "开发版", "0.6", "0.6.3.1", "0.6.4-beta", "0.6.4+1", "-1.0.0", "01.2.3", "1..3", "１.2.3", "999999999999999999999.0.0", "1.2.3/path"] {
            #expect(ReleaseVersion(invalid) == nil)
        }
    }

    @Test func newerReleaseIncludesNotesAndValidatedZIPInstaller() async throws {
        let data = try release()
        let service = GitHubReleaseService(supportsDownload: true) { request in
            #expect(request.url == GitHubReleaseService.apiURL)
            #expect(request.httpMethod == "GET")
            #expect(request.timeoutInterval == 20)
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "OpenPaste/0.6.3")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.httpBody == nil)
            return (data, response())
        }
        guard case .available(let result) = try await service.check(currentVersion: "0.6.3") else {
            Issue.record("Expected an update"); return
        }
        #expect(result.version == ReleaseVersion("0.6.4"))
        #expect(result.notes == "更新说明")
        #expect(result.pageURL.absoluteString == "https://github.com/Junp0/OpenPaste/releases/tag/v0.6.4")
        #expect(result.installer?.url.lastPathComponent == "OpenPaste-0.6.4.zip")
    }

    @Test(arguments: ["0.6.4", "0.6.5", "0.10.0", "1.0.0"])
    func equalOrNewerLocalVersionsNeverOfferADowngrade(current: String) async throws {
        let data = try release()
        let service = GitHubReleaseService { _ in (data, response()) }
        #expect(try await service.check(currentVersion: current) == .upToDate)
    }

    @Test func missingInstallerAndUnsupportedArchitectureKeepTheReleasePage() async throws {
        for supportsDownload in [true, false] {
            let data = try release(assets: supportsDownload ? [] : nil, notes: NSNull())
            let service = GitHubReleaseService(supportsDownload: supportsDownload) { _ in (data, response()) }
            guard case .available(let result) = try await service.check(currentVersion: "0.6.3") else {
                Issue.record("Expected an update"); continue
            }
            #expect(result.installer == nil)
            #expect(result.pageURL.host == "github.com")
            #expect(result.notes.isEmpty)
        }
    }

    @Test func unrelatedOrIncompleteAssetsAreNotUsedAsInstallers() async throws {
        let base: [String: Any] = ["name": "OpenPaste-0.6.4.zip", "state": "uploaded", "size": 2048, "digest": "sha256:\(digest)",
                                   "browser_download_url": "https://github.com/Junp0/OpenPaste/releases/download/v0.6.4/OpenPaste-0.6.4.zip"]
        let changes: [[String: Any]] = [
            ["browser_download_url": "https://example.com/OpenPaste-0.6.4.zip"],
            ["browser_download_url": "https://github.com/other/OpenPaste/releases/download/v0.6.4/OpenPaste-0.6.4.zip"],
            ["browser_download_url": "http://github.com/Junp0/OpenPaste/releases/download/v0.6.4/OpenPaste-0.6.4.zip"],
            ["browser_download_url": "https://github.com/Junp0/OpenPaste/releases/download/v0.6.3/OpenPaste-0.6.4.zip"],
            ["name": "OpenPaste-0.6.4.dmg"], ["state": "starter"], ["size": 0],
            ["digest": "sha256:invalid"], ["size": UpdateInstaller.maximumArchiveSize + 1]
        ]
        for change in changes {
            let asset = base.merging(change) { _, value in value }
            let data = try release(assets: [asset])
            let service = GitHubReleaseService(supportsDownload: true) { _ in (data, response()) }
            guard case .available(let result) = try await service.check(currentVersion: "0.6.3") else {
                Issue.record("Expected an update"); continue
            }
            #expect(result.installer == nil)
        }
    }

    @Test func zipFromOlderReleasesCanUseOnlyTheMatchingPublishedChecksum() async throws {
        let assets: [[String: Any]] = [
            ["name": "OpenPaste-0.6.4.zip", "state": "uploaded", "size": 2048,
             "browser_download_url": "https://github.com/Junp0/OpenPaste/releases/download/v0.6.4/OpenPaste-0.6.4.zip"],
            ["name": "SHA256SUMS.txt", "state": "uploaded", "size": 180,
             "browser_download_url": "https://github.com/Junp0/OpenPaste/releases/download/v0.6.4/SHA256SUMS.txt"]
        ]
        let data = try release(assets: assets)
        let service = GitHubReleaseService(supportsDownload: true) { _ in (data, response()) }
        guard case .available(let result) = try await service.check(currentVersion: "0.6.3") else {
            Issue.record("Expected an update"); return
        }
        let installer = try #require(result.installer)
        #expect(installer.digest == nil)
        #expect(installer.checksumsURL?.lastPathComponent == "SHA256SUMS.txt")
        let filename = installer.url.lastPathComponent
        #expect(UpdateInstaller.checksum(for: filename, in: "\(digest)  old.zip\n\(digest.uppercased()) *\(filename)\n") == digest)
        #expect(UpdateInstaller.checksum(for: filename, in: "\(digest)  unrelated.zip") == nil)
        #expect(UpdateInstaller.checksum(for: filename, in: "\(digest)  \(filename)\n\(digest)  \(filename)") == nil)
    }

    @Test func draftsPrereleasesAndMalformedResponsesAreNotOffered() async throws {
        let payloads = try [release(draft: true), release(prerelease: true), release(tag: "v0.7.0-beta"),
                            release(tag: "unexpected"), Data("not json".utf8), Data("{}".utf8)]
        for data in payloads {
            let service = GitHubReleaseService { _ in (data, response()) }
            await #expect(throws: UpdateCheckError.self) { try await service.check(currentVersion: "0.6.3") }
        }
    }

    @Test func missingReleaseRateLimitsAndServerErrorsHaveDistinctResults() async throws {
        let missing = GitHubReleaseService { _ in (Data(), response(404)) }
        #expect(try await missing.check(currentVersion: "0.6.3") == .noRelease)
        for (status, headers) in [(429, [:]), (403, ["X-RateLimit-Remaining": "0"]), (403, ["Retry-After": "60"])] {
            let limited = GitHubReleaseService { _ in (Data(), response(status, headers: headers)) }
            do {
                _ = try await limited.check(currentVersion: "0.6.3")
                Issue.record("Expected rate limit")
            } catch UpdateCheckError.rateLimited {} catch { Issue.record(error) }
        }
        for status in [403, 500, 503] {
            let failed = GitHubReleaseService { _ in (Data(), response(status)) }
            do {
                _ = try await failed.check(currentVersion: "0.6.3")
                Issue.record("Expected server error")
            } catch UpdateCheckError.httpStatus(let code) { #expect(code == status) }
        }
    }

    @Test func unknownLocalVersionDoesNotSendANetworkRequest() async {
        let service = GitHubReleaseService { _ in
            Issue.record("Unknown versions must not send a request")
            throw URLError(.badURL)
        }
        await #expect(throws: UpdateCheckError.self) { try await service.check(currentVersion: "开发版") }
    }

    @Test @MainActor func checkerStartsOnlyOnRequestAndCanRetryNetworkFailures() async throws {
        var calls = 0
        let data = try release()
        let checker = UpdateChecker(currentVersion: "0.6.3", service: GitHubReleaseService { _ in
            calls += 1
            if calls == 1 { throw URLError(.notConnectedToInternet) }
            return (data, response())
        })
        #expect(checker.state == .idle)
        #expect(calls == 0)
        await checker.check()?.value
        guard case .failed(let message) = checker.state else { Issue.record("Expected failure"); return }
        #expect(message.contains("检查更新失败"))
        await checker.check()?.value
        guard case .finished(.available) = checker.state else { Issue.record("Expected retry success"); return }
        #expect(calls == 2)
    }

    @Test @MainActor func closingSettingsCancelsChecksAndIgnoresLateResults() async throws {
        let data = try release()
        var continuation: CheckedContinuation<Void, Never>?
        let checker = UpdateChecker(currentVersion: "0.6.3", service: GitHubReleaseService { _ in
            await withCheckedContinuation { continuation = $0 }
            return (data, response())
        })
        let task = try #require(checker.check())
        #expect(checker.isChecking)
        #expect(checker.check() == nil)
        while continuation == nil { await Task.yield() }
        checker.cancel()
        #expect(checker.state == .idle)
        continuation?.resume()
        await task.value
        #expect(checker.state == .idle)
    }
}
