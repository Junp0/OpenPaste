import AppKit

enum ShelfPanelKeyAction: Equatable {
    case dismiss, previousGroup, nextGroup, confirmSearch

    static func cardSelectionOffset(_ event: NSEvent) -> Int? {
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return nil }
        // Plain arrows browse results even while a nonempty search is focused.
        // Modified arrows remain available for text editing and shelf shortcuts.
        switch event.keyCode {
        case 123, 126: return -1
        case 124, 125: return 1
        default: return nil
        }
    }

    static func deletesSelectedRecord(_ event: NSEvent, isEditing: Bool) -> Bool {
        // An empty field still owns deletion keys while the user is editing it.
        guard event.type == .keyDown, [51, 117].contains(event.keyCode), !isEditing else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        return modifiers.isEmpty || modifiers == .command
    }

    static func matching(_ event: NSEvent, shortcut: ShelfShortcut, isEditingSearch: Bool = false) -> Self? {
        guard event.type == .keyDown else { return nil }
        // Pressing the configured global shortcut again closes the open panel.
        if ShelfShortcut(event: event) == shortcut { return .dismiss }
        if isEditingSearch, [36, 76].contains(event.keyCode) { return .confirmSearch }
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command else { return nil }
        switch event.keyCode {
        case 123: return .previousGroup
        case 124: return .nextGroup
        case 125: return .dismiss
        default: return nil
        }
    }
}
