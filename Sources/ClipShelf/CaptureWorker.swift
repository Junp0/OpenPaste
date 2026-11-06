import AppKit
import ClipboardCore

struct CaptureWorkerRequest: Codable {
    let pasteboardName: String
    let changeCount: Int
    let databasePath: String
    let sourceName: String
    let sourceBundle: String
}

struct CaptureWorkerResult: Codable {
    enum Status: String, Codable { case captured, ignored, tooLarge, changed, failed }
    let status: Status
    var bytes: Int = 0
    var error: String?
}

/// Capturing can initialize system-owned flavor and text/image decoder caches.
/// A one-shot worker releases those caches without interrupting clipboard polling.
enum CaptureWorker {
    @MainActor static func capture(_ request: CaptureWorkerRequest) -> CaptureWorkerResult {
        let board = NSPasteboard(name: .init(request.pasteboardName))
        guard board.changeCount == request.changeCount else { return CaptureWorkerResult(status: .changed) }
        switch ClipboardCapture.readUncached(board.name, source: nil) {
        case .ignored: return CaptureWorkerResult(status: .ignored)
        case .tooLarge: return CaptureWorkerResult(status: .tooLarge)
        case .captured(var draft):
            guard board.changeCount == request.changeCount else { return CaptureWorkerResult(status: .changed) }
            draft.sourceName = request.sourceName; draft.sourceBundle = request.sourceBundle
            do {
                let database = try ClipboardDatabase(url: URL(fileURLWithPath: request.databasePath))
                try database.save(draft)
                let bytes = draft.payload.items.reduce(0) { $0 + $1.reduce(0) { $0 + $1.data.count } }
                return CaptureWorkerResult(status: .captured, bytes: bytes)
            } catch { return CaptureWorkerResult(status: .failed, error: error.localizedDescription) }
        }
    }

    @MainActor static func run() {
        let result: CaptureWorkerResult = autoreleasepool {
            do {
                let data = FileHandle.standardInput.readDataToEndOfFile()
                guard data.count <= 16 * 1024 else { return CaptureWorkerResult(status: .failed) }
                let request = try JSONDecoder().decode(CaptureWorkerRequest.self, from: data)
                return capture(request)
            } catch { return CaptureWorkerResult(status: .failed, error: error.localizedDescription) }
        }
        if let data = try? JSONEncoder().encode(result) { try? FileHandle.standardOutput.write(contentsOf: data) }
    }
}
