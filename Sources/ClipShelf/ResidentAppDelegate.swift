import AppKit
import Darwin

/// Owns clipboard capture, the status item and the global hot key for the whole
/// application session. The interface exists only while there is a visible UI.
@MainActor final class ResidentAppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: ClipboardMonitor!
    private let hotKey = GlobalHotKey()
    private var statusItem: NSStatusItem!
    private var interfaceProcess: Process?
    private var connection: InterfaceConnection?
    private var shortcut = ShelfShortcut.standard
    private var errorMessage: String?
    private var isTerminating = false
    private var interfaceEnding = false
    private var pendingPresentation: InterfaceMessage.Kind?
    private var lastPresentation = -Double.infinity
    private var memoryReliefTask: Task<Void, Never>?
    private var captureProcess: Process?
    private var pendingCapture: CaptureWorkerRequest?
    private var capturePresentation: InterfaceMessage.Kind?
    private var captureTimeout: DispatchWorkItem?
    private var verifiesFirstInterface = CommandLine.arguments.contains("--verify-background-memory")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        do { monitor = try ClipboardMonitor() }
        catch {
            let alert = NSAlert(); alert.messageText = "无法打开OpenPaste"; alert.informativeText = error.localizedDescription
            alert.runModal(); NSApp.terminate(nil); return
        }
        monitor.onCapture = { [weak self] bytes in
            self?.connection?.send(InterfaceMessage(.historyChanged))
            if bytes >= 1024 * 1024 { self?.scheduleMemoryRelief() }
        }
        monitor.onError = { [weak self] error in self?.errorMessage = error; self?.updateStatus() }
        monitor.onLargeRead = { [weak self] in self?.scheduleMemoryRelief() }
        monitor.captureRequest = { [weak self] changeCount, source in
            guard let self else { return }
            let request = CaptureWorkerRequest(pasteboardName: NSPasteboard.Name.general.rawValue,
                changeCount: changeCount, databasePath: self.monitor.databaseURL.path,
                sourceName: source?.localizedName ?? "未知应用", sourceBundle: source?.bundleIdentifier ?? "")
            self.enqueueCapture(request)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        hotKey.onPress = { [weak self] in self?.present(.toggle) }
        reloadPreferences()
        if !CommandLine.arguments.contains("--background") || verifiesFirstInterface { present(.show) }
    }

    private func reloadPreferences() {
        monitor.reloadPreferences()
        shortcut = ShelfShortcut.load(from: .standard)
        if !hotKey.register(shortcut) { errorMessage = "快捷键无法注册，请从菜单栏打开设置。" }
        updateStatus()
    }
    private func updateStatus() {
        statusItem?.button?.image = monitor.paused
            ? NSImage(systemSymbolName: "pause.rectangle", accessibilityDescription: "OpenPaste · 已暂停")
            : IPasteLogo.mark
        statusItem?.button?.toolTip = errorMessage ?? "OpenPaste · \(shortcut.displayLabel)\(monitor.paused ? " · 已暂停" : "")"
    }

    @objc private func statusClicked(_ sender: Any?) {
        guard NSApp.currentEvent?.type == .rightMouseUp else { present(.toggle); return }
        let menu = NSMenu()
        for (title, action) in [
            ("打开OpenPaste  \(shortcut.displayLabel)", #selector(openShelf)),
            (monitor.paused ? "继续记录" : "暂停记录", #selector(togglePause)),
            ("设置…", #selector(openSettings)),
            ("关于OpenPaste", #selector(openAbout)),
            ("退出OpenPaste", #selector(quit))
        ] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
        statusItem.menu = menu; statusItem.button?.performClick(nil); statusItem.menu = nil
    }
    @objc private func openShelf() { present(.show) }
    @objc private func openSettings() { present(.settings) }
    @objc private func openAbout() { present(.about) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func togglePause() {
        monitor.setPaused(!monitor.paused); updateStatus()
        connection?.send(InterfaceMessage(.preferencesChanged))
    }

    private func present(_ action: InterfaceMessage.Kind) {
        guard !isTerminating else { return }
        lastPresentation = ProcessInfo.processInfo.systemUptime
        monitor.poll()
        if let interfaceProcess, interfaceProcess.isRunning {
            if interfaceEnding {
                pendingPresentation = action == .toggle && pendingPresentation == .toggle ? nil : action
            } else { connection?.send(InterfaceMessage(action)) }
            return
        }
        // Opening immediately after copying must select the newly captured clip,
        // rather than racing a worker that has not committed its row yet.
        if captureProcess != nil {
            capturePresentation = action == .toggle && capturePresentation == .toggle ? nil : action
            return
        }
        guard let executable = Bundle.main.executableURL else { return }
        let process = Process()
        let commands = Pipe(), events = Pipe()
        process.executableURL = executable
        process.arguments = ["--shelf-interface", action.rawValue]
        if verifiesFirstInterface {
            verifiesFirstInterface = false
            process.arguments?.append("--hidden-interface-probe")
        }
        if let target = monitor.targetApplication {
            process.arguments?.append(contentsOf: ["--target-pid", String(target.processIdentifier)])
        }
        process.standardInput = commands; process.standardOutput = events
        let link = InterfaceConnection(input: events.fileHandleForReading, output: commands.fileHandleForWriting)
        link.onMessage = { [weak self, weak link] message in
            DispatchQueue.main.async { [weak self, weak link] in
                guard let self, let link, self.connection === link else { return }
                self.receive(message, from: link)
            }
        }
        process.terminationHandler = { [weak self, weak link] _ in
            DispatchQueue.main.async { [weak self, weak link] in
                guard let self, let link, self.connection === link else { return }
                link.close(); self.connection = nil; self.interfaceProcess = nil
                self.monitor.interfaceProcessIdentifier = nil
                self.interfaceEnding = false
                self.monitor.interfaceDidExit()
                self.reloadPreferences()
                // UI frameworks never initialized in this process. Return any
                // transient SQLite/capture allocations to the OS after UI exit.
                self.scheduleMemoryRelief()
                if let pending = self.pendingPresentation {
                    self.pendingPresentation = nil
                    self.present(pending)
                }
            }
        }
        interfaceEnding = false
        interfaceProcess = process; connection = link
        do {
            try process.run()
            monitor.interfaceProcessIdentifier = process.processIdentifier
            // Only the child owns these ends. Keeping them open in the parent
            // would prevent EOF from signalling a crashed/terminated process.
            try? commands.fileHandleForReading.close()
            try? events.fileHandleForWriting.close()
            link.start()
        }
        catch {
            link.close(); interfaceProcess = nil; connection = nil
            monitor.interfaceProcessIdentifier = nil
            errorMessage = "无法打开界面：\(error.localizedDescription)"; updateStatus()
        }
    }

    private func receive(_ message: InterfaceMessage, from link: InterfaceConnection) {
        switch message.kind {
        case .preferencesChanged: reloadPreferences()
        case .shortcut:
            let accepted = message.shortcut.map { $0.isValid && hotKey.register($0) } ?? false
            link.send(InterfaceMessage(.reply, id: message.id, flag: accepted))
        case .cancelShortcut: reloadPreferences()
        case .recordingShortcut:
            if message.flag == true { hotKey.suspend() }
            else { reloadPreferences() }
            if message.id != nil { link.send(InterfaceMessage(.reply, id: message.id, flag: true)) }
        case .beginRestore:
            pendingCapture = nil
            monitor.beginRestore()
            link.send(InterfaceMessage(.reply, id: message.id, flag: true))
        case .endRestore:
            if let count = message.changeCount { monitor.endRestore(changeCount: count) }
        case .prepareExit:
            let canExit = ProcessInfo.processInfo.systemUptime - lastPresentation > 0.3
            if canExit { interfaceEnding = true }
            link.send(InterfaceMessage(.reply, id: message.id, flag: canExit))
        case .quit: NSApp.terminate(nil)
        default: break
        }
    }

    private func enqueueCapture(_ request: CaptureWorkerRequest) {
        guard !isTerminating else { return }
        if captureProcess != nil { pendingCapture = request; return }
        guard let executable = Bundle.main.executableURL,
              let data = try? JSONEncoder().encode(request) else { return }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = executable; process.arguments = ["--capture-worker"]
        process.standardInput = input; process.standardOutput = output
        process.terminationHandler = { [weak self, weak process] _ in
            let data = output.fileHandleForReading.readDataToEndOfFile()
            try? output.fileHandleForReading.close()
            let result = (try? JSONDecoder().decode(CaptureWorkerResult.self, from: data))
                ?? CaptureWorkerResult(status: .failed, error: "剪贴板读取任务未能完成。")
            DispatchQueue.main.async { [weak self, weak process] in
                guard let self, let process, self.captureProcess === process else { return }
                self.captureTimeout?.cancel(); self.captureTimeout = nil
                self.captureProcess = nil
                if !self.isTerminating { self.monitor.capturedInWorker(result) }
                self.resumeAfterCapture()
            }
        }
        captureProcess = process
        do {
            try process.run()
            try? input.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            try input.fileHandleForWriting.write(contentsOf: data)
            try input.fileHandleForWriting.close()
            let timeout = DispatchWorkItem { [weak self, weak process] in
                guard let self, let process, self.captureProcess === process, process.isRunning else { return }
                // An unresponsive promised flavor must not leave a worker alive.
                process.terminate()
            }
            captureTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
        } catch {
            captureTimeout?.cancel(); captureTimeout = nil
            try? input.fileHandleForWriting.close(); try? output.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            captureProcess = nil
            monitor.capturedInWorker(CaptureWorkerResult(status: .failed, error: error.localizedDescription))
            resumeAfterCapture()
        }
    }

    private func resumeAfterCapture() {
        guard !isTerminating else { return }
        if let pending = pendingCapture {
            pendingCapture = nil; enqueueCapture(pending)
        } else if let action = capturePresentation {
            capturePresentation = nil; present(action)
        }
    }

    private func scheduleMemoryRelief() {
        memoryReliefTask?.cancel()
        memoryReliefTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 500_000_000) }
            catch { return }
            self?.memoryReliefTask = nil
            await Task.detached(priority: .utility) { _ = malloc_zone_pressure_relief(nil, 0) }.value
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        present(.show); return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        memoryReliefTask?.cancel()
        captureTimeout?.cancel()
        monitor?.stop(); hotKey.suspend()
        connection?.send(InterfaceMessage(.shutdown))
        // Terminate a stuck interface as well; clipboard transactions are atomic.
        if interfaceProcess?.isRunning == true { interfaceProcess?.terminate() }
        if captureProcess?.isRunning == true { captureProcess?.terminate() }
        connection?.close()
    }
}
