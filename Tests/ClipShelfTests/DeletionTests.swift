import AppKit
import ClipboardCore
import Testing
@testable import ClipShelf

@Suite @MainActor struct DeletionTests {
    private func withStore(_ body: (ClipboardStore) throws -> Void) throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        // All deletion tests use disposable data and never monitor the clipboard.
        let store = try ClipboardStore(dataDirectory: directory, monitorsClipboard: false)
        for (index, text) in ["one", "two", "three", "four"].enumerated() {
            try store.database.save(ClipDraft(kind: .text, title: text, text: text,
                sourceName: "Test", sourceBundle: "test.app",
                payload: ClipPayload(items: [[ClipRepresentation(type: "public.utf8-plain-text", data: Data(text.utf8))]])),
                now: Date().addingTimeInterval(Double(-index)))
        }
        try store.reload()
        try body(store)
    }

    @Test func deletingMiddleSelectsRightNeighborAndKeepsDatabaseInSync() throws {
        try withStore { store in
            let records = store.visibleRecords
            store.selectedID = records[1].id
            store.delete(records[1])
            #expect(store.selectedID == records[2].id)
            #expect(store.selectionOrigin == .deletion)
            #expect(store.visibleRecords.map(\.id) == [records[0].id, records[2].id, records[3].id])
            let persisted = try store.database.records()
            #expect(persisted.map(\.id) == store.records.map(\.id))
            #expect(throws: DatabaseError.self) { try store.database.payload(for: records[1].id) }
            store.moveSelection(-1)
            #expect(store.selectedID == records[0].id)
            #expect(store.selectionOrigin == .navigation)
        }
    }

    @Test func deletingLastSelectsLeftNeighborAndRepeatedDeletesEndWithNoSelection() throws {
        try withStore { store in
            let records = store.visibleRecords
            store.selectedID = records.last?.id
            for index in (0..<records.count).reversed() {
                store.delete(records[index])
                #expect(store.selectedID == (index > 0 ? records[index - 1].id : nil))
            }
            #expect(store.visibleRecords.isEmpty)
            let persisted = try store.database.records()
            #expect(persisted.isEmpty)
        }
    }

    @Test func deletingFirstSelectsItsImmediateNeighbor() throws {
        try withStore { store in
            let records = store.visibleRecords
            store.selectedID = records[0].id
            store.delete(records[0])
            #expect(store.selectedID == records[1].id)
        }
    }

    @Test func deletingAnotherCardKeepsCurrentSelection() throws {
        try withStore { store in
            let records = store.visibleRecords
            store.selectedID = records[2].id
            store.delete(records[1])
            #expect(store.selectedID == records[2].id)
            #expect(store.selectionOrigin == .navigation)
        }
    }

    @Test func deletionUsesNeighborsWithinTheCurrentGroupAndSearch() throws {
        try withStore { store in
            let records = store.visibleRecords
            let group = try store.database.addCollection(name: "test")
            for index in [0, 2, 3] { try store.database.assign(group, to: records[index].id) }
            try store.reload()
            store.filter = group
            store.query = "o" // one and four; two is outside this group, three does not match.
            #expect(store.visibleRecords.map(\.id) == [records[0].id, records[3].id])
            store.selectedID = records[0].id
            store.delete(records[0])
            #expect(store.selectedID == records[3].id)
            store.delete(records[3])
            #expect(store.selectedID == nil)
            #expect(store.records.count == 2)
            #expect(store.query == "o")
            #expect(store.filter == group)
        }
    }

    @Test func mouseSelectionStaysPutWhileKeyboardAndDeletionKeepTheirScrollBehavior() throws {
        try withStore { store in
            let records = store.visibleRecords
            store.selectCard(records[1])
            #expect(store.selectedID == records[1].id)
            #expect(store.selectionOrigin == .pointer)
            store.moveSelection(1)
            #expect(store.selectedID == records[2].id)
            #expect(store.selectionOrigin == .navigation)
            store.delete(records[2])
            #expect(store.selectedID == records[3].id)
            #expect(store.selectionOrigin == .deletion)
            store.selectCard(records[0])
            #expect(store.selectedID == records[0].id)
            #expect(store.selectionOrigin == .pointer)
        }
    }
}
