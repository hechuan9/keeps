import CryptoKit
import Foundation
import SQLite3

public struct KeepsTimelineEntry: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var date: String
    public var flagState: String
    public var filename: String
    public var browseThumbnail: KeepsPreview?
    public var thumbnail: KeepsPreview?
    public var preview: KeepsPreview?
    public var standard: KeepsPreview?
    public var gridPreview: KeepsPreview? { thumbnail ?? preview }
    public var isVideo: Bool { ["mov", "mp4", "m4v", "avi", "mkv", "mts", "m2ts"].contains(URL(fileURLWithPath: filename).pathExtension.lowercased()) }

    public init(id: UUID, date: String, thumbnail: KeepsPreview?, preview: KeepsPreview?, flagState: String, filename: String, browseThumbnail: KeepsPreview? = nil, standard: KeepsPreview? = nil) {
        self.id = id
        self.date = date
        self.flagState = flagState
        self.filename = filename
        self.browseThumbnail = browseThumbnail
        self.thumbnail = thumbnail
        self.preview = preview
        self.standard = standard
    }
}

/// The local catalog is the browsing source; only a completed stable scan removes stale rows.
public final class KeepsLibraryDatabase {
    // Each owner uses its own connection; this non-Sendable instance never crosses actors.
    private var connection: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    public let fileURL: URL

    public struct DatabaseError: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public init(configuration: KeepsConfiguration, rootDirectory: URL? = nil) throws {
        let root = try rootDirectory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Keeps/Catalogs", isDirectory: true)
        let identity = try JSONEncoder().encode([configuration.baseURL.absoluteString, configuration.libraryID, configuration.accessCredential ?? ""])
        let key = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fileURL = root.appendingPathComponent(key + ".sqlite")
        var opened: OpaquePointer?
        let result = sqlite3_open_v2(fileURL.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard result == SQLITE_OK else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open catalog"
            sqlite3_close(opened)
            throw DatabaseError(message: "SQLite open (\(result)): \(message)")
        }
        connection = opened
        do {
            try execute("PRAGMA foreign_keys=ON")
            try execute("PRAGMA journal_mode=WAL")
            try execute("CREATE TABLE IF NOT EXISTS assets(id TEXT PRIMARY KEY, snapshot TEXT NOT NULL, sort_time TEXT NOT NULL, filename TEXT NOT NULL, camera TEXT NOT NULL, rating INTEGER NOT NULL, flag TEXT NOT NULL, color TEXT, trashed INTEGER NOT NULL)")
            try execute("CREATE INDEX IF NOT EXISTS assets_sort ON assets(trashed,sort_time DESC,id)")
            try execute("CREATE TABLE IF NOT EXISTS paths(asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,path TEXT NOT NULL,PRIMARY KEY(asset_id,path))")
            try execute("CREATE INDEX IF NOT EXISTS paths_path ON paths(path,asset_id)")
            try execute("CREATE TABLE IF NOT EXISTS seen(id TEXT PRIMARY KEY)")
            try execute("CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS hidden(path TEXT PRIMARY KEY)")
            try execute("CREATE TABLE IF NOT EXISTS navigation(path TEXT PRIMARY KEY,snapshot TEXT NOT NULL)")
        } catch {
            sqlite3_close(opened)
            connection = nil
            throw error
        }
    }

    deinit { sqlite3_close(connection) }

