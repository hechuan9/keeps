import Foundation
import SQLite3

struct AIEditingPreferences: Codable {
    var text: String
    var revision: Int64
}

struct AIEditingPreferenceSuggestion: Identifiable, Equatable {
    let id: UUID
    let text: String
    let sourceName: String
    let sourceCandidateID: UUID
}

@MainActor final class AIEditingDatabase {
    // Operations remain MainActor-isolated; deinit only closes the exclusively owned handle.
    nonisolated(unsafe) private var handle: OpaquePointer?
    private let encoder: JSONEncoder = {
        let value = JSONEncoder()
        value.outputFormatting = .sortedKeys
        return value
    }()

    init(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let code = sqlite3_open_v2(root.appendingPathComponent("workspace.sqlite").path, &handle,
                                   SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK else {
            let error = databaseError("open", code: code)
            sqlite3_close(handle); handle = nil
            throw error
        }
        do {
            sqlite3_extended_result_codes(handle, 1)
            sqlite3_busy_timeout(handle, 5_000)
            let version = try rows("PRAGMA user_version").first?.first ?? "0"
            guard version == "0" || version == "1" || version == "2" else {
                throw AIEditingFailure("本机工作台数据库版本 \(version) 较新，请更新 Keeps。")
            }
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA foreign_keys=ON")
            try execute("PRAGMA synchronous=FULL")
            try transaction {
                try execute("CREATE TABLE IF NOT EXISTS preferences (singleton INTEGER PRIMARY KEY CHECK(singleton=1), text TEXT NOT NULL, revision INTEGER NOT NULL)")
                try execute("CREATE TABLE IF NOT EXISTS workspace (singleton INTEGER PRIMARY KEY CHECK(singleton=1), payload TEXT NOT NULL)")
                try execute("""
                    CREATE TABLE IF NOT EXISTS items (
                        id TEXT PRIMARY KEY, workspace_id INTEGER NOT NULL DEFAULT 1 REFERENCES workspace(singleton) ON DELETE CASCADE,
                        asset_id TEXT NOT NULL, position INTEGER NOT NULL CHECK(position>=0),
                        phase TEXT NOT NULL CHECK(phase IN ('preparing','downloading','grading','uploading','discarding','done','review')),
                        payload TEXT NOT NULL)
                    """)
                try execute("CREATE INDEX IF NOT EXISTS items_order ON items(position)")
                try execute("""
                    CREATE TABLE IF NOT EXISTS candidates (
                        id TEXT PRIMARY KEY, item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
                        position INTEGER NOT NULL CHECK(position>=0), payload TEXT NOT NULL)
                    """)
                try execute("CREATE INDEX IF NOT EXISTS candidates_order ON candidates(item_id,position)")
                try execute("""
                    CREATE TABLE IF NOT EXISTS preference_suggestions (
                        id TEXT PRIMARY KEY, text TEXT NOT NULL, normalized_text TEXT NOT NULL UNIQUE,
                        source_name TEXT NOT NULL, source_candidate_id TEXT NOT NULL,
                        status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','accepted','dismissed')))
                    """)
                try execute("PRAGMA user_version=2")
            }
        } catch {
            sqlite3_close(handle); handle = nil
            throw error
        }
    }

    deinit { sqlite3_close(handle) }

    func load() throws -> (batch: AIEditingBatch?, preferences: AIEditingPreferences)? {
        var result: (batch: AIEditingBatch?, preferences: AIEditingPreferences)?
        try transaction {
            guard let saved = try rows("SELECT text,revision FROM preferences WHERE singleton=1").first else { return }
            guard let revision = Int64(saved[1]) else { throw AIEditingFailure("本机工作台偏好版本无效。") }
            let preferences = AIEditingPreferences(text: saved[0], revision: revision)
            guard let header = try rows("SELECT payload FROM workspace WHERE singleton=1").first else {
                result = (nil, preferences); return
            }
            var object = try jsonObject(header[0])
            object["items"] = try rows("SELECT id,asset_id,phase,payload FROM items ORDER BY position,id").map { row in
                var item = try jsonObject(row[3])
                item["id"] = row[0]; item["assetID"] = row[1]; item["phase"] = row[2]
                item["candidates"] = try rows("SELECT id,payload FROM candidates WHERE item_id=? ORDER BY position,id", [row[0]]).map { candidate in
                    var object = try jsonObject(candidate[1]); object["id"] = candidate[0]; return object
                }
                return item
            }
            let data = try JSONSerialization.data(withJSONObject: object)
            result = (try JSONDecoder().decode(AIEditingBatch.self, from: data), preferences)
        }
        return result
    }

    func save(batch: AIEditingBatch?, preferences: AIEditingPreferences) throws {
        try transaction {
            try write(preferences: preferences)
            guard let batch else { try execute("DELETE FROM workspace"); return }
            var header = batch
            header.items = []
            let payload = try payload(header, excluding: ["items"])
            try execute("INSERT INTO workspace(singleton,payload) VALUES(1,?) ON CONFLICT(singleton) DO UPDATE SET payload=excluded.payload WHERE payload<>excluded.payload", [payload])
            let ids = Set(batch.items.map { $0.id.uuidString })
            for row in try rows("SELECT id FROM items") where !ids.contains(row[0]) {
                try execute("DELETE FROM items WHERE id=?", [row[0]])
            }
            for (position, item) in batch.items.enumerated() { try write(item: item, position: position) }
        }
    }

    func save(item: AIEditingBatch.Item, position: Int) throws {
        try transaction {
            guard try !rows("SELECT id FROM items WHERE id=?", [item.id.uuidString]).isEmpty else {
                throw AIEditingFailure("照片已离开本机工作台，不能写入处理进度。")
            }
            try write(item: item, position: position)
        }
    }

    func preferenceSuggestions() throws -> [AIEditingPreferenceSuggestion] {
        try rows("SELECT id,text,source_name,source_candidate_id FROM preference_suggestions WHERE status='pending' ORDER BY rowid").map { row in
            guard let id = UUID(uuidString: row[0]), let candidateID = UUID(uuidString: row[3]) else {
                throw AIEditingFailure("本机审美偏好建议的标识无效。")
            }
            return AIEditingPreferenceSuggestion(id: id, text: row[1], sourceName: row[2], sourceCandidateID: candidateID)
        }
    }

    func resolvePreferenceSuggestion(id: UUID, preferences: AIEditingPreferences?) throws {
        try transaction {
            guard try !rows("SELECT id FROM preference_suggestions WHERE id=? AND status='pending'", [id.uuidString]).isEmpty else {
                throw AIEditingFailure("这条审美偏好建议已处理或不存在。")
            }
            if let preferences { try write(preferences: preferences) }
            try execute("UPDATE preference_suggestions SET status=? WHERE id=?", [preferences == nil ? "dismissed" : "accepted", id.uuidString])
        }
    }

    private func write(preferences: AIEditingPreferences) throws {
        try execute("""
            INSERT INTO preferences(singleton,text,revision) VALUES(1,?,?)
            ON CONFLICT(singleton) DO UPDATE SET text=excluded.text,revision=excluded.revision
            WHERE text<>excluded.text OR revision<>excluded.revision
            """, [preferences.text, String(preferences.revision)])
    }

    private func write(item: AIEditingBatch.Item, position: Int) throws {
        var state = item
        state.candidates = nil
        let value = try payload(state, excluding: ["id", "assetID", "phase", "candidates"])
        try execute("""
            INSERT INTO items(id,asset_id,position,phase,payload) VALUES(?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET asset_id=excluded.asset_id,position=excluded.position,phase=excluded.phase,payload=excluded.payload
            WHERE asset_id<>excluded.asset_id OR position<>excluded.position OR phase<>excluded.phase OR payload<>excluded.payload
            """, [item.id.uuidString, item.assetID.uuidString, String(position), item.phase.rawValue, value])
        let ids = Set((item.candidates ?? []).map { $0.id.uuidString })
        for row in try rows("SELECT id FROM candidates WHERE item_id=?", [item.id.uuidString]) where !ids.contains(row[0]) {
            try execute("DELETE FROM candidates WHERE id=?", [row[0]])
        }
        for (position, candidate) in (item.candidates ?? []).enumerated() {
            try execute("""
                INSERT INTO candidates(id,item_id,position,payload) VALUES(?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET item_id=excluded.item_id,position=excluded.position,payload=excluded.payload
                WHERE item_id<>excluded.item_id OR position<>excluded.position OR payload<>excluded.payload
                """, [candidate.id.uuidString, item.id.uuidString, String(position), try payload(candidate, excluding: ["id"])])
            let suggestions = (candidate.result.preferenceSuggestions ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(3)
            for text in suggestions {
                let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
                try execute("""
                    INSERT INTO preference_suggestions(id,text,normalized_text,source_name,source_candidate_id)
                    VALUES(?,?,?,?,?) ON CONFLICT(normalized_text) DO NOTHING
                    """, [UUID().uuidString, text, normalized, item.name, candidate.id.uuidString])
            }
        }
    }

    private func payload<T: Encodable>(_ value: T, excluding keys: [String]) throws -> String {
        var object = try jsonObject(String(decoding: encoder.encode(value), as: UTF8.self))
        for key in keys { object.removeValue(forKey: key) }
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: .sortedKeys), as: UTF8.self)
    }

