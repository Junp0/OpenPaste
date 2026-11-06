import Testing
import Foundation
import CSQLite
@testable import ClipboardCore

@Suite final class DatabaseTests {
    private var directory: URL!
    private var database: ClipboardDatabase!
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        database = try ClipboardDatabase(url: directory.appendingPathComponent("test.sqlite"))
    }
    deinit {
        database = nil
        try? FileManager.default.removeItem(at: directory)
    }
    private func draft(_ text: String) -> ClipDraft {
        ClipDraft(kind: .text, title: text, text: text, sourceName: "Test", sourceBundle: "test.app",
            payload: ClipPayload(items: [[ClipRepresentation(type: "public.utf8-plain-text", data: Data(text.utf8)),
                ClipRepresentation(type: "public.rtf", data: Data("{\\rtf1 \(text)}".utf8))]]))
    }
    @Test func testRoundTripPersistsAllFormatsAndMetadata() throws {
        let original = draft("中文内容 ✨\nsecond\0line")
        let id = try database.save(original)
        let collection = try database.addCollection(name: "工作", icon: "briefcase.fill")
        try database.assign(collection, to: id)
        try database.setFavorite(true, id: id)
        database = nil
        database = try ClipboardDatabase(url: directory.appendingPathComponent("test.sqlite"))
        let record = try #require(database.records().first)
        #expect(record.text == original.text)
        #expect(record.collectionID == collection)
        #expect(record.favorite)
        #expect(try database.payload(for: id) == original.payload)
        #expect(try database.collections().first?.name == "工作")
        #expect(try database.collections().first?.icon == "briefcase.fill")
    }
    @Test func testLegacyCollectionsKeepNamesAndGainDefaultIcons() throws {
        let url = directory.appendingPathComponent("legacy.sqlite")
        var connection: OpaquePointer?
        #expect(sqlite3_open(url.path, &connection) == SQLITE_OK)
        #expect(sqlite3_exec(connection, """
            CREATE TABLE collections (id TEXT PRIMARY KEY, name TEXT NOT NULL);
            INSERT INTO collections VALUES ('work', '工作'), ('ideas', '灵感');
            PRAGMA user_version = 1;
            """, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(connection)
        var migrated: ClipboardDatabase? = try ClipboardDatabase(url: url)
        #expect(try migrated?.collections() == [ClipCollection(id: "work", name: "工作"), ClipCollection(id: "ideas", name: "灵感")])
        let id = try #require(migrated).addCollection(name: "阅读", icon: "book.fill")
        migrated = nil
        migrated = try ClipboardDatabase(url: url)
        #expect(try migrated?.collections().last == ClipCollection(id: id, name: "阅读", icon: "book.fill"))
    }
    @Test func testDuplicateMovesToTopWithoutLosingSavedState() throws {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let id = try database.save(draft("same"), now: start)
        let group = try database.addCollection(name: "分组")
        try database.setFavorite(true, id: id); try database.assign(group, to: id)
        try database.save(draft("other"), now: start.addingTimeInterval(10))
        let repeatedID = try database.save(draft("same"), now: start.addingTimeInterval(20))
        let records = try database.records()
        #expect(repeatedID == id)
        #expect(records.count == 2)
        #expect(records.first?.id == id)
        #expect(records.first?.createdAt == start)
        #expect(records.first?.favorite == true)
        #expect(records.first?.collectionID == group)
    }
    @Test func testRetentionAndCountLimitsPreserveSavedItems() throws {
        let now = Date()
        let old = now.addingTimeInterval(-90 * 86400)
        let favorite = try database.save(draft("favorite"), now: old)
        let grouped = try database.save(draft("grouped"), now: old)
        let expired = try database.save(draft("expired"), now: old)
        try database.setFavorite(true, id: favorite)
        let group = try database.addCollection(name: "keep")
        try database.assign(group, to: grouped)
        for i in 0..<5 { try database.save(draft("recent\(i)"), now: now.addingTimeInterval(Double(i))) }
        try database.prune(retentionDays: 30, limit: 2, now: now)
        let records = try database.records()
        #expect(records.count == 4)
        #expect(!(records.contains { $0.id == expired }))
        #expect(Set(records.filter { !$0.favorite && $0.collectionID == nil }.map(\.text)) == ["recent3", "recent4"])
        try database.clearHistory()
        #expect(Set(try database.records().map(\.id)) == [favorite, grouped])
    }
    @Test func testDeletingCollectionPreservesItsContent() throws {
        let id = try database.save(draft("keep me"))
        let group = try database.addCollection(name: "temporary")
        try database.assign(group, to: id)
        try database.deleteCollection(id: group)
        #expect(try database.records().count == 1)
        #expect(try database.records().first?.collectionID == nil)
        try database.delete(id: id)
        #expect(throws: DatabaseError.self) { try database.payload(for: id) }
    }
    @Test func testFingerprintAccountsForFormatsAndItemBoundaries() {
        let a = ClipRepresentation(type: "a", data: Data("bc".utf8))
        let b = ClipRepresentation(type: "ab", data: Data("c".utf8))
        #expect(ClipPayload(items: [[a]]).fingerprint != ClipPayload(items: [[b]]).fingerprint)
        #expect(ClipPayload(items: [[a], [b]]).fingerprint != ClipPayload(items: [[a, b]]).fingerprint)
        #expect(ClipPayload(items: [[a, b]]).fingerprint == ClipPayload(items: [[b, a]]).fingerprint)
    }
    @Test func testUsingAnOldRecordPromotesItAndPreservesDataAcrossReopening() throws {
        let created = Date(timeIntervalSince1970: 1_000_000)
        let used = created.addingTimeInterval(100)
        let original = draft("旧记录")
        let id = try database.save(original, now: created)
        let group = try database.addCollection(name: "工作")
        try database.assign(group, to: id)
        try database.setFavorite(true, id: id)
        try database.save(draft("新记录"), now: created.addingTimeInterval(50))
        try database.markUsed(id: id, now: used)
        database = nil
        database = try ClipboardDatabase(url: directory.appendingPathComponent("test.sqlite"))
        let records = try database.records()
        let record = try #require(records.first)
        #expect(records.count == 2)
        #expect(record.id == id)
        #expect(record.updatedAt == used)
        #expect(record.createdAt == created)
        #expect(record.sourceName == original.sourceName)
        #expect(record.sourceBundle == original.sourceBundle)
        #expect(record.text == original.text)
        #expect(record.title == original.title)
        #expect(record.favorite)
        #expect(record.collectionID == group)
        #expect(try database.payload(for: id) == original.payload)
    }
    @Test func testUsingADeletedRecordDoesNotRecreateIt() throws {
        let id = try database.save(draft("已删除"))
        try database.delete(id: id)
        #expect(throws: DatabaseError.self) { try database.markUsed(id: id) }
        #expect(try database.records().isEmpty)
    }

    @Test func testMetadataLoadingSkipsThumbnailBlobsWithoutChangingStoredContent() throws {
        let thumbnail = Data(repeating: 42, count: 128 * 1024)
        var original = draft("image")
        original.kind = .image
        original.thumbnail = thumbnail
        let id = try database.save(original)
        let metadata = try #require(database.records(includeThumbnails: false).first)
        #expect(metadata.id == id)
        #expect(metadata.thumbnail == nil)
        #expect(metadata.text == original.text)
        #expect(try database.thumbnail(for: id) == thumbnail)
        #expect(try database.records().first?.thumbnail == thumbnail)
        #expect(try database.payload(for: id) == original.payload)
        let textID = try database.save(draft("no thumbnail"))
        #expect(try database.thumbnail(for: textID) == nil)
        try database.delete(id: id)
        #expect(throws: DatabaseError.self) { try database.thumbnail(for: id) }
    }
}
