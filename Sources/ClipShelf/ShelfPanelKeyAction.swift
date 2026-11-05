import AppKit

enum ShelfPanelKeyAction: Equatable {
    case dismiss, previousGroup, nextGroup

    static func deletesSelectedRecord(_ event: NSEvent, isEditing: Bool) -> Bool {
        // An empty field still owns deletion keys while the user is editing it.
        guard event.type == .keyDown, [51, 117].contains(event.keyCode), !isEditing else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        return modifiers.isEmpty || modifiers == .command
    }

    static func matching(_ event: NSEvent, shortcut: ShelfShortcut) -> Self? {
        guard event.type == .keyDown else { return nil }
        // Pressing the configured global shortcut again closes the open panel.
        if ShelfShortcut(event: event) == shortcut { return .dismiss }
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command else { return nil }
        switch event.keyCode {
        case 123: return .previousGroup
        case 124: return .nextGroup
        case 125: return .dismiss
        default: return nil
        }
    }
}