    private func jsonObject(_ text: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw AIEditingFailure("本机工作台数据库记录不是有效对象。")
        }
        return object
    }

    private func transaction(_ action: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try action(); try execute("COMMIT") }
        catch {
            let original = error
            do { try execute("ROLLBACK") }
            catch {
                throw NSError(domain: "AIEditingDatabase", code: Int(sqlite3_extended_errcode(handle)),
                              userInfo: [NSLocalizedDescriptionKey: "事务失败：\(original)；回滚失败：\(error)", NSUnderlyingErrorKey: original])
            }
            throw original
        }
    }

    private func execute(_ sql: String, _ values: [String] = []) throws { _ = try rows(sql, values) }

    private func rows(_ sql: String, _ values: [String] = []) throws -> [[String]] {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK else { throw databaseError(sql, code: prepared) }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let code = sqlite3_bind_text(statement, Int32(offset + 1), value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            guard code == SQLITE_OK else { throw databaseError(sql, code: code) }
        }
        var output: [[String]] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return output }
            guard code == SQLITE_ROW else { throw databaseError(sql, code: code) }
            output.append((0..<sqlite3_column_count(statement)).map { index in
                guard let text = sqlite3_column_text(statement, index) else { return "" }
                return String(cString: text)
            })
        }
    }

    private func databaseError(_ operation: String, code: Int32) -> NSError {
        let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开 SQLite"
        return NSError(domain: "AIEditingDatabase", code: Int(code), userInfo: [
            NSLocalizedDescriptionKey: "SQLite \(code): \(message) [\(operation)]"
        ])
    }
}
