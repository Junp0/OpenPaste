import AppKit
import SwiftUI

@MainActor final class SearchInputController {
    weak var field: NSTextField?

    @discardableResult func focus(caretAtEnd: Bool = false) -> Bool {
        guard let field, let window = field.window else { return false }
        let editor: NSTextView
        if let current = field.currentEditor() as? NSTextView, window.firstResponder === current { editor = current }
        else {
            guard window.makeFirstResponder(field), let current = field.currentEditor() as? NSTextView else { return false }
            editor = current
        }
        if !editor.hasMarkedText() {
            if caretAtEnd { editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0)) }
            else { editor.selectAll(nil) }
        }
        return true
    }

    func blur() {
        guard let field, field.currentEditor() != nil else { return }
        field.window?.makeFirstResponder(nil)
    }
}

struct SearchInput: NSViewRepresentable {
    @Binding var text: String
    let controller: SearchInputController

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }
    func makeNSView(context: Context) -> SearchFieldView {
        let view = SearchFieldView()
        let field = view.field
        field.isEditable = true; field.isSelectable = true
        field.isBezeled = false; field.isBordered = false; field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14)
        field.textColor = .labelColor
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel("搜索剪贴板历史")
        field.delegate = context.coordinator
        context.coordinator.placeholder = view.placeholder
        controller.field = field
        return view
    }
    func updateNSView(_ view: SearchFieldView, context: Context) {
        let field = view.field
        context.coordinator.text = $text
        controller.field = field
        // Never replace an in-progress IME composition during a SwiftUI update.
        if (field.currentEditor() as? NSTextView)?.hasMarkedText() != true, field.stringValue != text {
            field.stringValue = text
        }
        context.coordinator.updatePlaceholder(field)
    }

    final class SearchFieldView: NSView {
        let field = NSTextField()
        // Keep the placeholder outside AppKit's shared field editor so moving
        // focus to the group name cannot replace its color with the text color.
        let placeholder = NSTextField(labelWithString: "搜索内容、应用或类型")

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            placeholder.font = .systemFont(ofSize: 14)
            placeholder.textColor = .placeholderTextColor
            placeholder.lineBreakMode = .byClipping
            placeholder.setAccessibilityElement(false)
            field.setAccessibilityHelp("搜索内容、应用或类型，例如 img、文本、链接、文件；可与内容或应用名组合")
            for view in [field, placeholder] {
                view.translatesAutoresizingMaskIntoConstraints = false
                addSubview(view)
                NSLayoutConstraint.activate([
                    view.leadingAnchor.constraint(equalTo: leadingAnchor),
                    view.trailingAnchor.constraint(equalTo: trailingAnchor),
                    view.centerYAnchor.constraint(equalTo: centerYAnchor),
                    view.heightAnchor.constraint(equalToConstant: 20)
                ])
            }
        }
        convenience init() { self.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? {
            let target = super.hitTest(point)
            return target === placeholder ? field : target
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        weak var placeholder: NSTextField?
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ notification: Notification) { synchronize(notification) }
        func controlTextDidEndEditing(_ notification: Notification) { synchronize(notification) }
        func updatePlaceholder(_ field: NSTextField) {
            placeholder?.isHidden = !(field.currentEditor()?.string ?? field.stringValue).isEmpty
        }
        private func synchronize(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            updatePlaceholder(field)
            guard (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
            if text.wrappedValue != field.stringValue { text.wrappedValue = field.stringValue }
        }
    }
}

enum SearchKeyRouting {
    /// Called only after shelf shortcuts have had a chance to handle the event.
    static func shouldFocusSearch(_ event: NSEvent, isEditing: Bool) -> Bool {
        guard event.type == .keyDown, !isEditing else { return false }
        if event.modifierFlags.contains(.command) {
            // Native editing shortcuts (select all, paste, cut, undo/redo, copy).
            return !event.modifierFlags.contains(.control) && [0, 9, 7, 6, 8].contains(event.keyCode)
        }
        guard !event.modifierFlags.contains(.control) else { return false }
        if event.keyCode == 51 || event.keyCode == 117 { return false }
        if let text = event.characters, text.unicodeScalars.contains(where: {
            !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value)
        }) { return true }
        // Dead keys and some IMEs initially have no characters. Focus first and
        // let the original event reach the native editor, rather than synthesizing text.
        let printable: Set<UInt16> = Set(0...35).union(37...47).union([49, 50, 65, 67, 69, 75, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92, 93, 94, 95])
        return printable.contains(event.keyCode)
    }
}