    /// SQLite backup includes committed WAL pages without checkpointing the live catalog.
    public func exportSnapshot(to destination: URL) throws {
        guard destination.standardizedFileURL != fileURL.standardizedFileURL else {
            throw DatabaseError(message: "Snapshot destination must differ from the live catalog")
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let target = try Self.openSnapshot(temporary, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        defer { sqlite3_close(target) }
        try transaction(readOnly: true) {
            try Self.validateSnapshot(connection)
            try Self.backup(from: connection, to: target)
        }
        _ = try Self.snapshotStrings(target, "PRAGMA journal_mode=DELETE")
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }

    /// Restore only before local synchronization starts; existing reader connections remain valid.
    public func restoreSnapshot(from source: URL) throws -> Bool {
        guard try strings("SELECT 1 FROM assets LIMIT 1").isEmpty,
              try strings("SELECT 1 FROM metadata WHERE key IN ('revision','sync_checkpoint') LIMIT 1").isEmpty else { return false }
        let origin = try Self.openSnapshot(source, flags: SQLITE_OPEN_READONLY)
        defer { sqlite3_close(origin) }
        _ = try Self.snapshotStrings(origin, "BEGIN DEFERRED")
        // Closing the source releases this read transaction, including on validation failure.
        try Self.validateSnapshot(origin)
        try Self.backup(from: origin, to: connection)
        return true
    }

    public func replaceSnapshot(from source: URL, revision: Int64, assetCount: Int) throws {
        let origin = try Self.openSnapshot(source, flags: SQLITE_OPEN_READONLY)
        defer { sqlite3_close(origin) }
        _ = try Self.snapshotStrings(origin, "BEGIN DEFERRED")
        try Self.validateSnapshot(origin)
        guard try Self.snapshotStrings(origin, "SELECT value FROM metadata WHERE key='revision'").first == String(revision),
              try Self.snapshotStrings(origin, "SELECT COUNT(*) FROM assets").first == String(assetCount) else {
            throw DatabaseError(message: "Offline snapshot manifest does not match catalog")
        }
        try Self.backup(from: origin, to: connection)
    }

    public final class SnapshotReader {
        private let connection: OpaquePointer
        public init(url: URL) throws {
            connection = try KeepsLibraryDatabase.openSnapshot(url, flags: SQLITE_OPEN_READONLY)
            do { try KeepsLibraryDatabase.validateSnapshot(connection) }
            catch { sqlite3_close(connection); throw error }
        }
        deinit { sqlite3_close(connection) }
        public func asset(id: UUID) throws -> KeepsAsset? {
            try KeepsLibraryDatabase.snapshotStrings(connection, "SELECT snapshot FROM assets WHERE id='\(id.uuidString)'").first.map {
                try JSONDecoder().decode(KeepsAsset.self, from: Data($0.utf8))
            }
        }
    }

    private static func openSnapshot(_ url: URL, flags: Int32) throws -> OpaquePointer {
        var db: OpaquePointer?
        let code = sqlite3_open_v2(url.path, &db, flags, nil)
        guard code == SQLITE_OK, let db else {
            let detail = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open snapshot"
            sqlite3_close(db)
            throw DatabaseError(message: "SQLite snapshot open (\(code)): \(detail)")
        }
        return db
    }

    private static func validateSnapshot(_ db: OpaquePointer?) throws {
        guard try snapshotStrings(db, "PRAGMA quick_check") == ["ok"] else {
            throw DatabaseError(message: "SQLite snapshot integrity check failed")
        }
        for query in [
            "SELECT id,snapshot,sort_time,filename,camera,rating,flag,color,trashed FROM assets LIMIT 0",
            "SELECT asset_id,path FROM paths LIMIT 0", "SELECT id FROM seen LIMIT 0",
            "SELECT key,value FROM metadata LIMIT 0", "SELECT path FROM hidden LIMIT 0",
            "SELECT path,snapshot FROM navigation LIMIT 0"
        ] { _ = try snapshotStrings(db, query) }
        guard try snapshotStrings(db, "SELECT value FROM metadata WHERE key='revision'").first.flatMap(Int64.init) != nil,
              try snapshotStrings(db, "SELECT 1 FROM metadata WHERE key='sync_checkpoint'").isEmpty else {
            throw DatabaseError(message: "Catalog snapshot is not a completed stable revision")
        }
    }

    private static func snapshotStrings(_ db: OpaquePointer?, _ sql: String) throws -> [String] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError(message: "SQLite snapshot prepare: \(String(cString: sqlite3_errmsg(db))); SQL: \(sql)")
        }
        var rows: [String] = []
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) { rows.append(String(cString: text)) }
            code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else {
            throw DatabaseError(message: "SQLite snapshot step (\(code)): \(String(cString: sqlite3_errmsg(db))); SQL: \(sql)")
        }
        return rows
    }

    private static func backup(from source: OpaquePointer?, to destination: OpaquePointer?) throws {
        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw DatabaseError(message: "SQLite backup init: \(String(cString: sqlite3_errmsg(destination)))")
        }
        let code = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard code == SQLITE_DONE, finish == SQLITE_OK else {
            throw DatabaseError(message: "SQLite backup (\(code), finish \(finish)): \(String(cString: sqlite3_errmsg(destination)))")
        }
    }

    public var revision: Int64? {
        get throws { try strings("SELECT value FROM metadata WHERE key='revision'").first.flatMap(Int64.init) }
    }

    public struct SyncCheckpoint: Codable, Sendable, Equatable {
        public var revision: Int64
        public var stable: Bool
        public var phase: Int = 0
        public var cursor: String?
        public init(revision: Int64, stable: Bool) {
            self.revision = revision
            self.stable = stable
        }
    }

    public var syncCheckpoint: SyncCheckpoint? {
        get throws {
            try strings("SELECT value FROM metadata WHERE key='sync_checkpoint'").first.map {
                try decoder.decode(SyncCheckpoint.self, from: Data($0.utf8))
            }
        }
    }

    private func saveCheckpoint(_ checkpoint: SyncCheckpoint) throws {
        try execute("INSERT OR REPLACE INTO metadata(key,value) VALUES('sync_checkpoint',?)",
                    [String(decoding: try encoder.encode(checkpoint), as: UTF8.self)])
    }

    public func beginSync(checkpoint: SyncCheckpoint? = nil) throws {
        try transaction {
            try execute("DELETE FROM seen")
            try execute("DELETE FROM metadata WHERE key IN ('revision','sync_checkpoint')")
            if let checkpoint { try saveCheckpoint(checkpoint) }
        }
    }

    public func ingest(_ items: [KeepsAsset], checkpoint: SyncCheckpoint? = nil) throws {
        try transaction {
            for asset in items {
                try save(asset)
                try execute("INSERT OR IGNORE INTO seen(id) VALUES(?)", [asset.id.uuidString])
            }
            if let checkpoint { try saveCheckpoint(checkpoint) }
        }
    }

    public func completeSync(revision: Int64, isStable: Bool) throws {
        try transaction {
            if isStable {
                try execute("DELETE FROM assets WHERE id NOT IN (SELECT id FROM seen)")
                try execute("INSERT OR REPLACE INTO metadata(key,value) VALUES('revision',?)", [String(revision)])
            }
            try execute("DELETE FROM seen")
            try execute("DELETE FROM metadata WHERE key='sync_checkpoint'")
        }
    }

    public func update(_ asset: KeepsAsset) throws { try transaction { try save(asset) } }

    public func replaceHiddenDirectories(_ paths: [String]) throws {
        try transaction {
            try execute("DELETE FROM hidden")
            for path in paths { try execute("INSERT OR IGNORE INTO hidden(path) VALUES(?)", [path]) }
        }
    }

    public func hiddenDirectories() throws -> [String] { try strings("SELECT path FROM hidden ORDER BY path") }

    public func saveNavigation(_ navigation: KeepsNavigation) throws {
        try execute("INSERT OR REPLACE INTO navigation(path,snapshot) VALUES(?,?)", [navigation.path ?? "", String(decoding: try encoder.encode(navigation), as: UTF8.self)])
    }

    public func navigation(path: String? = nil) throws -> KeepsNavigation? {
        try strings("SELECT snapshot FROM navigation WHERE path=?", [path ?? ""]).first.map { try decoder.decode(KeepsNavigation.self, from: Data($0.utf8)) }
    }

    /// All positions are available before scrolling; cursor and page size do not constrain the index.
    public func timeline(query: KeepsAssetQuery) throws -> [KeepsTimelineEntry] {
        let (filter, bindings) = try assetFilter(query)
        let sql = "SELECT id,sort_time,json_extract(snapshot,'$.thumbnail'),json_extract(snapshot,'$.preview'),flag,filename,json_extract(snapshot,'$.browseThumbnail'),json_extract(snapshot,'$.standard') FROM assets a WHERE \(filter) ORDER BY sort_time DESC,id ASC"
        let statement = try statement(sql, bindings)
        defer { sqlite3_finalize(statement) }
        var entries: [KeepsTimelineEntry] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            let idString = String(cString: sqlite3_column_text(statement, 0))
            guard let id = UUID(uuidString: idString) else { throw DatabaseError(message: "Invalid catalog asset ID: \(idString)") }
            func descriptor(_ column: Int32) throws -> KeepsPreview? {
                guard let text = sqlite3_column_text(statement, column) else { return nil }
                return try decoder.decode(KeepsPreview.self, from: Data(String(cString: text).utf8))
            }
            entries.append(KeepsTimelineEntry(id: id, date: String(cString: sqlite3_column_text(statement, 1)),
                                              thumbnail: try descriptor(2), preview: try descriptor(3),
                                              flagState: String(cString: sqlite3_column_text(statement, 4)),
                                              filename: String(cString: sqlite3_column_text(statement, 5)),
                                              browseThumbnail: try descriptor(6), standard: try descriptor(7)))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw failure(sql) }
        return entries
    }

    /// Preserve viewport order while keeping SQLite parameter counts bounded.
    public func assets(ids: [UUID]) throws -> [KeepsAsset] {
        guard !ids.isEmpty else { return [] }
        return try transaction(readOnly: true) {
            var loaded: [UUID: KeepsAsset] = [:]
            for start in stride(from: 0, to: ids.count, by: 500) {
                let batch = ids[start..<min(start + 500, ids.count)]
                let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
                let rows = try strings("SELECT snapshot FROM assets WHERE id IN (\(placeholders))", batch.map { $0.uuidString })
                for row in rows {
                    let asset = try decoder.decode(KeepsAsset.self, from: Data(row.utf8))
                    loaded[asset.id] = asset
                }
            }
            return ids.compactMap { loaded[$0] }
        }
    }

    private func assetFilter(_ query: KeepsAssetQuery) throws -> (String, [String?]) {
        guard query.folderID == nil else { throw DatabaseError(message: "Local catalog does not support folderID; use directory") }
        guard query.sort == "capture_desc" else { throw DatabaseError(message: "Unsupported local catalog sort: \(query.sort)") }
        guard (0...5).contains(query.minRating) else { throw DatabaseError(message: "Invalid local catalog rating") }
        var filter = "a.trashed=?"
        var bindings: [String?] = [query.trashed ? "1" : "0"]
        if query.minRating > 0 {
            filter += " AND a.rating>=?"
            bindings.append(String(query.minRating))
        }
        if !query.q.isEmpty {
            filter += " AND (a.filename LIKE ? ESCAPE '\\' OR a.camera LIKE ? ESCAPE '\\')"
            let pattern = "%" + query.q.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
            bindings += [pattern, pattern]
        }
        for (column, value) in [("flag", query.flagState), ("color", query.colorLabel)] {
            if let value { filter += " AND a.\(column)=?"; bindings.append(value) }
        }
        if let tag = query.tag {
            filter += " AND EXISTS(SELECT 1 FROM json_each(a.snapshot,'$.tags') WHERE value=?)"
            bindings.append(tag)
        }
        if let directory = query.directory {
            let root = directory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let prefix = root.isEmpty ? "/" : "/" + root + "/"
            filter += " AND a.id IN (SELECT asset_id FROM paths WHERE path>=? AND path<?"
            bindings += [prefix, String(prefix.dropLast()) + "0"]
            if !query.recursive {
                filter += " AND instr(substr(path,?),'/')=0"
                bindings.append(String(prefix.unicodeScalars.count + 1))
            }
            filter += ")"
        }
        if !query.showHidden {
            let directory = query.directory.map { $0 == "/" ? "/" : "/" + $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) } ?? ""
            filter += " AND a.id NOT IN (SELECT p.asset_id FROM hidden h JOIN paths p ON p.path>=rtrim(h.path,'/') || '/' AND p.path<rtrim(h.path,'/') || '0' WHERE NOT (?=h.path OR substr(?,1,length(rtrim(h.path,'/'))+1)=rtrim(h.path,'/') || '/'))"
            bindings += [directory, directory]
        }
        return (filter, bindings)
    }

    public func assets(query: KeepsAssetQuery, includingThrough asset: KeepsAsset? = nil, olderThan boundary: KeepsAsset? = nil, newerThan newer: KeepsAsset? = nil, startingAt first: KeepsAsset? = nil, maximumLimit: Int? = nil, knownTotal: Int? = nil) throws -> KeepsAssetPage {
        try transaction(readOnly: true) {
            guard query.limit > 0 else { throw DatabaseError(message: "Invalid local catalog limit") }
            guard let offset = Int(query.cursor ?? "0"), offset >= 0 else { throw DatabaseError(message: "Invalid local catalog cursor") }
            var (filter, bindings) = try assetFilter(query)
            let total = try knownTotal ?? Int(strings("SELECT count(*) FROM assets a WHERE \(filter)", bindings).first!)!
            // The explicit time bound lets SQLite seek assets_sort with bound parameters.
            if let boundary {
                filter += " AND sort_time<=? AND (sort_time<? OR (sort_time=? AND id>?))"
                let time = boundary.captureTime ?? boundary.createdAt
                bindings += [time, time, time, boundary.id.uuidString]
            }
            if let newer {
                filter += " AND sort_time>=? AND (sort_time>? OR (sort_time=? AND id<?))"
                let time = newer.captureTime ?? newer.createdAt
                bindings += [time, time, time, newer.id.uuidString]
            }
            if let first {
                filter += " AND sort_time<=? AND (sort_time<? OR (sort_time=? AND id>=?))"
                let time = first.captureTime ?? first.createdAt
                bindings += [time, time, time, first.id.uuidString]
            }
            var limit = query.limit
            if let asset {
                // 新记录加入时保留已浏览范围，避免固定条数窗口挤掉上方旧行。
                let time = asset.captureTime ?? asset.createdAt
                let count = Int(try strings("SELECT count(*) FROM assets a WHERE \(filter) AND (sort_time>? OR (sort_time=? AND id<=?))",
                    bindings + [time, time, asset.id.uuidString]).first!)!
                limit = max(limit, count - offset)
            }
            if let maximumLimit { limit = min(limit, maximumLimit) }
            let order = newer == nil ? "sort_time DESC,id ASC" : "sort_time ASC,id DESC"
            let rows = try strings("SELECT snapshot FROM assets a WHERE \(filter) ORDER BY \(order) LIMIT ? OFFSET ?", bindings + [String(limit + 1), String(offset)])
            let hasMore = rows.count > limit
            var items = try rows.prefix(limit).map { try decoder.decode(KeepsAsset.self, from: Data($0.utf8)) }
            if newer != nil { items.reverse() }
            let stableRevision = try revision
            return KeepsAssetPage(items: items, total: total, nextCursor: hasMore ? String(offset + items.count) : nil, revision: stableRevision ?? 0, isUpdating: stableRevision == nil)
        }
    }

    private func save(_ asset: KeepsAsset) throws {
        let snapshot = String(decoding: try encoder.encode(asset), as: UTF8.self)
        try execute("INSERT INTO assets(id,snapshot,sort_time,filename,camera,rating,flag,color,trashed) VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET snapshot=excluded.snapshot,sort_time=excluded.sort_time,filename=excluded.filename,camera=excluded.camera,rating=excluded.rating,flag=excluded.flag,color=excluded.color,trashed=excluded.trashed", [asset.id.uuidString, snapshot, asset.captureTime ?? asset.createdAt, asset.originalFilename, asset.cameraModel, String(asset.rating), asset.flagState, asset.colorLabel, asset.trashed ? "1" : "0"])
        try execute("DELETE FROM paths WHERE asset_id=?", [asset.id.uuidString])
        for path in asset.paths ?? [] { try execute("INSERT OR IGNORE INTO paths(asset_id,path) VALUES(?,?)", [asset.id.uuidString, path]) }
    }

    private func transaction<T>(readOnly: Bool = false, _ body: () throws -> T) throws -> T {
        try execute(readOnly ? "BEGIN DEFERRED" : "BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        }
        catch {
            do { try execute("ROLLBACK") }
            catch let rollback { throw DatabaseError(message: "\(error); rollback failed: \(rollback)") }
            throw error
        }
    }

    private func statement(_ sql: String, _ values: [String?]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure(sql) }
        for (index, value) in values.enumerated() {
            let result = value.map { value in value.withCString { sqlite3_bind_text(statement, Int32(index + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) } } ?? sqlite3_bind_null(statement, Int32(index + 1))
            guard result == SQLITE_OK else { sqlite3_finalize(statement); throw failure(sql) }
        }
        return statement
    }

    private func execute(_ sql: String, _ values: [String?] = []) throws {
        let statement = try statement(sql, values)
        defer { sqlite3_finalize(statement) }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW { result = sqlite3_step(statement) }
        guard result == SQLITE_DONE else { throw failure(sql) }
    }

    private func strings(_ sql: String, _ values: [String?] = []) throws -> [String] {
        let statement = try statement(sql, values)
        defer { sqlite3_finalize(statement) }
        var rows: [String] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            rows.append(String(cString: sqlite3_column_text(statement, 0)))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw failure(sql) }
        return rows
    }

    private func failure(_ sql: String) -> DatabaseError {
        DatabaseError(message: "SQLite (\(sqlite3_extended_errcode(connection))): \(String(cString: sqlite3_errmsg(connection))); SQL: \(sql)")
    }
}
