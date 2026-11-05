import AppKit
import ClipboardCore
import Testing
import UniformTypeIdentifiers
@testable import ClipShelf

@Suite @MainActor struct DragDropAndSizeTests {
    private func withRecord(_ action: (ClipboardDatabase, String, String, String) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try ClipboardDatabase(url: directory.appendingPathComponent("history.sqlite"))
        let source = try database.addCollection(name: "来源")
        let target = try database.addCollection(name: "目标")
        let id = try database.save(ClipDraft(kind: .text, title: "中文片段", text: "中文片段", sourceName: "Test", sourceBundle: "test.app",
            payload: ClipPayload(items: [[ClipRepresentation(type: "public.utf8-plain-text", data: Data("中文片段".utf8)),
                ClipRepresentation(type: "public.html", data: Data("<b>中文片段</b>".utf8))]])))
        try database.assign(source, to: id)
        try action(database, id, source, target)
    }
    @Test func movingBetweenGroupsPreservesPayloadFavoriteAndHistory() throws {
        try withRecord { database, id, source, target in
            let payload = try database.payload(for: id)
            try database.setFavorite(true, id: id)
            let operation = try #require(ClipGroupDropOperation.resolve(target: target, collections: database.collections()))
            try operation.apply(recordID: id, database: database)
            let records = try database.records()
            #expect(records.count == 1)
            #expect(records[0].collectionID == target)
            #expect(records[0].favorite)
            #expect(!ShelfGroupNavigation.matches(records[0], group: source))
            #expect(try database.payload(for: id) == payload)
        }
    }
    @Test func favoriteDropIsIdempotentAndAllDropRemovesOnlyGroupMembership() throws {
        try withRecord { database, id, source, _ in
            let favorite = try #require(ClipGroupDropOperation.resolve(target: "favorites", collections: []))
            try favorite.apply(recordID: id, database: database)
            try favorite.apply(recordID: id, database: database)
            var record = try #require(database.records().first)
            #expect(record.favorite)
            #expect(record.collectionID == source)
            let all = try #require(ClipGroupDropOperation.resolve(target: "all", collections: []))
            try all.apply(recordID: id, database: database)
            record = try #require(database.records().first)
            #expect(record.collectionID == nil)
            #expect(record.favorite)
            #expect(try database.records().count == 1)
        }
    }
    @Test func missingOrDeletedDropTargetDoesNotMoveTheRecord() throws {
        try withRecord { database, id, source, target in
            #expect(try ClipGroupDropOperation.resolve(target: "missing", collections: database.collections()) == nil)
            try database.deleteCollection(id: target)
            #expect(throws: DatabaseError.self) { try ClipGroupDropOperation.move(target).apply(recordID: id, database: database) }
            #expect(try database.records().first?.collectionID == source)
        }
    }
    @Test func dragProviderContainsOnlyAnInternalRecordIdentifier() async throws {
        let id = UUID().uuidString
        let provider = ClipDragItem.provider(recordID: id)
        #expect(provider.registeredTypeIdentifiers == [UTType.clipShelfRecord.identifier])
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.clipShelfRecord.identifier) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? NSError(domain: "ClipShelfTests", code: 1)) }
            }
        }
        #expect(String(data: data, encoding: .utf8) == id)
    }
    @Test func largerSizesIncreaseCardsFontsAndPanelWhileFittingTheScreen() {
        #expect(ShelfDisplaySize.standard.cardWidth > ShelfDisplaySize.small.cardWidth)
        #expect(ShelfDisplaySize.standard.cardHeight > ShelfDisplaySize.small.cardHeight)
        #expect(ShelfDisplaySize.standard.bodyFontSize > ShelfDisplaySize.small.bodyFontSize)
        #expect(ShelfDisplaySize.large.cardWidth > ShelfDisplaySize.standard.cardWidth)
        let screen = NSRect(x: -1000, y: -800, width: 1000, height: 800)
        let visible = NSRect(x: -1000, y: -800, width: 1000, height: 780)
        let normal = ShelfPresentation.frame(screen: screen, visible: visible, size: .small)
        let larger = ShelfPresentation.frame(screen: screen, visible: visible)
        #expect(larger.height > normal.height)
        #expect(larger.minY == screen.minY)
        let short = ShelfPresentation.frame(screen: screen, visible: NSRect(x: -1000, y: -800, width: 1000, height: 300), size: .large)
        #expect(short.height == 280)
    }
    @Test func sizePreferenceDefaultsToStandardAndSurvivesReload() throws {
        let suite = "io.clipshelf.size-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(ShelfDisplaySize.load(from: defaults) == .standard)
        #expect(ShelfDisplaySize.allCases.map(\.title) == ["较小", "标准", "较大"])
        for (legacyValue, expected) in [("standard", ShelfDisplaySize.small), ("large", .standard), ("extraLarge", .large)] {
            defaults.set(legacyValue, forKey: "displaySize")
            #expect(ShelfDisplaySize.load(from: defaults) == expected)
        }
        defaults.set(ShelfDisplaySize.large.rawValue, forKey: "displaySize")
        #expect(ShelfDisplaySize.load(from: defaults) == .large)
        defaults.set("invalid", forKey: "displaySize")
        #expect(ShelfDisplaySize.load(from: defaults) == .standard)
    }
}
