import AppKit
import ClipboardCore

/// The resident process never loads the history list or creates a SwiftUI view.
/// Original payloads stay in SQLite until the transient interface needs them.
@MainActor final class ClipboardMonitor {
    let database: ClipboardDatabase
    let databaseURL: URL
    private let defaults: UserDefaults
    private var lastChange: Int
    private var lastSource: NSRunningApplication?
    private var timer: Timer?
    private var pruneTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private(set) var paused = false
    private var retentionDays = 30
    private var excludedBundles: Set<String> = []
    private var restoringClipboard = false
    var onCapture: ((Int) -> Void)?
    var onError: ((String) -> Void)?
    var onLargeRead: (() -> Void)?
    var captureRequest: ((Int, NSRunningApplication?) -> Void)?
    var interfaceProcessIdentifier: Int32?

    init(dataDirectory: URL? = nil, monitorsClipboard: Bool = true, defaults: UserDefaults = .standard) throws {
        self.defaults = defaults
        let directory = try dataDirectory ?? FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("ClipShelf", isDirectory: true)
        databaseURL = directory.appendingPathComponent("history.sqlite")
        database = try ClipboardDatabase(url: databaseURL)
        lastChange = monitorsClipboard ? NSPasteboard.general.changeCount : 0
        reloadPreferences()
        try database.prune(retentionDays: retentionDays)
        guard monitorsClipboard else { return }
        lastSource = NSWorkspace.shared.frontmostApplication
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                Task { @MainActor [weak self] in
                    guard let self, !self.isOwnApplication(app) else { return }
                    self.lastSource = app
                }
            }
        timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in autoreleasepool { self?.poll() } }
        }
        pruneTimer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.prune() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        if let pruneTimer { RunLoop.main.add(pruneTimer, forMode: .common) }
    }

    func reloadPreferences() {
        defaults.synchronize()
        defaults.register(defaults: ["retentionDays": 30,
            "exclusions": "com.1password.1password\ncom.agilebits.onepassword7\ncom.bitwarden.desktop\norg.keepassxc.keepassxc"])
        paused = defaults.bool(forKey: "paused")
        retentionDays = defaults.integer(forKey: "retentionDays")
        excludedBundles = Set((defaults.string(forKey: "exclusions") ?? "").split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    }

    func setPaused(_ value: Bool) {
        defaults.set(value, forKey: "paused")
        defaults.synchronize()
        paused = value
    }

    func beginRestore() { restoringClipboard = true }
    func endRestore(changeCount: Int) {
        lastChange = changeCount
        restoringClipboard = false
    }
    func interfaceDidExit() {
        if restoringClipboard { lastChange = NSPasteboard.general.changeCount }
        restoringClipboard = false; reloadPreferences(); prune()
    }
    var targetApplication: NSRunningApplication? {
        let frontmost = NSWorkspace.shared.frontmostApplication
        return isOwnApplication(frontmost) ? lastSource : frontmost ?? lastSource
    }

    func poll() {
        capturePendingChange(from: .general, source: NSWorkspace.shared.frontmostApplication)
    }

    func capturePendingChange(from board: NSPasteboard, source: NSRunningApplication?) {
        guard !restoringClipboard, board.changeCount != lastChange else { return }
        let observedChange = board.changeCount
        lastChange = observedChange
        guard !paused else { return }
        // The temporary interface has a different PID but the same signed app
        // identity. Its search/settings fields must never enter the history.
        guard !isOwnApplication(source) else { return }
        let app = source ?? lastSource
        guard !excludedBundles.contains(app?.bundleIdentifier ?? "") else { return }
        if let captureRequest { captureRequest(observedChange, app); return }
        switch ClipboardCapture.readUncached(board.name, source: app) {
        case .ignored: break
        case .tooLarge: onLargeRead?()
        case .captured(let draft):
            guard board.changeCount == observedChange else { return }
            do {
                try database.save(draft)
                try database.prune(retentionDays: retentionDays)
                let bytes = draft.payload.items.reduce(0) { total, item in
                    total + item.reduce(0) { $0 + $1.data.count }
                }
                onCapture?(bytes)
            } catch { onError?(error.localizedDescription) }
        }
    }

    private func isOwnApplication(_ app: NSRunningApplication?) -> Bool {
        guard let app else { return false }
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier || app.processIdentifier == interfaceProcessIdentifier { return true }
        return Bundle.main.bundleIdentifier.map { app.bundleIdentifier == $0 } ?? false
    }

    private func prune() {
        do { try database.prune(retentionDays: retentionDays) }
        catch { onError?(error.localizedDescription) }
    }
    func capturedInWorker(_ result: CaptureWorkerResult) {
        switch result.status {
        case .captured: prune(); onCapture?(result.bytes)
        case .tooLarge: onLargeRead?()
        case .failed: onError?(result.error ?? "无法读取剪贴板内容。")
        case .ignored, .changed: break
        }
    }
    func stop() {
        timer?.invalidate(); timer = nil
        pruneTimer?.invalidate(); pruneTimer = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
    }
}
