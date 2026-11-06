import AppKit
import ImageIO
import SwiftUI
import ClipboardCore

enum ClipImageDecoder {
    static let thumbnailPixelSize = 560
    // The preview is at most 700 points wide, including on Retina displays.
    static let previewPixelSize = 1400

    static func image(from data: Data, maximumPixelSize: Int) -> NSImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        // Retain only the downsampled bitmap, not an NSImage backed by the original.
        let bitmap = NSBitmapImageRep(cgImage: image)
        let result = NSImage(size: bitmap.size)
        result.addRepresentation(bitmap)
        return result
    }
}

struct ClipThumbnailView: View {
    let record: ClipRecord
    let store: ClipboardStore
    @ViewState<NSImage?> private var image: NSImage?

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: record.kind.symbol).foregroundStyle(record.kind.color) }
        }
        .onAppear { image = store.thumbnail(for: record) }
        // Lazy stacks keep view state after scrolling away. Drop that bitmap too.
        .onDisappear { image = nil }
    }
}
