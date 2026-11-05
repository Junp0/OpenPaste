import AppKit
import ClipboardCore
import SwiftUI
import Testing
@testable import ClipShelf

@Suite @MainActor struct ShelfReopenScrollTests {
    private func settle(_ view: NSView) async throws {
        for _ in 0..<4 {
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? [])
            + view.subviews.flatMap { scrollViews(in: $0) }
    }

    @Test func reopeningRevealsThePastedCardEvenWhenItsSelectedIDDoesNotChange() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ClipboardStore(dataDirectory: directory, monitorsClipboard: false)
        let now = Date()
        for index in 0..<30 {
            let text = "测试卡片 \(index)"
            try store.database.save(ClipDraft(kind: .text, title: text, text: text,
                sourceName: "Test", sourceBundle: "test.app",
                payload: ClipPayload(items: [[ClipRepresentation(type: "public.utf8-plain-text", data: Data(text.utf8))]])),
                now: now.addingTimeInterval(Double(-index - 1)))
        }
        try store.reload()
        let old = store.records[15]
        store.selectCard(old)

        // Mount the real shelf in a hidden window. Never activate it or touch
        // the user's history, general clipboard, or frontmost application.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 470),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let hosting = NSHostingView(rootView: ShelfView(store: store, searchInput: SearchInputController(),
            paste: { _, _ in }, copy: { _ in }, showSettings: {}, dismiss: {}))
        window.contentView = hosting
        try await settle(hosting)
        let scroll = try #require(scrollViews(in: hosting).max {
            ($0.documentView?.frame.width ?? 0) < ($1.documentView?.frame.width ?? 0)
        })
        #expect((scroll.documentView?.frame.width ?? 0) > scroll.contentView.bounds.width * 2)
        scroll.contentView.scroll(to: NSPoint(x: 1600, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle(hosting)
        #expect(scroll.contentView.bounds.minX > 1000)

        let board = NSPasteboard(name: NSPasteboard.Name("io.clipshelf.reopen-tests.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        #expect(store.preparePaste(old, to: board))
        try await settle(hosting)
        #expect(store.records.first?.id == old.id)
        #expect(store.selectedID == old.id)
        // This is the reported failure: data is reordered but the viewport is stale.
        #expect(scroll.contentView.bounds.minX > 1000)

        for _ in 0..<2 {
            store.prepareToShow()
            #expect(store.selectedID == old.id)
            NotificationCenter.default.post(name: .shelfDidShow, object: nil)
            try await settle(hosting)
            #expect(abs(scroll.contentView.bounds.minX) < 1)
            scroll.contentView.scroll(to: NSPoint(x: 1200, y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await settle(hosting)
        }
    }
}
