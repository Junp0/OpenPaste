import Foundation
import Darwin

/// Only inherited anonymous pipes connect the resident process to its own UI.
/// No network listener, distributed notification, or clipboard content is used.
struct InterfaceMessage: Codable, Equatable {
    enum Kind: String, Codable {
        case show, toggle, settings, about, shutdown, historyChanged, preferencesChanged
        case shortcut, cancelShortcut, recordingShortcut, beginRestore, endRestore, quit
        case prepareExit, reply
    }
    let kind: Kind
    var id: String?
    var shortcut: ShelfShortcut?
    var flag: Bool?
    var changeCount: Int?

    init(_ kind: Kind, id: String? = nil, shortcut: ShelfShortcut? = nil,
         flag: Bool? = nil, changeCount: Int? = nil) {
        self.kind = kind; self.id = id; self.shortcut = shortcut
        self.flag = flag; self.changeCount = changeCount
    }
}

final class InterfaceConnection: @unchecked Sendable {
    private final class Reply {
        let semaphore = DispatchSemaphore(value: 0)
        var message: InterfaceMessage?
    }
    private let input: FileHandle
    private let output: FileHandle
    private let lock = NSLock()
    private let writeLock = NSLock()
    private let readLock = NSLock()
    private var buffer = Data()
    private var replies: [String: Reply] = [:]
    private var closed = false
    var onMessage: ((InterfaceMessage) -> Void)?
    var onClose: (() -> Void)?

    init(input: FileHandle, output: FileHandle) {
        self.input = input; self.output = output
    }

    func start() {
        let descriptor = input.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        input.readabilityHandler = { [weak self] _ in
            guard let self else { return }
            self.readLock.lock()
            self.lock.lock(); let isClosed = self.closed; self.lock.unlock()
            guard !isClosed else { self.readLock.unlock(); return }
            // FileHandle.read(upToCount:) may wait to fill the requested buffer
            // on pipes. A nonblocking POSIX read also handles fragmented writes.
            var bytes = [UInt8](repeating: 0, count: 16 * 1024)
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            let readError = errno
            self.readLock.unlock()
            if count > 0 { self.receive(Data(bytes.prefix(count))) }
            else if count == 0 || (readError != EAGAIN && readError != EINTR) { self.finish() }
        }
    }

    @discardableResult func send(_ message: InterfaceMessage) -> Bool {
        guard var data = try? JSONEncoder().encode(message), data.count < 4096 else { return false }
        data.append(10)
        writeLock.lock(); defer { writeLock.unlock() }
        lock.lock(); let canWrite = !closed; lock.unlock()
        guard canWrite else { return false }
        do { try output.write(contentsOf: data); return true }
        catch { return false }
    }

    /// Replies are delivered on the pipe's reader thread, independent of the UI
    /// main run loop. This preserves synchronous shortcut validation and makes
    /// clipboard restoration atomic with respect to the resident monitor.
    func request(_ message: InterfaceMessage, timeout: TimeInterval = 3) -> InterfaceMessage? {
        let id = UUID().uuidString
        var request = message; request.id = id
        let reply = Reply()
        lock.lock()
        guard !closed else { lock.unlock(); return nil }
        replies[id] = reply
        lock.unlock()
        let sent = send(request)
        let completed = sent && reply.semaphore.wait(timeout: .now() + timeout) == .success
        lock.lock()
        replies.removeValue(forKey: id)
        let result = completed ? reply.message : nil
        lock.unlock()
        if result == nil, message.kind == .shortcut {
            send(InterfaceMessage(.cancelShortcut, id: id))
        }
        return result
    }

    private func receive(_ data: Data) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        buffer.append(data)
        guard buffer.count <= 64 * 1024 else { lock.unlock(); finish(); return }
        var messages: [InterfaceMessage] = []
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer[..<newline]
            if let message = try? JSONDecoder().decode(InterfaceMessage.self, from: line) {
                messages.append(message)
            }
            buffer.removeSubrange(...newline)
        }
        var ordinary: [InterfaceMessage] = []
        for message in messages {
            if message.kind == .reply, let id = message.id, let reply = replies[id] {
                reply.message = message
                reply.semaphore.signal()
            } else { ordinary.append(message) }
        }
        lock.unlock()
        for message in ordinary { onMessage?(message) }
    }

    private func finish() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        for reply in replies.values { reply.semaphore.signal() }
        buffer.removeAll(); lock.unlock()
        input.readabilityHandler = nil
        onClose?()
    }

    func close() {
        finish()
        readLock.lock(); try? input.close(); readLock.unlock()
        writeLock.lock(); try? output.close(); writeLock.unlock()
    }
    deinit { input.readabilityHandler = nil }
}
