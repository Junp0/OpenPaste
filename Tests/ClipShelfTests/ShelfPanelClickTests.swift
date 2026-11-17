import AppKit
import Testing
@testable import ClipShelf

@Suite @MainActor struct ShelfPanelClickTests {
    private func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func click(in window: NSWindow?, count: Int = 1, type: NSEvent.EventType = .leftMouseDown) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: 100, y: 100),
            modifierFlags: [], timestamp: 0, windowNumber: window?.windowNumber ?? 0,
            context: nil, eventNumber: 1, clickCount: count, pressure: 1))
    }

    @Test func interfaceClicksStayInsideWithoutAResidentStatusItem() throws {
        let panel = window()
        defer { panel.close() }
        // The real interface process has no menu bar item. Both card clicks
        // must reach SwiftUI, which selects on one click and pastes on two.
        for count in [1, 2] {
            let event = try click(in: panel, count: count)
            #expect(event.window === panel)
            #expect(!ShelfPanelClickAction.shouldDismiss(event, inside: panel, statusItem: nil))
        }
        #expect(!ShelfPanelClickAction.shouldDismiss(try click(in: panel, type: .rightMouseDown),
            inside: panel, statusItem: nil))
    }

    @Test func clicksInOtherWindowsStillDismissThePanel() throws {
        let panel = window()
        let other = window()
        defer { panel.close(); other.close() }
        #expect(ShelfPanelClickAction.shouldDismiss(try click(in: other), inside: panel, statusItem: nil))
        #expect(ShelfPanelClickAction.shouldDismiss(try click(in: nil), inside: panel, statusItem: nil))
        // During a size preview, Settings is the window that stays interactive.
        #expect(!ShelfPanelClickAction.shouldDismiss(try click(in: other), inside: other, statusItem: nil))
    }
}
