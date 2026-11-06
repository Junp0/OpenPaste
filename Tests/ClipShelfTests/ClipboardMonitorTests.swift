import AppKit
import ClipboardCore
import Testing
@testable import ClipShelf

@Suite @MainActor struct ClipboardMonitorTests {
    private func withMonitor(_ body: (ClipboardMonitor, NSPasteboard) throws -> Void) throws {
        let id = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        let suite = "io.clipshelf.monitor-tests.\(id)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let board = NSPasteboard(name: .init(suite))
        defer {
            board.releaseGlobally()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let monitor = try ClipboardMonitor(dataDirectory: directory, monitorsClipboard: false, defaults: defaults)
        defer { monitor.stop() }
        try body(monitor, board)
    }

    @Test func backgroundCapturePersistsOriginalDataAndDoesNotRepeatAnUnchangedBoard() throws {
        try withMonitor { monitor, board in
            var captures = 0
            monitor.onCapture = { bytes in
                captures += 1; #expect(bytes == Data("后台记录".utf8).count)
            }
            board.clearContents(); board.setString("后台记录", forType: .string)
            for _ in 0..<3 { monitor.capturePendingChange(from: board, source: nil) }
            let record = try #require(monitor.database.records().first)
            #expect(captures == 1)
            #expect(record.text == "后台记录")
            #expect(try monitor.database.payload(for: record.id).items.first?.first?.data == Data("后台记录".utf8))
        }
    }

    @Test func restoringAnOldClipIsSkippedAndTheNextExternalCopyStillCaptures() throws {
        try withMonitor { monitor, board in
            board.clearContents(); board.setString("first", forType: .string)
            monitor.capturePendingChange(from: board, source: nil)
            monitor.beginRestore()
            board.clearContents(); board.setString("restored", forType: .string)
            monitor.capturePendingChange(from: board, source: nil)
            monitor.endRestore(changeCount: board.changeCount)
            monitor.capturePendingChange(from: board, source: nil)
            board.clearContents(); board.setString("next", forType: .string)
            monitor.capturePendingChange(from: board, source: nil)
            let records = try monitor.database.records()
            #expect(Set(records.map(\.text)) == ["first", "next"])
        }
    }

    @Test func pausingDoesNotReplayPrivateCopiesWhenRecordingResumes() throws {
        try withMonitor { monitor, board in
            monitor.setPaused(true)
            board.clearContents(); board.setString("paused content", forType: .string)
            monitor.capturePendingChange(from: board, source: nil)
            monitor.setPaused(false)
            monitor.capturePendingChange(from: board, source: nil)
            let pausedRecords = try monitor.database.records()
            #expect(pausedRecords.isEmpty)
            board.clearContents(); board.setString("after resume", forType: .string)
            monitor.capturePendingChange(from: board, source: nil)
            let records = try monitor.database.records()
            #expect(records.map(\.text) == ["after resume"])
        }
    }

    @Test func residentCaptureStillRejectsConcealedClipboardFormats() throws {
        try withMonitor { monitor, board in
            let item = NSPasteboardItem()
            item.setString("secret", forType: .string)
            item.setString("", forType: .init("org.nspasteboard.ConcealedType"))
            board.clearContents(); board.writeObjects([item])
            monitor.capturePendingChange(from: board, source: nil)
            let records = try monitor.database.records()
            #expect(records.isEmpty)
        }
    }

    @Test func theApplicationsOwnEditorIsIgnoredEvenWithoutABundleIdentifier() throws {
        try withMonitor { monitor, board in
            board.clearContents(); board.setString("search field contents", forType: .string)
            monitor.capturePendingChange(from: board, source: .current)
            let records = try monitor.database.records()
            #expect(records.isEmpty)
        }
    }
}
