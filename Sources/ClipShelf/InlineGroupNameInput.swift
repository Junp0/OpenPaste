import AppKit
import SwiftUI

enum CollectionIcons {
    static let choices: [(symbol: String, title: String)] = [
        ("pin.fill", "图钉"), ("folder.fill", "文件夹"), ("briefcase.fill", "工作"),
        ("house.fill", "生活"), ("lightbulb.fill", "灵感"), ("book.fill", "阅读"),
        ("chevron.left.forwardslash.chevron.right", "代码"), ("link", "链接"),
        ("photo.fill", "图片"), ("heart.fill", "喜欢"), ("bolt.fill", "快捷"), ("tag.fill", "标签")
    ]
}

enum InlineGroupEditResult: Equatable {
    case submitted(String), lostFocus(String), cancelled
}

struct InlineGroupNameInput: NSViewRepresentable {
    @Binding var icon: String
    let onFinish: (InlineGroupEditResult) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let field = GroupNameTextField()
        field.isEditable = true; field.isSelectable = true
        field.isBezeled = false; field.isBordered = false; field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.textColor = .labelColor
        field.placeholderString = "分组名称"
        field.cell?.usesSingleLineMode = true; field.cell?.isScrollable = true
        field.setAccessibilityLabel("新分组名称")
        field.delegate = context.coordinator
        context.coordinator.field = field
        context.coordinator.interactionView = container
        context.coordinator.onIconChange = { icon = $0 }
        let picker = NSPopUpButton(frame: .zero, pullsDown: false)
        picker.isBordered = false
        picker.imagePosition = .imageOnly
        picker.refusesFirstResponder = true
        picker.toolTip = "选择分组图标"
        picker.setAccessibilityLabel("选择分组图标")
        picker.menu?.autoenablesItems = false
        picker.menu?.delegate = context.coordinator
        for choice in CollectionIcons.choices {
            picker.addItem(withTitle: choice.title)
            picker.lastItem?.representedObject = choice.symbol
            picker.lastItem?.image = NSImage(systemSymbolName: choice.symbol, accessibilityDescription: choice.title)
        }
        picker.selectItem(at: CollectionIcons.choices.firstIndex { $0.symbol == icon } ?? 0)
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.chooseIcon(_:))
        context.coordinator.picker = picker
        for view in [picker, field] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            picker.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            picker.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            picker.widthAnchor.constraint(equalToConstant: 40),
            picker.heightAnchor.constraint(equalToConstant: 24),
            field.leadingAnchor.constraint(equalTo: picker.trailingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            field.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            field.heightAnchor.constraint(equalToConstant: 20)
        ])
        field.didAttach = { [weak coordinator = context.coordinator] in coordinator?.start() }
        return container
    }
    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onFinish = onFinish
        context.coordinator.onIconChange = { icon = $0 }
        context.coordinator.picker?.selectItem(at: CollectionIcons.choices.firstIndex { $0.symbol == icon } ?? 0)
        // Keep the field editor's text and IME composition untouched during redraws.
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.finish(.cancelled)
    }

    final class GroupNameTextField: NSTextField {
        var didAttach: (() -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { didAttach?() }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate, NSMenuDelegate {
        weak var field: NSTextField?
        weak var interactionView: NSView?
        weak var picker: NSPopUpButton?
        var onFinish: (InlineGroupEditResult) -> Void
        var onIconChange: (String) -> Void = { _ in }
        private var finished = false
        private var started = false
        private var choosingIcon = false
        private var mouseMonitor: Any?
        private var observers: [NSObjectProtocol] = []

        init(onFinish: @escaping (InlineGroupEditResult) -> Void) { self.onFinish = onFinish }

        @objc func chooseIcon(_ sender: NSPopUpButton) {
            guard !finished, let symbol = sender.selectedItem?.representedObject as? String,
                  let choice = CollectionIcons.choices.first(where: { $0.symbol == symbol }) else { return }
            if let field {
                field.stringValue = choice.title
                field.window?.makeFirstResponder(field)
                if let editor = field.currentEditor() as? NSTextView {
                    editor.string = choice.title
                    editor.selectAll(nil)
                }
            }
            onIconChange(symbol)
        }

        func menuWillOpen(_ menu: NSMenu) { choosingIcon = true }
        func menuDidClose(_ menu: NSMenu) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if !self.finished, let field = self.field, field.window?.isKeyWindow == true {
                    field.window?.makeFirstResponder(field)
                }
                self.choosingIcon = false
            }
        }

        func start() {
            guard !started, !finished, let window = field?.window else { return }
            started = true
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let field = self.field, !self.finished else { return event }
                if self.choosingIcon { return event }
                // Menu item events belong to a separate window. Leaving this
                // window is handled by didResignKey, not by a menu click.
                guard event.window === field.window else { return event }
                if let picker = self.picker, event.window === picker.window,
                   picker.bounds.contains(picker.convert(event.locationInWindow, from: nil)) {
                    self.choosingIcon = true
                    return event
                }
                let region = self.interactionView ?? field
                if !region.bounds.contains(region.convert(event.locationInWindow, from: nil)) {
                    self.endEditing()
                }
                return event
            }
            for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    if self?.choosingIcon != true { self?.endEditing() }
                })
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.finished, let field = self.field, let window = field.window else { return }
                window.makeFirstResponder(field)
            }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                finish(.submitted(currentName)); return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                finish(.cancelled); return true
            }
            if commandSelector == #selector(NSResponder.insertTab(_:)) || commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                finish(.submitted(currentName)); return true
            }
            return false
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            // In the composite editor, only a click outside, window departure,
            // Return/Tab or Esc ends the edit. AppKit may end field editing as
            // the icon menu closes even though the user is still in this editor.
            if interactionView == nil, !choosingIcon { finish(.lostFocus(currentName)) }
        }
        private var currentName: String { field?.currentEditor()?.string ?? field?.stringValue ?? "" }
        private func endEditing() {
            guard !finished else { return }
            field?.window?.makeFirstResponder(nil)
            if !finished { finish(.lostFocus(currentName)) }
        }
        func finish(_ result: InlineGroupEditResult) {
            guard !finished else { return }
            // Return, focus loss and SwiftUI removal may all fire for one edit.
            finished = true
            if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor); self.mouseMonitor = nil }
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            onFinish(result)
        }
    }
}
