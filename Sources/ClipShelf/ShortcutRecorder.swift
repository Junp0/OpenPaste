import AppKit
import SwiftUI

struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: ShelfShortcut
    let onChange: (ShelfShortcut) -> Bool
    let onRecordingChange: (Bool) -> Void
    let onValidationError: (String) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let view = ShortcutRecorderButton()
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ view: ShortcutRecorderButton, context: Context) {
        view.shortcut = shortcut
        view.onChange = onChange
        view.onRecordingChange = onRecordingChange
        view.onValidationError = onValidationError
        view.refreshTitle()
    }
    static func dismantleNSView(_ view: ShortcutRecorderButton, coordinator: ()) { view.finishRecording() }
}

final class ShortcutRecorderButton: NSButton {
    var shortcut = ShelfShortcut.standard
    var onChange: ((ShelfShortcut) -> Bool)?
    var onRecordingChange: ((Bool) -> Void)?
    var onValidationError: ((String) -> Void)?
    private var recording = false
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded; setButtonType(.momentaryPushIn)
        font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        target = self; action = #selector(toggleRecording)
        setAccessibilityLabel("自定义唤起快捷键")
        setAccessibilityHelp("点击后按下新的组合键，按 Escape 取消。")
        refreshTitle()
    }
    required init?(coder: NSCoder) { nil }

    func refreshTitle() {
        if !recording { title = shortcut.displayLabel + "   点击录入" }
    }
    @objc private func toggleRecording() {
        if recording { finishRecording(); return }
        guard window?.makeFirstResponder(self) == true else { return }
        recording = true; title = "按下组合键…"
        // Temporarily unregister the global hotkey so its current combination
        // can be recorded too, without opening the shelf over Settings.
        onRecordingChange?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.recording else { return event }
            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                if event.window !== self.window || !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                    self.finishRecording()
                }
                return event
            }
            guard event.window === self.window else { return event }
            if event.type == .flagsChanged {
                let label = ShelfShortcut.modifierLabel(ShelfShortcut.carbonModifiers(for: event.modifierFlags))
                self.title = label.isEmpty ? "按下组合键…" : label + " …"
                return event
            }
            if event.isARepeat { return nil }
            if event.keyCode == 53 && ShelfShortcut.carbonModifiers(for: event.modifierFlags) == 0 {
                self.finishRecording(); return nil
            }
            let candidate = ShelfShortcut(event: event)
            guard candidate.isValid else {
                self.onValidationError?("请按下包含 ⌘、⌥ 或 ⌃ 的组合键，单独按 Shift 无效。")
                return nil
            }
            if self.onChange?(candidate) == true {
                self.shortcut = candidate
                self.finishRecording()
            }
            return nil
        }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.finishRecording()
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.finishRecording()
        })
    }
    func finishRecording() {
        guard recording else { return }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        refreshTitle()
        onRecordingChange?(false)
    }
    override func resignFirstResponder() -> Bool {
        finishRecording()
        return super.resignFirstResponder()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { finishRecording() }
    }
}
