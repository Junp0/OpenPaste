import AppKit
import Carbon
import Testing
@testable import ClipShelf

@Suite @MainActor struct ShortcutAndPresentationTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "io.clipshelf.shortcut-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test func customShortcutPersistsAcrossPreferencesReloads() throws {
        try withDefaults { defaults in
            let shortcut = ShelfShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey))
            shortcut.save(in: defaults)
            #expect(ShelfShortcut.load(from: defaults) == shortcut)
            let data = try #require(defaults.data(forKey: ShelfShortcut.preferenceKey))
            #expect(try JSONDecoder().decode(ShelfShortcut.self, from: data) == shortcut)
        }
    }
    @Test func oldPresetMigratesAndCustomConfigurationTakesPriority() {
        withDefaults { defaults in
            #expect(ShelfShortcut.load(from: defaults) == .standard)
            defaults.set("commandOptionV", forKey: "shortcut")
            #expect(ShelfShortcut.load(from: defaults) == ShelfShortcut(keyCode: 9, modifiers: UInt32(cmdKey | optionKey)))
            defaults.set("commandShiftV", forKey: "shortcut")
            #expect(ShelfShortcut.load(from: defaults) == ShelfShortcut(keyCode: 9, modifiers: UInt32(cmdKey | shiftKey)))
            let custom = ShelfShortcut(keyCode: 7, modifiers: UInt32(controlKey | shiftKey))
            custom.save(in: defaults)
            #expect(ShelfShortcut.load(from: defaults) == custom)
        }
    }
    @Test func invalidOrCorruptConfigurationDoesNotDisableTheDefaultShortcut() throws {
        try withDefaults { defaults in
            defaults.set(Data("not json".utf8), forKey: ShelfShortcut.preferenceKey)
            #expect(ShelfShortcut.load(from: defaults) == .standard)
            let invalid = ShelfShortcut(keyCode: 9, modifiers: UInt32(shiftKey))
            defaults.set(try JSONEncoder().encode(invalid), forKey: ShelfShortcut.preferenceKey)
            #expect(ShelfShortcut.load(from: defaults) == .standard)
        }
        #expect(!ShelfShortcut(keyCode: 9, modifiers: 0).isValid)
        #expect(!ShelfShortcut(keyCode: 9, modifiers: UInt32(shiftKey)).isValid)
        #expect(!ShelfShortcut(keyCode: 55, modifiers: UInt32(cmdKey)).isValid)
        #expect(!ShelfShortcut(keyCode: 999, modifiers: UInt32(cmdKey)).isValid)
        #expect(!ShelfShortcut(keyCode: 9, modifiers: UInt32(cmdKey) | (1 << 31)).isValid)
    }
    @Test func captureIgnoresCapsLockAndKeyboardMetadataFlags() throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.control, .option, .capsLock, .numericPad, .function], timestamp: 0,
            windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        let shortcut = ShelfShortcut(event: event)
        #expect(shortcut.modifiers == UInt32(controlKey | optionKey))
        #expect(shortcut.displayLabel == "⌃⌥Space")
        #expect(shortcut.isValid)
        #expect(ShelfShortcut.modifierLabel(UInt32(cmdKey | shiftKey | optionKey | controlKey)) == "⌃⌥⇧⌘")
    }
    @Test func shelfUsesPhysicalBottomEdgeIncludingDockArea() {
        let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = NSRect(x: 0, y: 86, width: 1512, height: 870)
        let frame = ShelfPresentation.frame(screen: screen, visible: visible, size: .small)
        #expect(frame == NSRect(x: 0, y: 0, width: 1512, height: 400))
    }
    @Test func shelfStaysOnSelectedMonitorWithNegativeCoordinatesAndSideDock() {
        let screen = NSRect(x: -1920, y: -1080, width: 1920, height: 1080)
        let visible = NSRect(x: -1840, y: -1080, width: 1840, height: 1055)
        let frame = ShelfPresentation.frame(screen: screen, visible: visible)
        #expect(frame.minX == screen.minX)
        #expect(frame.minY == screen.minY)
        #expect(frame.width == screen.width)
        #expect(frame.maxY <= visible.maxY)
    }
    @Test func shelfFitsShortDisplays() {
        let frame = ShelfPresentation.frame(screen: NSRect(x: 0, y: 0, width: 1024, height: 360),
            visible: NSRect(x: 0, y: 60, width: 1024, height: 280))
        #expect(frame.height == 260)
    }
    @Test func deleteKeysRemoveSelectionButPreserveTextEditingAndModifiedCommands() throws {
        func event(_ keyCode: UInt16 = 51, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: 0, context: nil, characters: "\u{7f}",
                charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: keyCode))
        }
        #expect(ShelfPanelKeyAction.deletesSelectedRecord(try event(), isEditing: false))
        #expect(ShelfPanelKeyAction.deletesSelectedRecord(try event(flags: .command), isEditing: false))
        #expect(!ShelfPanelKeyAction.deletesSelectedRecord(try event(flags: .option), isEditing: false))
        #expect(!ShelfPanelKeyAction.deletesSelectedRecord(try event(flags: .control), isEditing: false))
        #expect(ShelfPanelKeyAction.deletesSelectedRecord(try event(117), isEditing: false))
        #expect(!ShelfPanelKeyAction.deletesSelectedRecord(try event(0), isEditing: false))
        for keyCode: UInt16 in [51, 117] {
            for flags: NSEvent.ModifierFlags in [[], .command, .option, .control, .shift] {
                #expect(!ShelfPanelKeyAction.deletesSelectedRecord(try event(keyCode, flags: flags), isEditing: true))
            }
        }
    }
}
