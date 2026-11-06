import AppKit
import SwiftUI
import ClipboardCore

@MainActor final class ClipboardStore: ObservableObject {
    enum SelectionOrigin { case navigation, pointer, deletion }
    @Published private(set) var records: [ClipRecord] = []
    @Published private(set) var collections: [ClipCollection] = []
    @Published var query = "" { didSet { ensureSelection() } }
    @Published var filter = "all" { didSet { ensureSelection() } }
    @Published var isCreatingCollection = false
    @Published private(set) var draggedRecordID: String?
    @Published var displaySize: ShelfDisplaySize {
        didSet { UserDefaults.standard.set(displaySize.rawValue, forKey: "displaySize"); preferencesDidChange(); onAppearanceChange?() }
    }
    @Published var selectedID: String? { didSet { selectionOrigin = .navigation } }
    private(set) var selectionOrigin = SelectionOrigin.navigation
    @Published var previewID: String?
    @Published var message = "只保存在这台 Mac 上"
    @Published var errorMessage: String?
    @Published var paused: Bool {
        didSet { UserDefaults.standard.set(paused, forKey: "paused"); preferencesDidChange(); onStateChange?() }
    }
    @Published var retentionDays: Int {
        didSet { UserDefaults.standard.set(retentionDays, forKey: "retentionDays"); preferencesDidChange(); prune() }
    }
    @Published var exclusions: String {
        didSet { UserDefaults.standard.set(exclusions, forKey: "exclusions"); preferencesDidChange() }
    }
    @Published private(set) var shortcut: ShelfShortcut
    @Published var shortcutError: String?
    var onStateChange: (() -> Void)?
    var onShortcutChange: ((ShelfShortcut) -> Bool)?
    var onShortcutRecordingChange: ((Bool) -> Void)?
    var onAppearanceChange: (() -> Void)?
    var onDragEnd: ((Bool) -> Void)?
    var onPreferencesChange: (() -> Void)?
    var onBeforeClipboardRestore: (() -> Bool)?
    var onClipboardRestore: ((Int) -> Void)?
    private var refreshingPreferences = false
    let database: ClipboardDatabase
    let dataDirectory: URL
    private var timer: Timer?
    private var pruneTimer: Timer?
    private var lastChange: Int
    private var lastSource: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    private var dragTimer: Timer?
    private var dragGeneration: UInt64 = 0
    private let thumbnailCache = NSCache<NSString, NSImage>()

