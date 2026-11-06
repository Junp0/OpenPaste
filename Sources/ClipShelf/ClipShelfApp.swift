import AppKit
import SwiftUI
import ApplicationServices
import ClipboardCore
import Darwin

@main enum IPasteApp {
    @MainActor static func main() {
        signal(SIGPIPE, SIG_IGN)
        let arguments = CommandLine.arguments
        if arguments.dropFirst().first == "--capture-worker" { CaptureWorker.run(); return }
        let application = NSApplication.shared
        let delegate: NSObject
        if arguments.dropFirst().first == "--shelf-interface" {
            let link = InterfaceConnection(input: .standardInput, output: .standardOutput)
            let action = arguments.count > 2 ? InterfaceMessage.Kind(rawValue: arguments[2]) ?? .toggle : .toggle
            let targetIndex = arguments.firstIndex(of: "--target-pid")
            let targetPID = targetIndex.flatMap { arguments.indices.contains($0 + 1) ? Int32(arguments[$0 + 1]) : nil }
            delegate = AppDelegate(connection: link, initialAction: action, targetPID: targetPID,
                showsWindows: !arguments.contains("--hidden-interface-probe"))
        } else { delegate = ResidentAppDelegate() }
        application.delegate = delegate as? NSApplicationDelegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

final class ShelfPanel: NSPanel {
    private(set) var hasShelfContent = false
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func mountContentIfNeeded<Content: View>(@ViewBuilder _ content: () -> Content) {
        guard !hasShelfContent else { return }
        contentView = NSHostingView(rootView: content())
        hasShelfContent = true
    }

    func releaseContent() {
        // The field editor must not keep the old search field as its responder.
        makeFirstResponder(self)
        contentView = nil
        hasShelfContent = false
    }
}

final class SettingsWindow: NSWindow {
    override func close() {
        makeFirstResponder(nil)
        contentView = nil
        super.close()
    }
}

extension Notification.Name {
    static let focusShelfSearch = Notification.Name("ClipShelf.focusSearch")
    static let shelfDidShow = Notification.Name("ClipShelf.didShow")
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let connection: InterfaceConnection?
    private let initialAction: InterfaceMessage.Kind
    private var idleTimer: Timer?
    private var idleSince: TimeInterval?
    private let showsWindows: Bool
    private var store: ClipboardStore!
    private var panel: ShelfPanel?
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var returnToSettingsAfterPanel = false
    private var previewingDisplaySize = false
    private var recordingShortcut = false
    private let hotKey = GlobalHotKey()
    private var keyMonitor: Any?
    private var panelClickMonitor: Any?
    private var outsideClickMonitor: Any?
    private var targetApplication: NSRunningApplication?
    private var pasteInFlight = false
    private var menuTrackingDepth = 0
    private let searchInput = SearchInputController()
    private let presentation = ShelfPresentation()
    private var panelShouldBeVisible = false
    private var panelTransition: UInt64 = 0
    private var memoryReliefTask: Task<Void, Never>?

    init(connection: InterfaceConnection? = nil, initialAction: InterfaceMessage.Kind = .toggle,
         targetPID: Int32? = nil, showsWindows: Bool = true) {
        self.connection = connection; self.initialAction = initialAction
        self.showsWindows = showsWindows
        self.targetApplication = targetPID.flatMap { NSRunningApplication(processIdentifier: $0) }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        do { store = try ClipboardStore(monitorsClipboard: connection == nil) }
        catch {
            let alert = NSAlert(); alert.messageText = "无法打开OpenPaste"; alert.informativeText = error.localizedDescription
            alert.runModal(); NSApp.terminate(nil); return
        }
        configureMenu()
        NotificationCenter.default.addObserver(self, selector: #selector(menuTrackingBegan(_:)), name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuTrackingEnded(_:)), name: NSMenu.didEndTrackingNotification, object: nil)
        if connection == nil {
            configureStatusItem()
            hotKey.onPress = { [weak self] in self?.togglePanel() }
        }
        store.onShortcutChange = { [weak self] shortcut in
            guard let self else { return false }
            if let connection = self.connection {
                return connection.request(InterfaceMessage(.shortcut, shortcut: shortcut))?.flag == true
            }
            return self.hotKey.register(shortcut)
        }
        store.onShortcutRecordingChange = { [weak self] recording in
            self?.recordingShortcut = recording
            if let connection = self?.connection {
                _ = connection.request(InterfaceMessage(.recordingShortcut, flag: recording)); return
            }
            if recording { self?.hotKey.suspend() }
            else { self?.registerHotKey() }
        }
        store.onStateChange = { [weak self] in self?.updateStatus() }
        if let connection {
            store.onPreferencesChange = { connection.send(InterfaceMessage(.preferencesChanged)) }
            store.onBeforeClipboardRestore = { connection.request(InterfaceMessage(.beginRestore))?.flag == true }
            store.onClipboardRestore = { count in connection.send(InterfaceMessage(.endRestore, changeCount: count)) }
            connection.onMessage = { [weak self] message in
                DispatchQueue.main.async { [weak self] in self?.receive(message) }
            }
            connection.onClose = { DispatchQueue.main.async { NSApp.terminate(nil) } }
            connection.start()
        }
        store.onAppearanceChange = { [weak self] in
            // Apply the new binding value before presenting its preview.
            DispatchQueue.main.async { self?.previewPanelForDisplaySize() }
        }
        store.onDragEnd = { [weak self] completedInside in
            DispatchQueue.main.async {
                guard let self, self.panelShouldBeVisible, let panel = self.panel else { return }
                if completedInside { NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil) }
                else if !panel.isKeyWindow { self.hidePanel() }
            }
        }
        if connection == nil { registerHotKey() }
        installKeyboardHandling()
        installOutsideClickHandling()
        switch initialAction {
        case .settings: openSettings()
        case .about: NSApp.orderFrontStandardAboutPanel(nil)
        default: showPanel()
        }
        if connection != nil {
            idleTimer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.exitInterfaceIfIdle() }
            }
            if let idleTimer { RunLoop.main.add(idleTimer, forMode: .common) }
        }
        if !showsWindows {
            // Integration probe: exercise the actual child process and both
            // view hierarchies without activating the app or showing windows.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.openSettings()
                self?.settingsWindow?.contentView?.layoutSubtreeIfNeeded()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.settingsWindow?.close()
                }
            }
        }
    }
    private func receive(_ message: InterfaceMessage) {
        switch message.kind {
        case .show:
            store.reloadPreferences(); store.perform { try store.reload() }; showPanel()
        case .toggle:
            store.reloadPreferences(); store.perform { try store.reload() }; togglePanel()
        case .settings: store.reloadPreferences(); openSettings()
        case .about: hidePanel(animated: false); NSApp.orderFrontStandardAboutPanel(nil)
        case .historyChanged: store.perform { try store.reload() }
        case .preferencesChanged: store.reloadPreferences()
        case .shutdown: NSApp.terminate(nil)
        default: break
        }
    }
    private func exitInterfaceIfIdle() {
        guard !panelShouldBeVisible, panel == nil, settingsWindow == nil, !pasteInFlight,
              !NSApp.windows.contains(where: { $0.isVisible }) else { idleSince = nil; return }
        let now = ProcessInfo.processInfo.systemUptime
        guard let idleSince else { self.idleSince = now; return }
        guard now - idleSince > 0.25 else { return }
        if connection?.request(InterfaceMessage(.prepareExit))?.flag == true { NSApp.terminate(nil) }
        else { self.idleSince = now }
    }
    private func configureMenu() {
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem(); let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "关于OpenPaste", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let settings = applicationMenu.addItem(withTitle: "设置…", action: #selector(settingsFromMenu), keyEquivalent: ",")
        settings.target = self
        applicationMenu.addItem(.separator())
        let quitItem = applicationMenu.addItem(withTitle: "退出OpenPaste", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        applicationItem.submenu = applicationMenu; mainMenu.addItem(applicationItem)
        let editItem = NSMenuItem(); let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu; mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }
    private func configurePanel() {
        let panel = ShelfPanel(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 440),
            styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = nil
        self.panel = panel
    }
    private func mountShelfContent() {
        guard let panel else { return }
        panel.mountContentIfNeeded {
            ShelfContainerView(presentation: presentation, content: ShelfView(store: store, searchInput: searchInput,
            paste: { [weak self] record, plain in self?.paste(record, plainText: plain) },
            copy: { [weak self] record in self?.copyOnly(record) },
            showSettings: { [weak self] in self?.openSettings() },
            dismiss: { [weak self] in self?.hidePanel(restoreFocus: true) }))
        }
    }
    private func releaseShelfContent() {
        if let panel {
            panel.releaseContent()
            // orderOut alone keeps the window, field editor and backing store.
            panel.delegate = nil
            panel.close()
            self.panel = nil
        }
        store.releaseTransientResources()
        scheduleIdleMemoryRelief()
    }
    private func scheduleIdleMemoryRelief() {
        // Exiting the temporary interface also releases framework caches that a
        // malloc trim cannot reclaim. Capture continues in the resident process.
        guard connection == nil else { return }
        memoryReliefTask?.cancel()
        memoryReliefTask = Task { @MainActor [weak self] in
            // Allow SwiftUI teardown, animations and autorelease pools to finish.
            do { try await Task.sleep(nanoseconds: 1_000_000_000) }
            catch { return }
            guard let self, self.panel == nil, self.settingsWindow == nil else { return }
            self.memoryReliefTask = nil
            // Return unused allocator pages after teardown; never trim in a poll
            // or on the rendering thread, and do not touch live allocations.
            await Task.detached(priority: .utility) {
                _ = malloc_zone_pressure_relief(nil, 0)
            }.value
        }
    }
    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = IPasteLogo.mark
            button.target = self; button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateStatus()
    }
    private func updateStatus() {
        statusItem?.button?.image = store.paused
            ? NSImage(systemSymbolName: "pause.rectangle", accessibilityDescription: "OpenPaste剪贴板 · 已暂停")
            : IPasteLogo.mark
        statusItem?.button?.toolTip = "OpenPaste · \(store.shortcutLabel)\(store.paused ? " · 已暂停" : "")"
    }
    private func registerHotKey() {
        if !hotKey.register(store.shortcut) {
            store.errorMessage = "快捷键被其他应用占用。可以在设置中切换快捷键，或通过菜单栏打开OpenPaste。"
        }
        updateStatus()
    }
    @objc private func statusClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "打开OpenPaste  \(store.shortcutLabel)", action: #selector(openFromMenu), keyEquivalent: "")
            menu.addItem(withTitle: store.paused ? "继续记录" : "暂停记录", action: #selector(togglePause), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "设置…", action: #selector(settingsFromMenu), keyEquivalent: ",")
            menu.addItem(withTitle: "退出OpenPaste", action: #selector(quit), keyEquivalent: "q")
            for item in menu.items { item.target = self }
            statusItem.menu = menu; statusItem.button?.performClick(nil); statusItem.menu = nil
        } else { togglePanel() }
    }
    @objc private func openFromMenu() { showPanel() }
    @objc private func togglePause() { store.paused.toggle() }
    @objc private func settingsFromMenu() { openSettings() }
    @objc private func quit() {
        if let connection { connection.send(InterfaceMessage(.quit)) }
        else { NSApp.terminate(nil) }
    }
    @objc private func menuTrackingBegan(_ notification: Notification) { menuTrackingDepth += 1 }
    @objc private func menuTrackingEnded(_ notification: Notification) {
        menuTrackingDepth = max(0, menuTrackingDepth - 1)
    }

    private func togglePanel() { panelShouldBeVisible ? hidePanel(restoreFocus: true) : showPanel() }
    private func showPanel(forSizePreview: Bool = false) {
        guard !pasteInFlight else { return }
        memoryReliefTask?.cancel(); memoryReliefTask = nil
        if panel == nil { configurePanel() }
        guard let panel else { return }
        if panelShouldBeVisible {
            if !forSizePreview {
                previewingDisplaySize = false
                panel.ignoresMouseEvents = false
                panel.makeKeyAndOrderFront(nil)
            }
            return
        }
        panelTransition &+= 1
        let transition = panelTransition
        panelShouldBeVisible = true
        previewingDisplaySize = forSizePreview
        panel.ignoresMouseEvents = forSizePreview
        store.capturePendingChange()
        let frontmost = NSWorkspace.shared.frontmostApplication
        returnToSettingsAfterPanel = forSizePreview || settingsWindow?.isKeyWindow == true
        if let frontmost, !isOwnApplication(frontmost) { targetApplication = frontmost }
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        if let screen {
            panel.setFrame(ShelfPresentation.frame(screen: screen.frame, visible: screen.visibleFrame, size: store.displaySize), display: true)
        }
        store.prepareToShow()
        mountShelfContent()
        if !showsWindows {
            // A hidden native integration probe must never take user focus.
        } else if forSizePreview {
            // Let Settings keep keyboard focus so the user can compare sizes.
            panel.orderFront(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
        panel.contentView?.layoutSubtreeIfNeeded()
        // AppKit may restore the previous field editor when reopening the panel.
        if !forSizePreview { panel.makeFirstResponder(panel) }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panelShouldBeVisible, self.panelTransition == transition else { return }
            self.presentation.isPresented = true
            NotificationCenter.default.post(name: .shelfDidShow, object: nil)
        }
    }
    private func hidePanel(restoreFocus: Bool = false, animated: Bool = true) {
        guard let panel else { return }
        guard panelShouldBeVisible || (!animated && panel.isVisible) else { return }
        panelTransition &+= 1
        let transition = panelTransition
        panelShouldBeVisible = false
        previewingDisplaySize = false
        store.endClipDrag(completedInside: false)
        store.previewID = nil
        presentation.isPresented = false
        if animated {
            DispatchQueue.main.asyncAfter(deadline: .now() + presentation.hideDuration) { [weak self] in
                guard let self, self.panelTransition == transition, !self.panelShouldBeVisible else { return }
                self.panel?.orderOut(nil)
                self.releaseShelfContent()
            }
        } else {
            panel.orderOut(nil)
            releaseShelfContent()
        }
        if restoreFocus {
            if returnToSettingsAfterPanel, let settingsWindow, settingsWindow.isVisible {
                settingsWindow.makeKeyAndOrderFront(nil)
            } else {
                targetApplication?.activate(options: [])
            }
        }
    }
    func windowDidResignKey(_ notification: Notification) {
        // A size selection may temporarily move focus without an outside click.
        // Temporary previews are dismissed by explicit interaction below.
        if previewingDisplaySize { return }
        guard let panel, let window = notification.object as? NSWindow, window === panel, panel.attachedSheet == nil, menuTrackingDepth == 0, store.draggedRecordID == nil else { return }
        hidePanel()
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        if previewingDisplaySize { hidePanel(animated: false) }
        window.contentView = nil
        settingsWindow = nil
        scheduleIdleMemoryRelief()
    }
    func windowDidMiniaturize(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === settingsWindow, previewingDisplaySize {
            hidePanel()
        }
    }
    func applicationDidResignActive(_ notification: Notification) {
        if previewingDisplaySize { hidePanel() }
    }
    private func installOutsideClickHandling() {
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        panelClickMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            guard let self, let panel = self.panel, self.panelShouldBeVisible, panel.attachedSheet == nil,
                  self.store.draggedRecordID == nil, self.menuTrackingDepth == 0 else { return event }
            // The status button already toggles the panel in its own action.
            if event.window === self.statusItem.button?.window { return event }
            let insideWindow = self.previewingDisplaySize ? self.settingsWindow : panel
            if event.window !== insideWindow { self.hidePanel() }
            return event
        }
        // Local monitors do not receive clicks on the desktop or in other apps.
        // Observe mouse clicks only; the original event keeps reaching its target.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            guard let self, let panel = self.panel, self.panelShouldBeVisible, panel.attachedSheet == nil,
                  self.store.draggedRecordID == nil else { return }
            self.hidePanel()
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showPanel(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    private func resizePanelForDisplaySize() {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        panel.setFrame(ShelfPresentation.frame(screen: screen.frame, visible: screen.visibleFrame, size: store.displaySize), display: true)
    }
    private func previewPanelForDisplaySize() {
        resizePanelForDisplaySize()
        guard settingsWindow?.isVisible == true, settingsWindow?.isMiniaturized != true else { return }
        showPanel(forSizePreview: true)
    }

    private func installKeyboardHandling() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.menuTrackingDepth == 0 else { return event }
            // Settings stays open; only the shelf responds to its wake shortcut.
            if self.settingsWindow?.isKeyWindow == true, self.settingsWindow?.attachedSheet == nil,
               !self.recordingShortcut, ShelfShortcut(event: event) == self.store.shortcut {
                if !event.isARepeat { self.togglePanel() }
                return nil
            }
            guard let panel = self.panel, panel.isKeyWindow, panel.attachedSheet == nil else { return event }
            let panelAction = ShelfPanelKeyAction.matching(event, shortcut: self.store.shortcut)
            if panelAction == .dismiss { self.hidePanel(restoreFocus: true); return nil }
            if self.store.isCreatingCollection { return event }
            let editor = panel.firstResponder as? NSTextView
            // Candidate selection, confirmation, and cancellation belong to the IME.
            if editor?.hasMarkedText() == true { return event }
            let plainSpace = event.keyCode == 49 && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
            if self.store.previewID != nil {
                if event.keyCode == 36 || event.keyCode == 76 {
                    if !event.isARepeat, let record = self.store.records.first(where: { $0.id == self.store.previewID }) {
                        self.paste(record, plainText: event.modifierFlags.contains([.command, .shift]))
                    }
                    return nil
                }
                if plainSpace || event.keyCode == 53 {
                    if !event.isARepeat { self.store.previewID = nil }
                    return nil
                }
                return event
            }
            if panelAction == .previousGroup { self.store.cycleGroup(by: -1); return nil }
            if panelAction == .nextGroup { self.store.cycleGroup(by: 1); return nil }
            let editing = editor != nil
            let command = event.modifierFlags.contains(.command)
            if event.keyCode == 53 { self.hidePanel(restoreFocus: true); return nil }
            if command, event.charactersIgnoringModifiers == "," { self.openSettings(); return nil }
            if command, event.charactersIgnoringModifiers == "f" {
                NotificationCenter.default.post(name: .focusShelfSearch, object: nil); return nil
            }
            if command, let number = Int(event.charactersIgnoringModifiers ?? ""), (1...9).contains(number) {
                let items = self.store.visibleRecords
                if items.indices.contains(number - 1) { self.paste(items[number - 1]) }; return nil
            }
            if event.keyCode == 36 || event.keyCode == 76 {
                if let record = self.store.selected { self.paste(record, plainText: command && event.modifierFlags.contains(.shift)) }
                return nil
            }
            if ShelfPanelKeyAction.deletesSelectedRecord(event, isEditing: editing),
               let record = self.store.selected {
                if !event.isARepeat { self.store.delete(record) }
                return nil
            }
            if event.keyCode == 125 || event.keyCode == 126 || ((event.keyCode == 123 || event.keyCode == 124) && (!editing || self.store.query.isEmpty)) {
                self.searchInput.blur()
                panel.makeFirstResponder(panel)
                self.store.moveSelection((event.keyCode == 123 || event.keyCode == 126) ? -1 : 1); return nil
            }
            if plainSpace, (!editing || self.store.query.isEmpty), let record = self.store.selected {
                if !event.isARepeat { self.store.previewID = record.id }
                return nil
            }
            if command, event.charactersIgnoringModifiers == "c", !editing, let record = self.store.selected {
                self.copyOnly(record); return nil
            }
            if SearchKeyRouting.shouldFocusSearch(event, isEditing: editing) {
                // Synchronous focus preserves the first key, dead keys, and IME events.
                // Returning the original event lets AppKit deliver it to the new editor.
                self.searchInput.focus(caretAtEnd: true)
            }
            return event
        }
    }
    private func copyOnly(_ record: ClipboardCore.ClipRecord) {
        if store.copy(record) { store.message = "已复制 · 在目标应用中按 ⌘V 粘贴" }
    }
    private func isOwnApplication(_ app: NSRunningApplication) -> Bool {
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier ||
           (connection != nil && app.processIdentifier == getppid()) { return true }
        return Bundle.main.bundleIdentifier.map { app.bundleIdentifier == $0 } ?? false
    }
    private func paste(_ record: ClipboardCore.ClipRecord, plainText: Bool = false) {
        guard !pasteInFlight, store.preparePaste(record, plainText: plainText) else { return }
        guard let targetApplication, !targetApplication.isTerminated,
              !isOwnApplication(targetApplication) else {
            store.message = "已复制 · 请切换到目标应用按 ⌘V"; return
        }
        guard AXIsProcessTrusted() else {
            store.message = "已复制 · 开启辅助功能后可直接粘贴"
            let alert = NSAlert()
            alert.messageText = "内容已复制到剪贴板"
            alert.informativeText = "直接粘贴需要辅助功能权限。开启后，OpenPaste才能替你向原来的应用发送 ⌘V。现在也可以关闭面板，手动粘贴。"
            alert.addButton(withTitle: "开启辅助功能")
            alert.addButton(withTitle: "手动粘贴")
            guard let panel else { return }
            alert.beginSheetModal(for: panel) { [weak self] response in
                self?.hidePanel()
                if response == .alertFirstButtonReturn { Self.requestAccessibility() }
                else { targetApplication.activate(options: []) }
            }
            return
        }
        pasteInFlight = true
        hidePanel()
        targetApplication.activate(options: [])
        sendPaste(whenActive: targetApplication, attempts: 12)
    }
    private func sendPaste(whenActive target: NSRunningApplication, attempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
                // Wait until physical shortcut modifiers are up before sending ⌘V.
                let physicalFlags = CGEventSource.flagsState(.combinedSessionState)
                if !physicalFlags.intersection([.maskShift, .maskAlternate, .maskCommand, .maskControl]).isEmpty, attempts > 0 {
                    self.sendPaste(whenActive: target, attempts: attempts - 1); return
                }
                guard physicalFlags.intersection([.maskShift, .maskAlternate, .maskCommand, .maskControl]).isEmpty,
                      let source = CGEventSource(stateID: .privateState),
                      let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
                    self.pasteInFlight = false; self.store.message = "已复制 · 请手动按 ⌘V"; return
                }
                down.flags = .maskCommand; up.flags = .maskCommand
                down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
                self.pasteInFlight = false
            } else if attempts > 0 { self.sendPaste(whenActive: target, attempts: attempts - 1) }
            else { self.pasteInFlight = false; self.store.message = "已复制 · 目标应用未就绪，请手动粘贴" }
        }
    }
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
    private func openSettings() {
        hidePanel(animated: false)
        memoryReliefTask?.cancel(); memoryReliefTask = nil
        if settingsWindow == nil {
            let window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 720), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "OpenPaste 设置"; window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.canHide = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: PreferencesView(store: store))
            window.center(); settingsWindow = window
        }
        if showsWindows {
            NSApp.activate(ignoringOtherApps: true)
            settingsWindow?.makeKeyAndOrderFront(nil)
        }
    }
}
