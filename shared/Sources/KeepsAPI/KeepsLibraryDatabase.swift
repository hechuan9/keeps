import CryptoKit
import Foundation
import SQLite3
import Darwin

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

/// Browsing uses the local NAS projection; data and its synchronization cursor commit together.
public final class KeepsLibraryDatabase {
    // Each owner uses its own connection; this non-Sendable instance never crosses actors.
    private final class Connection {
        var pointer: OpaquePointer?
        var fileURL: URL?
    }
    private final class Connections: @unchecked Sendable {
        let lock = NSRecursiveLock()
        var live: [Connection] = []
    }
    private static let connections = Connections()
    private let handle = Connection()
    private var connection: OpaquePointer? {
        get { handle.pointer }
        set { handle.pointer = newValue }
    }
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    public let fileURL: URL

    public struct DatabaseError: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public init(configuration: KeepsConfiguration, rootDirectory: URL? = nil) throws {
        Self.connections.lock.lock()
        defer { Self.connections.lock.unlock() }
        let root = try rootDirectory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Keeps/Catalogs", isDirectory: true)
        let identity = try JSONEncoder().encode([configuration.baseURL.absoluteString, configuration.libraryID, configuration.accessCredential ?? ""])
        let key = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fileURL = root.appendingPathComponent(key + ".sqlite")
        if !FileManager.default.fileExists(atPath: fileURL.path), FileManager.default.fileExists(atPath: fileURL.appendingPathExtension("replica").path) {
            try FileManager.default.removeItem(at: fileURL.appendingPathExtension("replica"))
        }
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
            try execute("PRAGMA journal_size_limit=0")
            sqlite3_busy_timeout(connection, 5000)
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
        handle.fileURL = fileURL
        Self.connections.live.append(handle)
    }

    /// Read an immutable snapshot without copying it into another writable catalog.
    init(snapshotURL: URL) throws {
        fileURL = snapshotURL
        let opened = try Self.openSnapshot(snapshotURL, flags: SQLITE_OPEN_READONLY)
        connection = opened
        do { try Self.validateSnapshot(opened) }
        catch {
            sqlite3_close(opened)
            connection = nil
            throw error
        }
    }

    deinit {
        Self.connections.lock.lock()
        sqlite3_close(connection)
        Self.connections.live.removeAll { $0 === handle }
        Self.connections.lock.unlock()
    }

    /// SQLite backup includes committed WAL pages without checkpointing the live catalog.
    public func exportSnapshot(to destination: URL) throws {
        Self.connections.lock.lock()
        defer { Self.connections.lock.unlock() }
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
        Self.connections.lock.lock()
        defer { Self.connections.lock.unlock() }
        guard try strings("SELECT 1 FROM assets LIMIT 1").isEmpty,
              try strings("SELECT 1 FROM metadata WHERE key IN ('revision','sync_checkpoint') LIMIT 1").isEmpty else { return false }
        let origin = try Self.openSnapshot(source, flags: SQLITE_OPEN_READONLY)
        defer { sqlite3_close(origin) }
        _ = try Self.snapshotStrings(origin, "BEGIN DEFERRED")
        // Closing the source releases this read transaction, including on validation failure.
        try Self.validateSnapshot(origin)
        try installSnapshot(from: origin)
        return true
    }

    public func replaceSnapshot(from source: URL, revision: Int64, assetCount: Int, consumingSource: Bool = false) throws {
        Self.connections.lock.lock()
        defer { Self.connections.lock.unlock() }
        var origin: OpaquePointer? = try Self.openSnapshot(source, flags: SQLITE_OPEN_READONLY)
        defer { sqlite3_close(origin) }
        _ = try Self.snapshotStrings(origin, "BEGIN DEFERRED")
        try Self.validateSnapshot(origin)
        guard try Self.snapshotStrings(origin, "SELECT value FROM metadata WHERE key='revision'").first == String(revision),
              try Self.snapshotStrings(origin, "SELECT COUNT(*) FROM assets").first == String(assetCount) else {
            throw DatabaseError(message: "Offline snapshot manifest does not match catalog")
        }
        guard source.standardizedFileURL != fileURL.standardizedFileURL else { throw DatabaseError(message: "Snapshot source must differ from live catalog") }
        if consumingSource {
            guard !FileManager.default.fileExists(atPath: source.path + "-wal") else { throw DatabaseError(message: "Snapshot still has a WAL") }
            guard sqlite3_close(origin) == SQLITE_OK else { throw DatabaseError(message: "Cannot close validated snapshot") }
            origin = nil
            try installCatalog(source)
        } else {
            try installSnapshot(from: origin!)
        }
    }

