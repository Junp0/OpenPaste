import AppKit
import ClipboardCore
import Testing
@testable import ClipShelf

@Suite @MainActor struct PasteRecencyTests {
    private func withStore(_ body: (ClipboardStore, ClipRecord, NSPasteboard) throws -> Void) throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let board = NSPasteboard(name: NSPasteboard.Name("io.clipshelf.paste-recency-tests.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let store = try ClipboardStore(dataDirectory: directory, monitorsClipboard: false)
        let oldText = "旧内容"
        let id = try store.database.save(ClipDraft(kind: .text, title: oldText, text: oldText,
            sourceName: "Original App", sourceBundle: "original.app",
            payload: ClipPayload(items: [[
                ClipRepresentation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(oldText.utf8)),
                ClipRepresentation(type: NSPasteboard.PasteboardType.rtf.rawValue, data: Data("{\\rtf1 old}".utf8))
            ]])), now: Date().addingTimeInterval(-3600))
        let group = try store.database.addCollection(name: "工作")
        try store.database.assign(group, to: id)
        try store.database.setFavorite(true, id: id)
        try store.database.save(ClipDraft(kind: .text, title: "新内容", text: "新内容",
            sourceName: "Other App", sourceBundle: "other.app",
            payload: ClipPayload(items: [[ClipRepresentation(type: "public.utf8-plain-text", data: Data("新内容".utf8))]])))
        try store.reload()
        let old = try #require(store.records.first { $0.id == id })
        try body(store, old, board)
    }

    @Test func preparingPasteRefreshesTimeAndMovesTheExistingCardToTheFront() throws {
        try withStore { store, old, board in
            let now = Date()
            #expect(store.preparePaste(old, to: board, now: now))
            let refreshed = try #require(store.records.first)
            #expect(refreshed.id == old.id)
            // SQLite 使用 Unix 时间 Double，跨 Date 参考纪元换算可能损失一个浮点精度单位。
            #expect(abs(refreshed.updatedAt.timeIntervalSince(now)) < 0.000001)
            #expect(refreshed.createdAt == old.createdAt)
            #expect(refreshed.sourceBundle == old.sourceBundle)
            #expect(refreshed.favorite == old.favorite)
            #expect(refreshed.collectionID == old.collectionID)
            #expect(store.records.count == 2)
            #expect(store.selectedID == old.id)
            #expect(board.string(forType: .string) == old.text)
            #expect(board.data(forType: .rtf) == Data("{\\rtf1 old}".utf8))
            try store.reload()
            let persisted = try #require(store.records.first)
            #expect(abs(persisted.updatedAt.timeIntervalSince(now)) < 0.000001)
        }
    }

    @Test func plainTextPastePromotesWithinTheCurrentGroupWithoutChangingStoredFormats() throws {
        try withStore { store, old, board in
            let originalPayload = try store.database.payload(for: old.id)
            store.filter = try #require(old.collectionID)
            store.query = "旧"
            let now = Date()
            #expect(store.preparePaste(old, plainText: true, to: board, now: now))
            #expect(board.string(forType: .string) == old.text)
            #expect(board.data(forType: .rtf) == nil)
            let refreshed = try #require(store.visibleRecords.first)
            #expect(abs(refreshed.updatedAt.timeIntervalSince(now)) < 0.000001)
            #expect(store.filter == old.collectionID)
            #expect(store.query == "旧")
            #expect(try store.database.payload(for: old.id) == originalPayload)
        }
    }

    @Test func unsupportedPlainTextPasteDoesNotRefreshOrClearTheClipboard() throws {
        try withStore { store, _, board in
            let id = try store.database.save(ClipDraft(kind: .file, title: "文件", text: "",
                sourceName: "Test", sourceBundle: "test.app",
                payload: ClipPayload(items: [[ClipRepresentation(type: "public.file-url", data: Data("file:///tmp/test".utf8))]])),
                now: Date().addingTimeInterval(-1800))
            try store.reload()
            let record = try #require(store.records.first { $0.id == id })
            board.setString("原剪贴板内容", forType: .string)
            let order = store.records.map(\.id)
            #expect(!store.preparePaste(record, plainText: true, to: board))
            #expect(store.records.map(\.id) == order)
            #expect(board.string(forType: .string) == "原剪贴板内容")
            let persisted = try store.database.records().first { $0.id == id }
            #expect(persisted?.updatedAt == record.updatedAt)
        }
    }

    @Test func copyingWithoutPastingKeepsExistingRecency() throws {
        try withStore { store, old, board in
            let order = store.records.map(\.id)
            #expect(store.copy(old, to: board))
            #expect(store.records.map(\.id) == order)
            #expect(store.records.last?.updatedAt == old.updatedAt)
            #expect(board.string(forType: .string) == old.text)
        }
    }
}
