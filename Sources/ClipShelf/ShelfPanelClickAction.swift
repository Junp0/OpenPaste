import AppKit

enum ShelfPanelClickAction {
    static func shouldDismiss(_ event: NSEvent, inside window: NSWindow?, statusItem: NSStatusItem?) -> Bool {
        // The interface child has no status item; only the resident process
        // owns one. Its button already toggles the panel in its own action.
        if let statusWindow = statusItem?.button?.window, event.window === statusWindow { return false }
        return event.window !== window
    }
}
