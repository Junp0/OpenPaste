import AppKit
import ClipboardCore
import Testing
@testable import ClipShelf

@Suite @MainActor struct CaptureWorkerTests {
    private func withRequest(_ body: (NSPasteboard, CaptureWorkerRequest, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let board = NSPasteboard(name: .init("io.clipshelf.worker-tests.\(UUID().uuidString)"))
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: directory) }
        board.clearContents(); board.setString("worker text", forType: .string)
        let url = directory.appendingPathComponent("history.sqlite")
        let request = CaptureWorkerRequest(pasteboardName: board.name.rawValue, changeCount: board.changeCount,
            databasePath: url.path, sourceName: "Original App", sourceBundle: "original.app")
        try body(board, request, url)
    }

    @Test func workerPersistsAllFormatsAndTheObservedSource() throws {
        try withRequest { _, request, url in
            let result = CaptureWorker.capture(request)
            #expect(result.status == .captured)
            #expect(result.bytes == Data("worker text".utf8).count)
            let database = try ClipboardDatabase(url: url)
            let record = try #require(database.records().first)
            #expect(record.sourceName == "Original App")
            #expect(record.sourceBundle == "original.app")
            #expect(record.text == "worker text")
            #expect(try database.payload(for: record.id).items.first?.first?.data == Data("worker text".utf8))
        }
    }

    @Test func aChangedClipboardCannotBeSavedWithTheOldSource() throws {
        try withRequest { board, request, url in
            board.clearContents(); board.setString("new copy", forType: .string)
            #expect(CaptureWorker.capture(request).status == .changed)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func concealedContentIsRejectedBeforeOpeningTheDatabase() throws {
        try withRequest { board, _, url in
            board.clearContents()
            let item = NSPasteboardItem()
            item.setString("secret", forType: .string)
            item.setString("", forType: .init("org.nspasteboard.ConcealedType"))
            board.writeObjects([item])
            let request = CaptureWorkerRequest(pasteboardName: board.name.rawValue, changeCount: board.changeCount,
                databasePath: url.path, sourceName: "Original App", sourceBundle: "original.app")
            #expect(CaptureWorker.capture(request).status == .ignored)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }
}
