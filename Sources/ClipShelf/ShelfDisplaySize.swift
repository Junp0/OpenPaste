import AppKit

enum ShelfDisplaySize: String, CaseIterable, Identifiable {
    // Keep existing preference values so renaming does not resize saved choices.
    case small = "standard", standard = "large", large = "extraLarge"
    var id: String { rawValue }
    var title: String {
        switch self { case .small: return "较小"; case .standard: return "标准"; case .large: return "较大" }
    }
    var cardWidth: CGFloat {
        switch self { case .small: return 222; case .standard: return 280; case .large: return 340 }
    }
    var cardHeight: CGFloat {
        switch self { case .small: return 246; case .standard: return 300; case .large: return 360 }
    }
    var panelHeight: CGFloat {
        switch self { case .small: return 400; case .standard: return 450; case .large: return 510 }
    }
    var bodyFontSize: CGFloat {
        switch self { case .small: return 12; case .standard: return 14; case .large: return 16 }
    }
    var footerHeight: CGFloat {
        switch self { case .small: return 32; case .standard: return 36; case .large: return 40 }
    }
    var sourceFontSize: CGFloat { bodyFontSize - 3 }
    static func load(from defaults: UserDefaults) -> Self {
        defaults.string(forKey: "displaySize").flatMap(Self.init(rawValue:)) ?? .standard
    }
}
