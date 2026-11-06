import Foundation
import Testing
@testable import ClipShelf

@Suite struct InterfaceConnectionTests {
    private func pair() -> (InterfaceConnection, InterfaceConnection) {
        let commands = Pipe(), events = Pipe()
        return (InterfaceConnection(input: events.fileHandleForReading, output: commands.fileHandleForWriting),
                InterfaceConnection(input: commands.fileHandleForReading, output: events.fileHandleForWriting))
    }

    @Test func synchronousRequestReceivesReplyWithoutTheMainRunLoop() {
        let (resident, interface) = pair()
        defer { resident.close(); interface.close() }
        resident.onMessage = { [weak resident] message in
            resident?.send(InterfaceMessage(.reply, id: message.id, flag: message.shortcut?.isValid))
        }
        resident.start(); interface.start()
        let response = interface.request(InterfaceMessage(.shortcut, shortcut: .standard))
        #expect(response?.flag == true)
        #expect(response?.kind == .reply)
    }

    @Test func timedOutShortcutRequestCancelsItsUncommittedRegistration() {
        let (resident, interface) = pair()
        defer { resident.close(); interface.close() }
        let cancelled = DispatchSemaphore(value: 0)
        resident.onMessage = { message in
            if message.kind == .cancelShortcut { cancelled.signal() }
        }
        resident.start(); interface.start()
        #expect(interface.request(InterfaceMessage(.shortcut, shortcut: .standard), timeout: 0.05) == nil)
        #expect(cancelled.wait(timeout: .now() + 2) == .success)
    }

    @Test func restoreIsAcknowledgedBeforeTheClipboardWriterContinues() {
        let (resident, interface) = pair()
        defer { resident.close(); interface.close() }
        let restored = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var isRestoring = false
        resident.onMessage = { [weak resident] message in
            lock.lock(); defer { lock.unlock() }
            if message.kind == .beginRestore {
                isRestoring = true
                resident?.send(InterfaceMessage(.reply, id: message.id, flag: true))
            } else if message.kind == .endRestore, message.changeCount == 42 {
                isRestoring = false; restored.signal()
            }
        }
        resident.start(); interface.start()
        #expect(interface.request(InterfaceMessage(.beginRestore))?.flag == true)
        lock.lock(); let began = isRestoring; lock.unlock()
        #expect(began)
        #expect(interface.send(InterfaceMessage(.endRestore, changeCount: 42)))
        #expect(restored.wait(timeout: .now() + 2) == .success)
        lock.lock(); let ended = !isRestoring; lock.unlock()
        #expect(ended)
    }

    @Test func fragmentedAndCoalescedMessagesPreserveBoundariesAndOrder() throws {
        let input = Pipe(), output = Pipe()
        let receiver = InterfaceConnection(input: input.fileHandleForReading, output: output.fileHandleForWriting)
        defer { receiver.close(); try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close() }
        let delivered = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var messages: [InterfaceMessage] = []
        receiver.onMessage = { message in
            lock.lock(); messages.append(message); let complete = messages.count == 3; lock.unlock()
            if complete { delivered.signal() }
        }
        receiver.start()
        let expected = [InterfaceMessage(.show, id: "中文\n换行"), InterfaceMessage(.settings), InterfaceMessage(.prepareExit)]
        var data = Data()
        for message in expected {
            data.append(try JSONEncoder().encode(message)); data.append(10)
        }
        try input.fileHandleForWriting.write(contentsOf: data.prefix(7))
        try input.fileHandleForWriting.write(contentsOf: data.dropFirst(7))
        #expect(delivered.wait(timeout: .now() + 2) == .success)
        lock.lock(); let received = messages; lock.unlock()
        #expect(received == expected)
    }

    @Test func parentDisconnectionClosesTheChannelAndReleasesPendingRequests() {
        let commands = Pipe(), events = Pipe()
        let interface = InterfaceConnection(input: commands.fileHandleForReading, output: events.fileHandleForWriting)
        defer { interface.close(); try? events.fileHandleForReading.close() }
        let closed = DispatchSemaphore(value: 0)
        interface.onClose = { closed.signal() }
        interface.start()
        try? commands.fileHandleForWriting.close()
        #expect(closed.wait(timeout: .now() + 2) == .success)
        #expect(interface.request(InterfaceMessage(.prepareExit), timeout: 0.05) == nil)
        #expect(!interface.send(InterfaceMessage(.toggle)))
    }
}
