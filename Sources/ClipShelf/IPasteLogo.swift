import AppKit

enum IPasteLogo {
    static let mark: NSImage = {
        let image = Bundle.main.url(forResource: "OpenPasteStatus", withExtension: "pdf")
            .flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "OpenPaste剪贴板")!
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        image.accessibilityDescription = "OpenPaste剪贴板"
        return image
    }()
}
