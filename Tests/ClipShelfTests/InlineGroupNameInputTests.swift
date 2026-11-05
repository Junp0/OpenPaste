import AppKit
import Testing
@testable import ClipShelf

@Suite @MainActor struct InlineGroupNameInputTests {
    @Test func returnSubmitsOnlyOnceEvenWhenFocusLossFollows() {
        _ = NSApplication.shared
        var results: [InlineGroupEditResult] = []
        let coordinator = InlineGroupNameInput.Coordinator { results.append($0) }
        let field = NSTextField(); field.stringValue = "工作"
        coordinator.field = field
        #expect(coordinator.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        coordinator.finish(.cancelled)
        #expect(results == [.submitted("工作")])
    }
    @Test func escapeCancelsInsteadOfSavingTheTypedName() {
        _ = NSApplication.shared
        var results: [InlineGroupEditResult] = []
        let coordinator = InlineGroupNameInput.Coordinator { results.append($0) }
        let field = NSTextField(); field.stringValue = "不应创建"
        coordinator.field = field
        #expect(coordinator.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        #expect(results == [.cancelled])
    }
    @Test func returnDuringCompositionIsLeftToTheInputMethod() {
        _ = NSApplication.shared
        var results: [InlineGroupEditResult] = []
        let coordinator = InlineGroupNameInput.Coordinator { results.append($0) }
        let field = NSTextField(); coordinator.field = field
        let editor = NSTextView()
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        #expect(!coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(results.isEmpty)
        editor.unmarkText()
    }
    @Test func choosingIconKeepsNameEditingUntilReturnSubmits() {
        _ = NSApplication.shared
        var results: [InlineGroupEditResult] = []
        var icon = "pin.fill"
        let coordinator = InlineGroupNameInput.Coordinator { results.append($0) }
        let field = NSTextField(); field.stringValue = "原名称"
        coordinator.field = field
        coordinator.onIconChange = { icon = $0 }
        let picker = NSPopUpButton()
        picker.addItem(withTitle: "工作")
        picker.lastItem?.representedObject = "briefcase.fill"
        let menu = NSMenu()
        coordinator.menuWillOpen(menu)
        coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        coordinator.chooseIcon(picker)
        #expect(results.isEmpty)
        #expect(icon == "briefcase.fill")
        #expect(field.stringValue == "工作")
        #expect(coordinator.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(results == [.submitted("工作")])
    }
    @Test func everyIconFillsItsCorrespondingNameWithoutSubmitting() {
        _ = NSApplication.shared
        var results: [InlineGroupEditResult] = []
        let coordinator = InlineGroupNameInput.Coordinator { results.append($0) }
        let field = NSTextField()
        coordinator.field = field
        let picker = NSPopUpButton()
        for choice in CollectionIcons.choices {
            picker.addItem(withTitle: choice.title)
            picker.lastItem?.representedObject = choice.symbol
        }
        for (index, choice) in CollectionIcons.choices.enumerated() {
            picker.selectItem(at: index)
            coordinator.chooseIcon(picker)
            #expect(field.stringValue == choice.title)
            #expect(results.isEmpty)
        }
    }
    @Test func generatedNameCanBeReplacedOrClearedInTheNativeEditor() throws {
        _ = NSApplication.shared
        for replacement in ["我的项目", ""] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            var results: [InlineGroupEditResult] = []
            let coordinator = InlineGroupNameInput.Coordinator { results.append($0) }
            let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 260, height: 24))
            field.stringValue = "原名称"
            field.delegate = coordinator
            coordinator.field = field
            window.contentView?.addSubview(field)
            #expect(window.makeFirstResponder(field))
            let picker = NSPopUpButton()
            picker.addItem(withTitle: "工作")
            picker.lastItem?.representedObject = "briefcase.fill"
            coordinator.menuWillOpen(try #require(picker.menu))
            coordinator.chooseIcon(picker)
            let editor = try #require(field.currentEditor() as? NSTextView)
            #expect(editor.string == "工作")
            #expect(editor.selectedRange() == NSRange(location: 0, length: 2))
            editor.insertText(replacement, replacementRange: editor.selectedRange())
            #expect(editor.string == replacement)
            #expect(results.isEmpty)
            #expect(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
            #expect(results == [.submitted(replacement)])
        }
    }
    @Test func compositeEditorDoesNotSubmitWhenTheNativeFieldEditorEnds() {
        _ = NSApplication.shared
        var results: [InlineGroupEditResult] = []
        let coordinator = InlineGroupNameInput.Coordinator { results.append($0) }
        let container = NSView()
        let field = NSTextField(); field.stringValue = "工作"
        coordinator.interactionView = container
        coordinator.field = field
        coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        #expect(results.isEmpty)
        #expect(coordinator.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(results == [.cancelled])
    }
}
