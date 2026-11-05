import AppKit
import Carbon

struct ShelfShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let preferenceKey = "shortcutConfiguration"
    static let standard = ShelfShortcut(keyCode: UInt32(kVK_UpArrow), modifiers: UInt32(cmdKey))
    static let allowedModifiers = UInt32(cmdKey | optionKey | controlKey | shiftKey)
    static let modifierKeyCodes: Set<UInt32> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    var isValid: Bool {
        keyCode < 128 && !Self.modifierKeyCodes.contains(keyCode) &&
        modifiers & ~Self.allowedModifiers == 0 &&
        modifiers & UInt32(cmdKey | optionKey | controlKey) != 0
    }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode; self.modifiers = modifiers
    }

    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        modifiers = Self.carbonModifiers(for: event.modifierFlags)
    }

    static func carbonModifiers(for flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }

    static func modifierLabel(_ modifiers: UInt32) -> String {
        [(UInt32(controlKey), "⌃"), (UInt32(optionKey), "⌥"), (UInt32(shiftKey), "⇧"), (UInt32(cmdKey), "⌘")]
            .filter { modifiers & $0.0 != 0 }.map(\.1).joined()
    }
    var displayLabel: String { Self.modifierLabel(modifiers) + keyLabel }
    var keyLabel: String {
        let special: [UInt32: String] = [
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "Esc", 71: "Clear", 76: "⌤",
            114: "Help", 115: "↖", 116: "⇞", 117: "⌦", 119: "↘", 121: "⇟",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
            106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"
        ]
        if let label = special[keyCode] { return label }
        // Read the current ASCII-capable layout so non-US keyboards show their key labels.
        if let input = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
           let pointer = TISGetInputSourceProperty(input, kTISPropertyUnicodeKeyLayoutData) {
            let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
            if let bytes = CFDataGetBytePtr(data) {
                let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
                var deadKey: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 8)
                let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKey,
                    characters.count, &length, &characters)
                if status == noErr, length > 0 {
                    let label = String(utf16CodeUnits: characters, count: length).uppercased()
                    if label.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) { return label }
                }
            }
        }
        return "Key \(keyCode)"
    }

    static func load(from defaults: UserDefaults) -> ShelfShortcut {
        if let data = defaults.data(forKey: preferenceKey),
           let shortcut = try? JSONDecoder().decode(Self.self, from: data), shortcut.isValid { return shortcut }
        if defaults.string(forKey: "shortcut") == "commandOptionV" {
            return ShelfShortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | optionKey))
        }
        if defaults.string(forKey: "shortcut") == "commandShiftV" {
            return ShelfShortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey))
        }
        return .standard
    }
    func save(in defaults: UserDefaults) {
        guard isValid, let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.preferenceKey)
    }
}