    init(dataDirectory: URL? = nil, monitorsClipboard: Bool = true) throws {
        thumbnailCache.totalCostLimit = 8 * 1024 * 1024
        thumbnailCache.countLimit = 24
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["retentionDays": 30,
            "exclusions": "com.1password.1password\ncom.agilebits.onepassword7\ncom.bitwarden.desktop\norg.keepassxc.keepassxc"])
        paused = defaults.bool(forKey: "paused")
        retentionDays = defaults.integer(forKey: "retentionDays")
        exclusions = defaults.string(forKey: "exclusions") ?? ""
        shortcut = ShelfShortcut.load(from: defaults)
        displaySize = ShelfDisplaySize.load(from: defaults)
        self.dataDirectory = try dataDirectory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("ClipShelf", isDirectory: true)
        database = try ClipboardDatabase(url: self.dataDirectory.appendingPathComponent("history.sqlite"))
        lastChange = monitorsClipboard ? NSPasteboard.general.changeCount : 0
        lastSource = monitorsClipboard ? NSWorkspace.shared.frontmostApplication : nil
        try database.prune(retentionDays: retentionDays)
        try reload()
        guard monitorsClipboard else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            Task { @MainActor [weak self] in self?.lastSource = app }
        }
        timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in autoreleasepool { self?.poll() } }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        pruneTimer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.prune() }
        }
        if let pruneTimer { RunLoop.main.add(pruneTimer, forMode: .common) }
    }

    var visibleRecords: [ClipRecord] {
        let search = ClipSearch(query)
        return records.filter { record in
            ShelfGroupNavigation.matches(record, group: filter) &&
            search.matches(record)
        }
    }
    var selected: ClipRecord? { visibleRecords.first { $0.id == selectedID } }
    var shortcutLabel: String { shortcut.displayLabel }
    @discardableResult func setShortcut(_ candidate: ShelfShortcut) -> Bool {
        guard candidate.isValid else {
            shortcutError = "请至少包含 Command、Option 或 Control 中的一个修饰键。"; return false
        }
        guard onShortcutChange?(candidate) ?? true else {
            shortcutError = "这个组合键无法注册，可能已被其他应用或系统占用。请换一个，原快捷键已保留。"; return false
        }
        shortcut = candidate; candidate.save(in: .standard); shortcutError = nil
        preferencesDidChange()
        onStateChange?()
        return true
    }
    private func preferencesDidChange() {
        guard !refreshingPreferences else { return }
        UserDefaults.standard.synchronize()
        onPreferencesChange?()
    }
    func reloadPreferences() {
        let defaults = UserDefaults.standard
        defaults.synchronize()
        refreshingPreferences = true
        defer { refreshingPreferences = false }
        if paused != defaults.bool(forKey: "paused") { paused = defaults.bool(forKey: "paused") }
        if retentionDays != defaults.integer(forKey: "retentionDays") { retentionDays = defaults.integer(forKey: "retentionDays") }
        let excluded = defaults.string(forKey: "exclusions") ?? ""
        if exclusions != excluded { exclusions = excluded }
        let size = ShelfDisplaySize.load(from: defaults)
        if displaySize != size { displaySize = size }
        let configured = ShelfShortcut.load(from: defaults)
        if shortcut != configured { shortcut = configured }
    }
    var excludedBundles: Set<String> { Set(exclusions.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }) }
    func count(for filter: String) -> Int {
        records.filter { ShelfGroupNavigation.matches($0, group: filter) }.count
    }
    func prepareToShow() {
        isCreatingCollection = false
        query = ""; filter = "all"; selectedID = visibleRecords.first?.id
        message = paused ? "记录已暂停" : "只保存在这台 Mac 上"
    }
    func capturePendingChange() { autoreleasepool { poll() } }
    func cycleGroup(by offset: Int) { filter = ShelfGroupNavigation.target(current: filter, collections: collections, offset: offset) }
    func ensureSelection() {
        let visible = visibleRecords
        if !visible.contains(where: { $0.id == selectedID }) { selectedID = visible.first?.id }
    }
    func moveSelection(_ offset: Int) {
        let items = visibleRecords
        guard !items.isEmpty else { return }
        let index = items.firstIndex { $0.id == selectedID } ?? 0
        selectedID = items[min(max(index + offset, 0), items.count - 1)].id
    }
    func selectCard(_ record: ClipRecord) {
        guard selectedID != record.id else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            selectedID = record.id
            selectionOrigin = .pointer
        }
    }
    private func poll() {
        let board = NSPasteboard.general
        guard board.changeCount != lastChange else { return }
        let observedChange = board.changeCount
        lastChange = observedChange
        guard !paused else { return }
        // Ignore our own search/settings fields, including while a sheet is open.
        guard NSApp.keyWindow?.isKeyWindow != true else { return }
        let source = NSWorkspace.shared.frontmostApplication
        guard source?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let app = source ?? lastSource
        guard !excludedBundles.contains(app?.bundleIdentifier ?? "") else { return }
        switch ClipboardCapture.read(board, source: app) {
        case .ignored: break
        case .tooLarge: message = "已跳过超过 20 MB 的内容"
        case .captured(let draft):
            // Do not save a mixed snapshot if another app changed the board mid-read.
            guard board.changeCount == observedChange else { return }
            perform {
                try database.save(draft)
                try database.prune(retentionDays: retentionDays)
                try reload()
            }
        }
    }
    func reload() throws {
        records = try database.records(includeThumbnails: false); collections = try database.collections(); ensureSelection()
    }
    func perform(_ operation: () throws -> Void) {
        do { try operation() } catch { errorMessage = error.localizedDescription }
    }
    func prune() { perform { try database.prune(retentionDays: retentionDays); try reload() } }
    func favorite(_ record: ClipRecord) {
        perform { try database.setFavorite(!record.favorite, id: record.id); try reload() }
    }
    func assign(_ id: String?, record: ClipRecord) {
        perform { try database.assign(id, to: record.id); try reload() }
    }
    func beginClipDrag(_ record: ClipRecord) {
        dragTimer?.invalidate()
        dragGeneration &+= 1
        let generation = dragGeneration
        draggedRecordID = record.id; selectedID = record.id
        message = "拖到顶部分组标签，松开即可归类"
        if #available(macOS 26.0, *) { return }
        // Older SwiftUI has no session-ended callback. Detect mouse release,
        // with a grace period so the synchronous drop handler always runs first.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.dragGeneration == generation, self.draggedRecordID != nil else { return }
                if NSEvent.pressedMouseButtons & 1 == 0 {
                    self.dragTimer?.invalidate(); self.dragTimer = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                        guard let self, self.dragGeneration == generation else { return }
                        self.endClipDrag(completedInside: false)
                    }
                }
            }
        }
        dragTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func endClipDrag(completedInside: Bool) {
        guard draggedRecordID != nil else { return }
        dragGeneration &+= 1
        dragTimer?.invalidate(); dragTimer = nil
        draggedRecordID = nil
        if !completedInside { message = "只保存在这台 Mac 上" }
        onDragEnd?(completedInside)
    }
    func canDropDraggedRecord(to target: String) -> Bool {
        guard let id = draggedRecordID, records.contains(where: { $0.id == id }) else { return false }
        return ClipGroupDropOperation.resolve(target: target, collections: collections) != nil
    }
    @discardableResult func dropDraggedRecord(to target: String) -> Bool {
        guard canDropDraggedRecord(to: target), let id = draggedRecordID,
              let operation = ClipGroupDropOperation.resolve(target: target, collections: collections) else { return false }
        do {
            try operation.apply(recordID: id, database: database)
            filter = target
            try reload()
            selectedID = id
            switch operation {
            case .addFavorite: message = "已加入收藏"
            case .removeGroup: message = "已移回全部记录，取消原分组"
            case .move: message = "已移入「\(collections.first(where: { $0.id == target })?.name ?? "分组")」"
            }
            endClipDrag(completedInside: true)
            return true
        } catch {
            errorMessage = error.localizedDescription
            endClipDrag(completedInside: false)
            return false
        }
    }
    func delete(_ record: ClipRecord) {
        guard records.contains(where: { $0.id == record.id }) else { return }
        let visible = visibleRecords
        let remaining = visible.filter { $0.id != record.id }
        let neighbor = visible.firstIndex(where: { $0.id == record.id }).flatMap { index in
            remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
        }
        perform {
            try database.delete(id: record.id)
            thumbnailCache.removeObject(forKey: record.id as NSString)
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            withAnimation(.easeInOut(duration: reduceMotion ? 0.12 : 0.24)) {
                records.removeAll { $0.id == record.id }
                if selectedID == record.id {
                    selectedID = neighbor
                    selectionOrigin = .deletion
                }
                if previewID == record.id { previewID = nil }
                ensureSelection()
                message = "已删除"
            }
        }
    }
    func clearHistory() {
        perform { try database.clearHistory(); thumbnailCache.removeAllObjects(); try reload() }
    }
    func addCollection(name: String, icon: String = ClipCollection.defaultIcon, select: Bool = true) {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !name.isEmpty else { return }
        perform {
            let id = try database.addCollection(name: name, icon: icon)
            if select { filter = id }
            try reload()
        }
    }
    func deleteCollection(id: String) {
        perform { try database.deleteCollection(id: id); filter = "all"; try reload() }
    }
    @discardableResult func preparePaste(_ record: ClipRecord, plainText: Bool = false,
                                        to board: NSPasteboard = .general, now: Date = Date()) -> Bool {
        guard copy(record, plainText: plainText, to: board) else { return false }
        // A successful clipboard restore also supports the manual-paste fallback.
        // Touch the existing row so original formats, source and saved state stay intact.
        perform {
            try database.markUsed(id: record.id, now: now)
            try reload()
            selectedID = record.id
        }
        return true
    }
    @discardableResult func copy(_ record: ClipRecord, plainText: Bool = false, to board: NSPasteboard = .general) -> Bool {
        do {
            let items: [NSPasteboardItem]
            if plainText {
                guard !record.text.isEmpty else { return false }
                let item = NSPasteboardItem(); item.setString(record.text, forType: .string); items = [item]
            } else {
                items = try database.payload(for: record.id).items.map { representations in
                    let item = NSPasteboardItem()
                    for value in representations { item.setData(value.data, forType: NSPasteboard.PasteboardType(value.type)) }
                    return item
                }
            }
            if board.name == .general, onBeforeClipboardRestore?() == false {
                errorMessage = "后台记录服务暂时无法响应，请重试。"; return false
            }
            defer {
                if board.name == .general { onClipboardRestore?(board.changeCount) }
            }
            board.clearContents()
            let success = board.writeObjects(items)
            if board.name == NSPasteboard.Name.general { lastChange = board.changeCount }
            if !success { errorMessage = "无法写入系统剪贴板。请重试。" }
            return success
        } catch { errorMessage = error.localizedDescription; return false }
    }
    func releaseTransientResources() {
        thumbnailCache.removeAllObjects()
    }

    func thumbnail(for record: ClipRecord) -> NSImage? {
        guard record.kind == .image else { return nil }
        if let image = thumbnailCache.object(forKey: record.id as NSString) { return image }
        return autoreleasepool {
            do {
                guard let data = try database.thumbnail(for: record.id),
                      let image = ClipImageDecoder.image(from: data, maximumPixelSize: ClipImageDecoder.thumbnailPixelSize) else { return nil }
                let cost = image.representations.reduce(0) { total, representation in
                    let rowBytes = (representation as? NSBitmapImageRep)?.bytesPerRow ?? representation.pixelsWide * 4
                    return total + rowBytes * representation.pixelsHigh
                }
                thumbnailCache.setObject(image, forKey: record.id as NSString, cost: cost)
                return image
            } catch { errorMessage = error.localizedDescription; return nil }
        }
    }

    func previewImage(for record: ClipRecord) -> NSImage? {
        guard record.kind == .image else { return nil }
        return autoreleasepool {
            do {
                let payload = try database.payload(for: record.id)
                for item in payload.items {
                    for value in item where ["public.png", "public.jpeg", "public.tiff"].contains(value.type) {
                        if let image = ClipImageDecoder.image(from: value.data, maximumPixelSize: ClipImageDecoder.previewPixelSize) {
                            return image
                        }
                    }
                }
            } catch { errorMessage = error.localizedDescription }
            return thumbnail(for: record)
        }
    }
}