    // Every live owner is paused and reopened together; no reader retains an old inode.
    private func installSnapshot(from origin: OpaquePointer) throws {
        let staged = fileURL.appendingPathExtension("installing")
        defer { try? FileManager.default.removeItem(at: staged) }
        let target = try Self.openSnapshot(staged, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        do {
            try Self.backup(from: origin, to: target)
            _ = try Self.snapshotStrings(target, "PRAGMA journal_mode=DELETE")
        } catch { sqlite3_close(target); throw error }
        sqlite3_close(target)
        try installCatalog(staged)
    }

    private func installCatalog(_ staged: URL) throws {
        let file = try FileHandle(forWritingTo: staged)
        try file.synchronize()
        try file.close()
        let owners = Self.connections.live.filter { $0.fileURL == fileURL }
        try checkpoint()
        var closeError: Error?
        for owner in owners {
            let code = sqlite3_close(owner.pointer)
            if code == SQLITE_OK { owner.pointer = nil }
            else {
                closeError = DatabaseError(message: "Close before replacement (\(code)): \(String(cString: sqlite3_errmsg(owner.pointer)))")
                break
            }
        }
        let result = closeError == nil ? rename(staged.path, fileURL.path) : -1
        let renameError = errno
        var reopenError: Error?
        for owner in owners where owner.pointer == nil {
            do {
                owner.pointer = try Self.openSnapshot(fileURL, flags: SQLITE_OPEN_READWRITE)
                sqlite3_busy_timeout(owner.pointer, 5000)
                _ = try Self.snapshotStrings(owner.pointer, "PRAGMA foreign_keys=ON")
                _ = try Self.snapshotStrings(owner.pointer, "PRAGMA journal_mode=WAL")
                _ = try Self.snapshotStrings(owner.pointer, "PRAGMA journal_size_limit=0")
            } catch { reopenError = reopenError ?? error }
        }
        if let closeError { throw closeError }
        if result != 0 { throw DatabaseError(message: "Catalog replacement failed: \(String(cString: strerror(renameError)))") }
        if let reopenError { throw reopenError }
    }

    public func checkpoint() throws {
        Self.connections.lock.lock()
        defer { Self.connections.lock.unlock() }
        let code = sqlite3_wal_checkpoint_v2(connection, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        guard code == SQLITE_OK else { throw failure("WAL checkpoint (\(code))") }
    }

    public var generation: String? {
        get throws { try strings("SELECT value FROM metadata WHERE key='generation'").first }
    }

    // The registration lives outside exported databases and is excluded from device backups.
    public func replicaID() throws -> String {
        Self.connections.lock.lock()
        defer { Self.connections.lock.unlock() }
        var file = fileURL.appendingPathExtension("replica")
        if FileManager.default.fileExists(atPath: file.path) {
            let value = try String(contentsOf: file, encoding: .utf8)
            guard UUID(uuidString: value) != nil else { throw DatabaseError(message: "Invalid replica identity") }
            return value
        }
        let value = UUID().uuidString
        try Data(value.utf8).write(to: file, options: .atomic)
        var attributes = URLResourceValues()
        attributes.isExcludedFromBackup = true
        try file.setResourceValues(attributes)
        return value
    }

    public func applyDelta(from source: URL, generation: String, fromRevision: Int64, revision: Int64, assetCount: Int) throws {
        Self.connections.lock.lock()
        defer { Self.connections.lock.unlock() }
        guard UUID(uuidString: generation) != nil, revision >= fromRevision else {
            throw DatabaseError(message: "Invalid delta cursor")
        }
        let origin = try Self.openSnapshot(source, flags: SQLITE_OPEN_READONLY)
        defer { sqlite3_close(origin) }
        try Self.validateSnapshot(origin)
        for (key, value) in [("generation", generation), ("revision", String(revision)), ("from_revision", String(fromRevision))] {
            guard try Self.snapshotStrings(origin, "SELECT value FROM metadata WHERE key='\(key)'").first == value else {
                throw DatabaseError(message: "Delta manifest does not match catalog")
            }
        }
        guard try self.generation == generation else { throw DatabaseError(message: "Delta generation does not match local catalog") }
        if try self.revision == revision {
            guard try strings("SELECT COUNT(*) FROM assets").first == String(assetCount) else { throw DatabaseError(message: "Completed delta count mismatch") }
            try checkpoint()
            return
        }
        guard try self.revision == fromRevision else { throw DatabaseError(message: "Delta starts at a different local revision") }
        try execute("ATTACH DATABASE ? AS delta", [source.path])
        do {
            try transaction {
                try execute("DELETE FROM assets WHERE id IN (SELECT id FROM delta.deleted_assets)")
                try execute("DELETE FROM paths WHERE asset_id IN (SELECT id FROM delta.assets)")
                try execute("INSERT INTO assets(id,snapshot,sort_time,filename,camera,rating,flag,color,trashed) SELECT id,snapshot,sort_time,filename,camera,rating,flag,color,trashed FROM delta.assets WHERE true ON CONFLICT(id) DO UPDATE SET snapshot=excluded.snapshot,sort_time=excluded.sort_time,filename=excluded.filename,camera=excluded.camera,rating=excluded.rating,flag=excluded.flag,color=excluded.color,trashed=excluded.trashed")
                try execute("INSERT INTO paths(asset_id,path) SELECT asset_id,path FROM delta.paths")
                try execute("DELETE FROM navigation")
                try execute("INSERT INTO navigation(path,snapshot) SELECT path,snapshot FROM delta.navigation")
                try execute("DELETE FROM hidden")
                try execute("INSERT INTO hidden(path) SELECT path FROM delta.hidden")
                try execute("DELETE FROM seen")
                try execute("DELETE FROM metadata WHERE key='sync_checkpoint'")
                try execute("INSERT OR REPLACE INTO metadata(key,value) VALUES('revision',?)", [String(revision)])
                guard try strings("SELECT COUNT(*) FROM assets").first == String(assetCount) else { throw DatabaseError(message: "Applied delta asset count mismatch") }
                guard try strings("PRAGMA foreign_key_check").isEmpty else { throw DatabaseError(message: "Applied delta has invalid paths") }
            }
        } catch {
            do { try execute("DETACH DATABASE delta") }
            catch let detach { throw DatabaseError(message: "\(error); detach failed: \(detach)") }
            throw error
        }
        try execute("DETACH DATABASE delta")
        try checkpoint()
    }

    public final class SnapshotReader {
        private var connection: OpaquePointer?
        public init(url: URL) throws {
            connection = try KeepsLibraryDatabase.openSnapshot(url, flags: SQLITE_OPEN_READONLY)
            do { try KeepsLibraryDatabase.validateSnapshot(connection) }
            catch { sqlite3_close(connection); throw error }
        }
        deinit { sqlite3_close(connection) }
        func close() { sqlite3_close(connection); connection = nil }
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
        Self.connections.lock.lock()
        defer { Self.connections.lock.unlock() }
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
        Self.connections.lock.lock()
        defer { Self.connections.lock.unlock() }
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
        Self.connections.lock.lock()
        defer { Self.connections.lock.unlock() }
        let statement = try statement(sql, values)
        defer { sqlite3_finalize(statement) }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW { result = sqlite3_step(statement) }
        guard result == SQLITE_DONE else { throw failure(sql) }
    }

    private func strings(_ sql: String, _ values: [String?] = []) throws -> [String] {
        Self.connections.lock.lock()
        defer { Self.connections.lock.unlock() }
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
