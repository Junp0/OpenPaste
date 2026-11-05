import AppKit

enum IPasteLogo {
    static let mark: NSImage = {
        let image = Bundle.main.url(forResource: "iPasteStatus", withExtension: "pdf")
            .flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "iPaste剪贴板")!
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        image.accessibilityDescription = "iPaste剪贴板"
        return image
    }()
}
