import AppKit
import Testing
import SwiftUI
import ClipboardCore
@testable import ClipShelf

@Suite @MainActor struct SearchInputTests {
    private func event(_ keyCode: UInt16, _ text: String, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
            isARepeat: false, keyCode: keyCode))
    }
    @Test func textAndDeadKeysFocusSearchWithoutTurningCommandsIntoText() throws {
        #expect(SearchKeyRouting.shouldFocusSearch(try event(0, "a"), isEditing: false))
        #expect(SearchKeyRouting.shouldFocusSearch(try event(0, "A", flags: .shift), isEditing: false))
        #expect(SearchKeyRouting.shouldFocusSearch(try event(0, "你"), isEditing: false))
        #expect(SearchKeyRouting.shouldFocusSearch(try event(14, "", flags: .option), isEditing: false))
        #expect(!SearchKeyRouting.shouldFocusSearch(try event(51, "\u{7f}"), isEditing: false))
        #expect(!SearchKeyRouting.shouldFocusSearch(try event(117, "\u{f728}"), isEditing: false))
        #expect(SearchKeyRouting.shouldFocusSearch(try event(9, "v", flags: .command), isEditing: false))
        #expect(SearchKeyRouting.shouldFocusSearch(try event(0, "a", flags: .command), isEditing: false))
        #expect(!SearchKeyRouting.shouldFocusSearch(try event(40, "k", flags: .command), isEditing: false))
        #expect(!SearchKeyRouting.shouldFocusSearch(try event(40, "k", flags: .control), isEditing: false))
    }
    @Test func navigationAndAlreadyFocusedInputKeepTheirNativeDestinations() throws {
        for (code, text): (UInt16, String) in [(53, "\u{1b}"), (48, "\t"), (36, "\r"),
            (123, "\u{f702}"), (124, "\u{f703}"), (125, "\u{f701}"), (126, "\u{f700}"), (122, "\u{f704}")] {
            #expect(!SearchKeyRouting.shouldFocusSearch(try event(code, text), isEditing: false))
        }
        #expect(!SearchKeyRouting.shouldFocusSearch(try event(0, "a"), isEditing: true))
    }
    private func withField(_ action: (SearchInputController, NSTextField) throws -> Void) throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 80), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 360, height: 24))
        field.stringValue = "原有😀"
        window.contentView?.addSubview(field)
        let input = SearchInputController(); input.field = field
        try action(input, field)
    }
    @Test func leavingSearchForCardNavigationKeepsTheWindowFocusedAndTextIntact() throws {
        try withField { input, field in
            #expect(input.focus(caretAtEnd: true))
            let editor = try #require(field.currentEditor() as? NSTextView)
            editor.insertText("筛选", replacementRange: NSRange(location: NSNotFound, length: 0))
            input.blur()
            #expect(field.currentEditor() == nil)
            #expect(field.window?.firstResponder === field.window)
            #expect(field.stringValue == "原有😀筛选")
            for code: UInt16 in [123, 124, 125, 126] {
                #expect(!SearchKeyRouting.shouldFocusSearch(try event(code, ""), isEditing: false))
                #expect(field.window?.firstResponder === field.window)
            }
        }
    }
    @Test func horizontalArrowsNavigateFilteredResultsFromFocusedSearch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ClipboardStore(dataDirectory: directory, monitorsClipboard: false)
        for (index, text) in ["匹配一", "其他内容", "匹配二"].enumerated() {
            _ = try store.database.save(ClipDraft(kind: .text, title: text, text: text,
                sourceName: "Test", sourceBundle: "test.app",
                payload: ClipPayload(items: [[ClipRepresentation(type: "public.utf8-plain-text", data: Data(text.utf8))]])),
                now: Date().addingTimeInterval(Double(index)))
        }
        try store.reload()
        store.query = "匹配"
        let results = store.visibleRecords.map(\.id)
        try #require(results.count == 2)
        try withField { input, field in
            field.stringValue = store.query
            for (code, expected): (UInt16, String) in [(124, results[1]), (124, results[1]), (123, results[0]), (123, results[0])] {
                #expect(input.focus(caretAtEnd: true))
                #expect(field.currentEditor() != nil)
                let offset = try #require(ShelfPanelKeyAction.cardSelectionOffset(try event(code, "")))
                input.blur()
                store.moveSelection(offset)
                #expect(store.selectedID == expected)
                #expect(field.window?.firstResponder === field.window)
                #expect(field.stringValue == "匹配")
                #expect(store.query == "匹配")
            }
            store.query = "无结果"
            store.moveSelection(try #require(ShelfPanelKeyAction.cardSelectionOffset(try event(124, ""))))
            #expect(store.selectedID == nil)
        }
    }
    @Test func modifiedArrowsRemainAvailableForEditingAndGroupShortcuts() throws {
        for code: UInt16 in [123, 124, 125, 126] {
            #expect(ShelfPanelKeyAction.cardSelectionOffset(try event(code, "")) == ([123, 126].contains(code) ? -1 : 1))
            for flags: NSEvent.ModifierFlags in [.command, .option, .control, .shift, [.option, .shift]] {
                #expect(ShelfPanelKeyAction.cardSelectionOffset(try event(code, "", flags: flags)) == nil)
            }
        }
        #expect(ShelfPanelKeyAction.cardSelectionOffset(try event(0, "a")) == nil)
    }
    @Test func returnConfirmsSearchBeforeItCanPasteACard() throws {
        try withField { input, field in
            for query in ["筛选", ""] {
                for code: UInt16 in [36, 76] {
                    field.stringValue = query
                    #expect(input.focus(caretAtEnd: true))
                    let confirm = try event(code, "\r")
                    #expect(ShelfPanelKeyAction.matching(confirm, shortcut: .standard,
                        isEditingSearch: field.currentEditor() != nil) == .confirmSearch)
                    input.blur()
                    #expect(field.window?.firstResponder === field.window)
                    #expect(field.stringValue == query)
                    #expect(ShelfPanelKeyAction.matching(confirm, shortcut: .standard,
                        isEditingSearch: field.currentEditor() != nil) == nil)
                }
            }
        }
    }
    @Test func firstCharacterAppendsAfterReturningFromCardSelection() throws {
        try withField { input, field in
            #expect(input.focus(caretAtEnd: true))
            let editor = try #require(field.currentEditor() as? NSTextView)
            #expect(editor.selectedRange() == NSRange(location: 4, length: 0))
            editor.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(editor.string == "原有😀a")
            input.blur()
            #expect(field.stringValue == "原有😀a")
            #expect(input.focus(caretAtEnd: true))
            let secondEditor = try #require(field.currentEditor() as? NSTextView)
            secondEditor.insertText("b", replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(secondEditor.string == "原有😀ab")
        }
    }
    @Test func backspaceStaysInSearchAfterDeletingTheLastCharacter() throws {
        try withField { input, field in
            field.stringValue = "a"
            #expect(input.focus(caretAtEnd: true))
            let editor = try #require(field.currentEditor() as? NSTextView)
            let backspace = try event(51, "\u{7f}")
            for _ in 0..<3 {
                let isEditing = field.window?.firstResponder is NSTextView
                #expect(isEditing)
                #expect(!ShelfPanelKeyAction.deletesSelectedRecord(backspace, isEditing: isEditing))
                editor.deleteBackward(nil)
                #expect(editor.string.isEmpty)
            }
            input.blur()
            #expect(field.stringValue.isEmpty)
            #expect(ShelfPanelKeyAction.deletesSelectedRecord(backspace, isEditing: field.window?.firstResponder is NSTextView))
        }
    }
    @Test func refocusingDoesNotSelectOrCommitAnIMEComposition() throws {
        try withField { input, field in
            #expect(input.focus(caretAtEnd: true))
            let editor = try #require(field.currentEditor() as? NSTextView)
            editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(editor.hasMarkedText())
            let selection = editor.selectedRange()
            #expect(input.focus())
            #expect(editor.hasMarkedText())
            #expect(editor.selectedRange() == selection)
            editor.unmarkText()
        }
    }
    @Test func placeholderHidesDuringIMECompositionWithoutChangingTheSearch() throws {
        try withField { input, field in
            var query = ""
            field.stringValue = ""
            let placeholder = NSTextField(labelWithString: "搜索")
            let coordinator = SearchInput.Coordinator(text: Binding(get: { query }, set: { query = $0 }))
            coordinator.placeholder = placeholder
            #expect(input.focus())
            let editor = try #require(field.currentEditor() as? NSTextView)
            coordinator.updatePlaceholder(field)
            #expect(!placeholder.isHidden)
            editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            #expect(placeholder.isHidden)
            #expect(query.isEmpty)
            #expect(editor.hasMarkedText())
            editor.unmarkText()
            editor.string = ""; field.stringValue = ""
            coordinator.updatePlaceholder(field)
            #expect(!placeholder.isHidden)
        }
    }
}
