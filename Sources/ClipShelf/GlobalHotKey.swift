import AppKit
import Carbon

final class GlobalHotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var registeredShortcut: ShelfShortcut?
    private var nextID: UInt32 = 0
    var onPress: (() -> Void)?
    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
            hotKey.onPress?()
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func register(_ shortcut: ShelfShortcut) -> Bool {
        guard shortcut.isValid else { return false }
        if reference != nil, registeredShortcut == shortcut { return true }
        nextID &+= 1
        let id = EventHotKeyID(signature: 0x43534846, id: nextID)
        var candidate: EventHotKeyRef?
        guard RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &candidate) == noErr,
              let candidate else { return false }
        // Commit only after registration succeeds, preserving the old binding on conflict.
        if let reference { UnregisterEventHotKey(reference) }
        reference = candidate; registeredShortcut = shortcut
        return true
    }
    func suspend() {
        if let reference { UnregisterEventHotKey(reference); self.reference = nil }
    }
    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}
