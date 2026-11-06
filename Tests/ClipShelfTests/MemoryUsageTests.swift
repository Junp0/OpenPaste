import AppKit
import ClipboardCore
import Testing
@testable import ClipShelf

@Suite @MainActor struct MemoryUsageTests {
    private func imageData(width: Int, height: Int) throws -> Data {
        try autoreleasepool {
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width,
                pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            // Initialize pixels so the encoded image is deterministic.
            memset(try #require(bitmap.bitmapData), 128, bitmap.bytesPerRow * height)
            return try #require(bitmap.representation(using: .png, properties: [:]))
        }
    }

    @Test func largePreviewIsBoundedWhileOriginalImageStillPastesLosslessly() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ClipboardStore(dataDirectory: directory, monitorsClipboard: false)
        let original = try imageData(width: 4096, height: 3072)
        let thumbnail = try imageData(width: 560, height: 420)
        let payload = ClipPayload(items: [[ClipRepresentation(type: "public.png", data: original)]])
        let id = try store.database.save(ClipDraft(kind: .image, title: "4096 × 3072", text: "",
            sourceName: "Test", sourceBundle: "test.app", thumbnail: thumbnail, payload: payload))
        try store.reload()
        let record = try #require(store.records.first)
        #expect(record.thumbnail == nil)
        let preview = try #require(store.previewImage(for: record))
        let representation = try #require(preview.representations.first)
        #expect(representation.pixelsWide == ClipImageDecoder.previewPixelSize)
        #expect(representation.pixelsHigh == 1050)
        #expect(try store.database.payload(for: id) == payload)

        let board = NSPasteboard(name: .init("io.clipshelf.memory-tests.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        #expect(store.copy(record, to: board))
        #expect(board.data(forType: .png) == original)
    }

    @Test func thumbnailsAreReusedThenReleasedAndCanBeLoadedAgain() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ClipboardStore(dataDirectory: directory, monitorsClipboard: false)
        let data = try imageData(width: 64, height: 48)
        try store.database.save(ClipDraft(kind: .image, title: "64 × 48", text: "",
            sourceName: "Test", sourceBundle: "test.app", thumbnail: data,
            payload: ClipPayload(items: [[ClipRepresentation(type: "public.png", data: data)]])))
        try store.reload()
        let record = try #require(store.records.first)
        weak var releasedImage: NSImage?
        try autoreleasepool {
            let image = try #require(store.thumbnail(for: record))
            #expect(store.thumbnail(for: record) === image)
            // Small images must not be upscaled to the thumbnail limit.
            #expect(image.representations.first?.pixelsWide == 64)
            releasedImage = image
        }
        store.releaseTransientResources()
        #expect(releasedImage == nil)
        #expect(store.thumbnail(for: record) != nil)
        store.delete(record)
        #expect(store.records.isEmpty)
    }

    @Test func corruptImageDataCannotProduceAPreviewBitmap() {
        #expect(ClipImageDecoder.image(from: Data("invalid".utf8), maximumPixelSize: 560) == nil)
    }
}
