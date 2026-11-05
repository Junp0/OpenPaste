import Foundation
import CSQLite

public enum DatabaseError: LocalizedError {
    case sqlite(String), missingItem
    public var errorDescription: String? {
        switch self { case .sqlite(let message): return "本地数据库：\(message)"; case .missingItem: return "这条记录已被删除。" }
    }
}

public final class ClipboardDatabase {
    private var connection: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"
            if let connection { sqlite3_close(connection) }; connection = nil
            throw DatabaseError.sqlite(message)
        }
        do {
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA secure_delete = ON")
            sqlite3_busy_timeout(connection, 3000)
            try execute("""
                CREATE TABLE IF NOT EXISTS collections (id TEXT PRIMARY KEY, name TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS clips (
                    id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL UNIQUE,
                    kind TEXT NOT NULL, title TEXT NOT NULL, text TEXT NOT NULL,
                    source_name TEXT NOT NULL, source_bundle TEXT NOT NULL,
                    created_at REAL NOT NULL, updated_at REAL NOT NULL,
                    thumbnail BLOB, byte_count INTEGER NOT NULL, payload BLOB NOT NULL,
                    favorite INTEGER NOT NULL DEFAULT 0,
                    collection_id TEXT REFERENCES collections(id) ON DELETE SET NULL
                );
                CREATE INDEX IF NOT EXISTS clips_updated ON clips(updated_at DESC);
                """)
            try migrateCollectionIcons()
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            sqlite3_close(connection); connection = nil; throw error
        }
    }
    deinit { if let connection { sqlite3_close(connection) } }

    private func migrateCollectionIcons() throws {
        let hasIcon: Bool = try {
            let statement = try prepare("PRAGMA table_info(collections)")
            defer { sqlite3_finalize(statement) }
            var step = sqlite3_step(statement)
            var found = false
            while step == SQLITE_ROW {
                if string(statement, 1) == "icon" { found = true }
                step = sqlite3_step(statement)
            }
            guard step == SQLITE_DONE else { throw error() }
            return found
        }()
        if !hasIcon {
            try execute("ALTER TABLE collections ADD COLUMN icon TEXT NOT NULL DEFAULT 'pin.fill'")
        }
        try execute("PRAGMA user_version = 2")
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error() }
        return statement
    }
    private func error() -> DatabaseError {
        .sqlite(connection.map { String(cString: sqlite3_errmsg($0)) } ?? "连接已关闭")
    }
    private func bind(_ value: String?, at index: Int32, to statement: OpaquePointer) {
        if let value { sqlite3_bind_text(statement, index, value, Int32(value.utf8.count), transient) }
        else { sqlite3_bind_null(statement, index) }
    }
    private func bind(_ value: Data?, at index: Int32, to statement: OpaquePointer) {
        if let value {
            _ = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(value.count), transient) }
        } else { sqlite3_bind_null(statement, index) }
    }
    private func complete(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }
    private func string(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: value, count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self)
    }
    private func blob(_ statement: OpaquePointer, _ column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }

    @discardableResult public func save(_ draft: ClipDraft, now: Date = Date()) throws -> String {
        let encoded = try JSONEncoder().encode(draft.payload)
        let proposedID = UUID().uuidString
        let statement = try prepare("""
            INSERT INTO clips (id, fingerprint, kind, title, text, source_name, source_bundle, created_at, updated_at, thumbnail, byte_count, payload)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(fingerprint) DO UPDATE SET updated_at = excluded.updated_at,
                source_name = excluded.source_name, source_bundle = excluded.source_bundle
            RETURNING id
            """)
        defer { sqlite3_finalize(statement) }
        for (index, value) in [proposedID, draft.payload.fingerprint, draft.kind.rawValue, draft.title, draft.text, draft.sourceName, draft.sourceBundle].enumerated() {
            bind(value, at: Int32(index + 1), to: statement)
        }
        sqlite3_bind_double(statement, 8, now.timeIntervalSince1970)
        sqlite3_bind_double(statement, 9, now.timeIntervalSince1970)
        bind(draft.thumbnail, at: 10, to: statement)
        sqlite3_bind_int64(statement, 11, Int64(draft.payload.items.flatMap { $0 }.reduce(0) { $0 + $1.data.count }))
        bind(encoded, at: 12, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw error() }
        let id = string(statement, 0)
        try complete(statement)
        return id
    }

    public func records() throws -> [ClipRecord] {
        let statement = try prepare("SELECT id, kind, title, text, source_name, source_bundle, created_at, updated_at, thumbnail, byte_count, favorite, collection_id FROM clips ORDER BY updated_at DESC, id DESC")
        defer { sqlite3_finalize(statement) }
        var records: [ClipRecord] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            records.append(ClipRecord(id: string(statement, 0), kind: ClipKind(rawValue: string(statement, 1)) ?? .text,
                title: string(statement, 2), text: string(statement, 3), sourceName: string(statement, 4), sourceBundle: string(statement, 5),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)), thumbnail: blob(statement, 8),
                byteCount: Int(sqlite3_column_int64(statement, 9)), favorite: sqlite3_column_int(statement, 10) == 1,
                collectionID: sqlite3_column_type(statement, 11) == SQLITE_NULL ? nil : string(statement, 11)))
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw error() }
        return records
    }

    public func payload(for id: String) throws -> ClipPayload {
        let statement = try prepare("SELECT payload FROM clips WHERE id = ?")
        defer { sqlite3_finalize(statement) }; bind(id, at: 1, to: statement)
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { throw DatabaseError.missingItem }
        guard step == SQLITE_ROW else { throw error() }
        guard let data = blob(statement, 0) else { throw DatabaseError.missingItem }
        return try JSONDecoder().decode(ClipPayload.self, from: data)
    }

    public func setFavorite(_ favorite: Bool, id: String) throws {
        let statement = try prepare("UPDATE clips SET favorite = ? WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, favorite ? 1 : 0); bind(id, at: 2, to: statement); try complete(statement)
    }
    public func markUsed(id: String, now: Date = Date()) throws {
        let statement = try prepare("UPDATE clips SET updated_at = ? WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, now.timeIntervalSince1970)
        bind(id, at: 2, to: statement)
        try complete(statement)
        guard sqlite3_changes(connection) == 1 else { throw DatabaseError.missingItem }
    }
    public func assign(_ collectionID: String?, to id: String) throws {
        let statement = try prepare("UPDATE clips SET collection_id = ? WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        bind(collectionID, at: 1, to: statement); bind(id, at: 2, to: statement); try complete(statement)
    }
    public func delete(id: String) throws {
        let statement = try prepare("DELETE FROM clips WHERE id = ?")
        defer { sqlite3_finalize(statement) }; bind(id, at: 1, to: statement); try complete(statement)
    }
    public func clearHistory() throws {
        try execute("DELETE FROM clips WHERE favorite = 0 AND collection_id IS NULL")
        try execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }
    public func prune(retentionDays: Int, limit: Int = 1000, now: Date = Date()) throws {
        // Saved items survive both age and count limits.
        if retentionDays > 0 {
            let statement = try prepare("DELETE FROM clips WHERE favorite = 0 AND collection_id IS NULL AND updated_at < ?")
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, now.addingTimeInterval(-Double(retentionDays) * 86400).timeIntervalSince1970)
            try complete(statement)
        }
        let statement = try prepare("DELETE FROM clips WHERE id IN (SELECT id FROM clips WHERE favorite = 0 AND collection_id IS NULL ORDER BY updated_at DESC LIMIT -1 OFFSET ?)")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(max(0, limit))); try complete(statement)
    }
    public func collections() throws -> [ClipCollection] {
        let statement = try prepare("SELECT id, name, icon FROM collections ORDER BY rowid")
        defer { sqlite3_finalize(statement) }
        var result: [ClipCollection] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            result.append(ClipCollection(id: string(statement, 0), name: string(statement, 1), icon: string(statement, 2)))
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw error() }
        return result
    }
    @discardableResult public func addCollection(name: String, icon: String = ClipCollection.defaultIcon) throws -> String {
        let id = UUID().uuidString
        let statement = try prepare("INSERT INTO collections (id, name, icon) VALUES (?, ?, ?)")
        defer { sqlite3_finalize(statement) }
        bind(id, at: 1, to: statement); bind(name, at: 2, to: statement)
        bind(icon, at: 3, to: statement); try complete(statement); return id
    }
    public func deleteCollection(id: String) throws {
        let statement = try prepare("DELETE FROM collections WHERE id = ?")
        defer { sqlite3_finalize(statement) }; bind(id, at: 1, to: statement); try complete(statement)
    }
}
