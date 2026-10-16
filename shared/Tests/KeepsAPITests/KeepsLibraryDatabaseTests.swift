import Foundation
import SQLite3
import Testing
@testable import KeepsAPI

@MainActor
struct KeepsLibraryDatabaseTests {
    private let configuration = KeepsConfiguration(baseURL: URL(string: "https://nas.example")!, libraryID: "photos", accessCredential: "credential")
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func asset(_ n: Int, paths: [String] = []) -> KeepsAsset {
        KeepsAsset(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!, captureTime: "2026-01-01", cameraMake: "", cameraModel: "Camera", lensModel: "", originalFilename: "photo\(n).jpg", contentFingerprint: "hash", metadataFingerprint: "meta", rating: 3, flagState: "picked", colorLabel: nil, tags: ["travel"], createdAt: "2026-01-01", updatedAt: "2026-01-01", trashed: false, preview: nil, paths: paths)
    }

    private func sql(_ url: URL, _ sql: String) throws {
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let code = sqlite3_exec(db, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw KeepsLibraryDatabase.DatabaseError(message: String(cString: sqlite3_errmsg(db))) }
    }

    @Test func deltaMergeMatchesFullSnapshotAndRejectsMismatchesAtomically() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let generation = UUID().uuidString
        let local = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: root.appendingPathComponent("local"))
        let reader = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: root.appendingPathComponent("local"))
        try local.ingest([asset(1, paths: ["/old/B0014325.HEIC"]), asset(2, paths: ["/old/B0014325.3FR"]), asset(3)])
        try local.completeSync(revision: 10, isStable: true)
        try sql(local.fileURL, "INSERT INTO metadata VALUES('generation','\(generation)')")
        let delta = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: root.appendingPathComponent("delta"))
        let merged = asset(1, paths: ["/new/B0014325.HEIC", "/new/B0014325.3FR"])
        try delta.ingest([merged])
        try delta.completeSync(revision: 12, isStable: true)
        try delta.replaceHiddenDirectories(["/hidden"])
        let navigation = KeepsNavigation(path: nil, directories: [KeepsNavigationDirectory(path: "/new", name: "new", photoCount: 1, hasChildren: false)])
        try delta.saveNavigation(navigation)
        try local.saveNavigation(KeepsNavigation(path: nil, directories: []))
        try sql(delta.fileURL, "INSERT INTO metadata VALUES('generation','\(generation)'),('from_revision','10'); CREATE TABLE deleted_assets(id TEXT PRIMARY KEY); INSERT INTO deleted_assets VALUES('\(asset(2).id.uuidString)')")
        let package = root.appendingPathComponent("delta.sqlite")
        try delta.exportSnapshot(to: package)
        #expect(throws: KeepsLibraryDatabase.DatabaseError.self) {
            try local.applyDelta(from: package, generation: UUID().uuidString, fromRevision: 10, revision: 12, assetCount: 2)
        }
        #expect(throws: KeepsLibraryDatabase.DatabaseError.self) {
            try local.applyDelta(from: package, generation: generation, fromRevision: 10, revision: 12, assetCount: 99)
        }
        #expect(try reader.revision == 10)
        #expect(try reader.assets(ids: [asset(2).id]).count == 1)
        try local.applyDelta(from: package, generation: generation, fromRevision: 10, revision: 12, assetCount: 2)
        #expect(try reader.revision == 12)
        #expect(try reader.assets(ids: [asset(2).id]).isEmpty)
        #expect(try reader.assets(ids: [merged.id]).first?.paths == merged.paths)
        #expect(try reader.hiddenDirectories() == ["/hidden"])
        #expect(try reader.navigation()?.directories.first?.path == "/new")
        try local.applyDelta(from: package, generation: generation, fromRevision: 10, revision: 12, assetCount: 2)
        let full = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: root.appendingPathComponent("full"))
        try full.ingest([merged, asset(3)])
        try full.completeSync(revision: 12, isStable: true)
        #expect(try reader.timeline(query: .init()) == full.timeline(query: .init()))
        var old = KeepsAssetQuery(); old.directory = "/old"
        #expect(try reader.assets(query: old).total == 0)
        var edited = merged; edited.rating = 5
        try reader.update(edited)
        #expect(try reader.revision == 12)
    }

    @Test func repeatedSnapshotReplacementReopensAllReadersWithoutGrowingWAL() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: root.appendingPathComponent("source"))
        try source.ingest((1...300).map { asset($0) })
        try source.completeSync(revision: 20, isStable: true)
        try source.saveNavigation(KeepsNavigation(path: nil, directories: [KeepsNavigationDirectory(path: "/photos", name: "photos", photoCount: 300, hasChildren: false)]))
        let snapshot = root.appendingPathComponent("snapshot.sqlite")
        try source.exportSnapshot(to: snapshot)
        let local = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: root.appendingPathComponent("local"))
        let other = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: root.appendingPathComponent("local"))
        try local.ingest([asset(999)])
        try local.completeSync(revision: 1, isStable: true)
        for _ in 0..<5 {
            try local.replaceSnapshot(from: snapshot, revision: 20, assetCount: 300)
            #expect(try other.revision == 20)
            #expect(try other.assets(query: .init()).total == 300)
            #expect(try other.navigation()?.directories.first?.photoCount == 300)
            let wal = URL(fileURLWithPath: local.fileURL.path + "-wal")
            #expect(((try? wal.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) < 65_536)
        }
    }

    @Test func replicaIdentityIsLocalAndSurvivesSnapshotReplacement() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: root.appendingPathComponent("first"))
        let id = try first.replicaID()
        try first.completeSync(revision: 1, isStable: true)
        let snapshot = root.appendingPathComponent("snapshot.sqlite")
        try first.exportSnapshot(to: snapshot)
        let second = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: root.appendingPathComponent("second"))
        #expect(try second.restoreSnapshot(from: snapshot))
        #expect(try second.replicaID() != id)
        try first.replaceSnapshot(from: snapshot, revision: 1, assetCount: 0)
        #expect(try first.replicaID() == id)
    }

    @Test func timelineMatchesEveryFilterAndIgnoresPagination() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: root)
        var photos = (1...12).map { asset($0, paths: [$0.isMultiple(of: 2) ? "/photos/sub/\($0).jpg" : "/photos/\($0).jpg"]) }
        photos[0].captureTime = nil
        photos[0].createdAt = "2027-01-01"
        photos[1].rating = 1
        photos[2].flagState = "rejected"
        photos[3].colorLabel = "red"
        photos[4].tags = ["family"]
        photos[5].trashed = true
        photos[6].paths = ["/hidden/7.jpg"]
        photos[7].originalFilename = "100%_photo.jpg"
        photos[8].cameraModel = "Other"
        photos[9].browseThumbnail = KeepsPreview(downloadURL: URL(string: "https://nas.example/browse")!, width: 64, height: 48, version: "b1")
        photos[9].thumbnail = KeepsPreview(downloadURL: URL(string: "https://nas.example/thumb")!, width: 80, height: 60, version: "t1")
        photos[9].preview = KeepsPreview(downloadURL: URL(string: "https://nas.example/preview")!, width: 800, height: 600, version: "p1")
        photos[9].standard = KeepsPreview(downloadURL: URL(string: "https://nas.example/standard")!, width: 2400, height: 1800, version: "s1")
        try db.ingest(photos.reversed())
        try db.replaceHiddenDirectories(["/hidden"])
        var queries = [KeepsAssetQuery()]
        func add(_ configure: (inout KeepsAssetQuery) -> Void) {
            var query = KeepsAssetQuery()
            configure(&query)
            queries.append(query)
        }
        add { $0.minRating = 3 }
        add { $0.flagState = "rejected" }
        add { $0.colorLabel = "red" }
        add { $0.tag = "family" }
        add { $0.trashed = true }
        add { $0.showHidden = true }
        add { $0.directory = "/hidden" }
        add { $0.directory = "/photos"; $0.recursive = false }
        add { $0.directory = "/photos"; $0.recursive = true }
        add { $0.q = "%_" }
        add { $0.q = "Other" }
        add { $0.directory = "/photos"; $0.minRating = 3; $0.tag = "travel"; $0.flagState = "picked" }
        for var query in queries {
            query.limit = 100
            let expected = try db.assets(query: query).items
            query.limit = 1
            query.cursor = "9"
            let timeline = try db.timeline(query: query)
            #expect(timeline.map(\.id) == expected.map(\.id))
            #expect(timeline.map(\.date) == expected.map { $0.captureTime ?? $0.createdAt })
            #expect(timeline.map(\.browseThumbnail) == expected.map(\.browseThumbnail))
            #expect(timeline.map(\.gridPreview) == expected.map(\.gridPreview))
            #expect(timeline.map(\.standard) == expected.map(\.standard))
            #expect(timeline.map(\.flagState) == expected.map(\.flagState))
            #expect(timeline.map(\.filename) == expected.map(\.originalFilename))
        }
        #expect(try db.timeline(query: .init()).first?.id == photos[0].id)
    }

    @Test func viewportAssetsPreserveOrderAcrossBatchesAndSkipMissingIDs() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: root)
        let photos = (1...1100).map { asset($0) }
        try db.ingest(photos)
        let requested = photos.reversed().map(\.id) + [asset(9999).id, photos[0].id]
        #expect(try db.assets(ids: requested) == Array(photos.reversed()) + [photos[0]])
        #expect(try db.assets(ids: []).isEmpty)
    }

    @Test func snapshotIncludesCommittedWALAndRestoresOpenReadersAndNavigation() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: root.appendingPathComponent("source"))
        try source.ingest([asset(1)])
        try source.completeSync(revision: 11, isStable: true)
        try source.update(asset(2))
        try source.saveNavigation(.init(path: nil, directories: [.init(path: "/photos", name: "photos", photoCount: 2, hasChildren: false)]))
        #expect(FileManager.default.fileExists(atPath: source.fileURL.path + "-wal"))
        let snapshot = root.appendingPathComponent("snapshot.sqlite")
        try source.exportSnapshot(to: snapshot)
        #expect(!FileManager.default.fileExists(atPath: snapshot.path + "-wal"))
        let destination = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: root.appendingPathComponent("destination"))
        let reader = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: root.appendingPathComponent("destination"))
        #expect(try reader.assets(query: .init()).total == 0)
        #expect(try destination.restoreSnapshot(from: snapshot))
        #expect(try reader.assets(query: .init()).items.map(\.id) == [asset(1).id, asset(2).id])
        #expect(try reader.revision == 11)
        #expect(try reader.navigation()?.directories.first?.photoCount == 2)
        #expect(try !destination.restoreSnapshot(from: snapshot))
    }

    @Test func snapshotRejectsIncompleteAndCorruptInputWithoutOverwriting() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: root)
        let snapshot = root.appendingPathComponent("snapshot.sqlite")
        try Data("invalid".utf8).write(to: snapshot)
        #expect(throws: KeepsLibraryDatabase.DatabaseError.self) { _ = try db.restoreSnapshot(from: snapshot) }
        #expect(try db.assets(query: .init()).total == 0)
        #expect(throws: KeepsLibraryDatabase.DatabaseError.self) { try db.exportSnapshot(to: snapshot) }
        #expect(try Data(contentsOf: snapshot) == Data("invalid".utf8))
        try db.beginSync(checkpoint: .init(revision: 3, stable: true))
        #expect(try !db.restoreSnapshot(from: snapshot))
        try db.ingest([asset(1)])
        #expect(try !db.restoreSnapshot(from: snapshot))
        #expect(try db.assets(query: .init()).total == 1)
    }

    @Test func snapshotRejectsWrongSchemaAndStableEmptyCatalogIsNotReplaced() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: root)
        let snapshot = root.appendingPathComponent("wrong-schema.sqlite")
        var source: OpaquePointer?
        #expect(sqlite3_open(snapshot.path, &source) == SQLITE_OK)
        defer { sqlite3_close(source) }
        #expect(sqlite3_exec(source, "CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT); INSERT INTO metadata VALUES('revision','9')", nil, nil, nil) == SQLITE_OK)
        #expect(throws: KeepsLibraryDatabase.DatabaseError.self) { _ = try local.restoreSnapshot(from: snapshot) }
        #expect(try local.revision == nil)
        #expect(try local.assets(query: .init()).total == 0)
        try local.completeSync(revision: 5, isStable: true)
        #expect(try !local.restoreSnapshot(from: snapshot))
        #expect(try local.revision == 5)
        try local.exportSnapshot(to: snapshot)
        try local.exportSnapshot(to: snapshot)
        let restored = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: root.appendingPathComponent("restored"))
        #expect(try restored.restoreSnapshot(from: snapshot))
        #expect(try restored.revision == 5)
    }

    @Test func newerKeysetReturnsNearestPageAndBoundedRefreshKeepsItsStart() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: root)
        try db.ingest((1...20).map { asset($0) })
        var query = KeepsAssetQuery()
        query.limit = 3
        let newer = try db.assets(query: query, newerThan: asset(10))
        #expect(newer.items.map(\.id) == (7...9).map { asset($0).id })
        #expect(newer.nextCursor != nil)
        let first = try db.assets(query: query, newerThan: asset(3))
        #expect(first.items.map(\.id) == [asset(1).id, asset(2).id])
        #expect(first.nextCursor == nil)
        let retained = try db.assets(query: query, startingAt: asset(10))
        #expect(retained.items.map(\.id) == (10...12).map { asset($0).id })
        let bounded = try db.assets(query: query, includingThrough: asset(20), maximumLimit: 5)
        #expect(bounded.items.count == 5)
        #expect(bounded.nextCursor != nil)
    }

    @Test func reopenReadsCatalogAndNavigationWithoutNetwork() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let db = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: root)
            try db.beginSync()
            try db.ingest([asset(1, paths: ["/photos/one.jpg"])])
            try db.replaceHiddenDirectories(["/private"])
            try db.saveNavigation(KeepsNavigation(path: nil, directories: [KeepsNavigationDirectory(path: "/photos", name: "photos", photoCount: 1, hasChildren: false)]))
            try db.completeSync(revision: 9, isStable: true)
        }
        let reopened = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: root)
        #expect(try reopened.assets(query: KeepsAssetQuery()).items.map(\.id) == [asset(1).id])
        #expect(try reopened.revision == 9)
        #expect(try reopened.hiddenDirectories() == ["/private"])
        #expect(try reopened.navigation()?.directories.first?.path == "/photos")
    }

    @Test func scopesIsolateServerLibraryAndCredential() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: root)
        try db.ingest([asset(1)])
        var scopes = [configuration, configuration, configuration]
        scopes[0].baseURL = URL(string: "https://another.example")!
        scopes[1].libraryID = "other"
        scopes[2].accessCredential = "other"
        for scope in scopes {
            let other = try KeepsLibraryDatabase(configuration: scope, rootDirectory: root)
            #expect(try other.assets(query: KeepsAssetQuery()).total == 0)
            #expect(other.fileURL != db.fileURL)
        }
    }

    @Test func partialSyncRetainsRowsAndStableScanReconciles() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: root)
        try db.beginSync()
        try db.ingest([asset(1), asset(2)])
        try db.completeSync(revision: 1, isStable: true)
        try db.beginSync()
        try db.ingest([asset(3)])
        try db.completeSync(revision: 2, isStable: false)
        #expect(try db.assets(query: KeepsAssetQuery()).total == 3)
        #expect(try db.revision == nil)
        try db.beginSync()
        try db.ingest([asset(2), asset(3)])
        try db.completeSync(revision: 3, isStable: true)
        #expect(try db.assets(query: KeepsAssetQuery()).items.map(\.id) == [asset(2).id, asset(3).id])
    }

    @Test func interruptedScanReopensAsIncompleteWithoutLosingPhotos() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let db = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: root)
            try db.beginSync()
            try db.ingest([asset(1)])
            try db.completeSync(revision: 1, isStable: true)
            try db.beginSync()
            try db.ingest([asset(2)])
        }
        let reopened = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: root)
        #expect(try reopened.revision == nil)
        #expect(try reopened.assets(query: KeepsAssetQuery()).total == 2)
    }

    @Test func syncCheckpointAndSeenRowsSurviveReopening() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let db = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: root)
            try db.ingest([asset(99)])
            var checkpoint = KeepsLibraryDatabase.SyncCheckpoint(revision: 7, stable: true)
            try db.beginSync(checkpoint: checkpoint)
            checkpoint.cursor = "page-two"
            try db.ingest([asset(1)], checkpoint: checkpoint)
        }
        let reopened = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: root)
        var checkpoint = try #require(try reopened.syncCheckpoint)
        #expect(checkpoint.cursor == "page-two")
        checkpoint.cursor = nil
        checkpoint.phase = 2
        try reopened.ingest([asset(2)], checkpoint: checkpoint)
        try reopened.completeSync(revision: 7, isStable: true)
        #expect(try reopened.assets(query: KeepsAssetQuery()).items.map(\.id) == [asset(1).id, asset(2).id])
        #expect(try reopened.syncCheckpoint == nil)
    }

    @Test func unstableResumedScanDoesNotDeleteUnseenRows() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: root)
        try db.ingest([asset(99)])
        try db.beginSync(checkpoint: .init(revision: 1, stable: true))
        try db.ingest([asset(1)])
        try db.completeSync(revision: 2, isStable: false)
        #expect(try db.assets(query: KeepsAssetQuery()).total == 2)
        #expect(try db.syncCheckpoint == nil)
        #expect(try db.revision == nil)
    }

    @Test func corruptedDatabaseIsReportedAndPreserved() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let path: URL
        do {
            let db = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: root)
            path = db.fileURL
        }
        let corruption = Data("not a SQLite database".utf8)
        try corruption.write(to: path)
        #expect(throws: KeepsLibraryDatabase.DatabaseError.self) {
            _ = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: root)
        }
        #expect(try Data(contentsOf: path) == corruption)
    }

    @Test func nestedHiddenDirectoriesAndUpdatedPathsMatchServerSemantics() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: root)
        try db.ingest([asset(1, paths: ["/hidden/1.jpg"]), asset(2, paths: ["/hidden/child/2.jpg"]), asset(3, paths: ["/hidden-other/3.jpg"])])
        try db.replaceHiddenDirectories(["/hidden", "/hidden/child"])
        var query = KeepsAssetQuery()
        #expect(try db.assets(query: query).items.map(\.id) == [asset(3).id])
        query.directory = "/hidden/"
        #expect(try db.assets(query: query).items.map(\.id) == [asset(1).id])
        query.directory = "/hidden/child"
        #expect(try db.assets(query: query).items.map(\.id) == [asset(2).id])
        try db.update(asset(2, paths: ["/visible/2.jpg"]))
        #expect(try db.assets(query: query).total == 0)
        query.directory = "/visible"
        #expect(try db.assets(query: query).items.map(\.id) == [asset(2).id])
    }

    @Test func queryUsesPathsHiddenExceptionsAndStablePagination() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: root)
        try db.ingest([asset(3, paths: ["/photos/sub/3.jpg"]), asset(2, paths: ["/photos/2.jpg", "/hidden/2.jpg"]), asset(1, paths: ["/photos/1.jpg"])])
        try db.replaceHiddenDirectories(["/hidden"])
        var query = KeepsAssetQuery()
        query.directory = "/photos"
        #expect(try db.assets(query: query).items.map(\.id) == [asset(1).id, asset(3).id])
        query.recursive = false
        #expect(try db.assets(query: query).total == 1)
        query.directory = "/hidden"
        #expect(try db.assets(query: query).items.map(\.id) == [asset(2).id])
        query.directory = nil
        query.showHidden = true
        query.limit = 1
        var ids: [UUID] = []
        repeat {
            let page = try db.assets(query: query)
            ids += page.items.map(\.id)
            query.cursor = page.nextCursor
        } while query.cursor != nil
        #expect(ids == [asset(1).id, asset(2).id, asset(3).id])
        query.limit = 100
        query.q = "camera"
        query.flagState = "picked"
        query.tag = "travel"
        #expect(try db.assets(query: query).total == 3)
        query.q = "%"
        #expect(try db.assets(query: query).total == 0)
        query.q = "photo2"
        #expect(try db.assets(query: query).total == 1)
        var changed = asset(2, paths: ["/new/2.jpg"])
        changed.trashed = true
        try db.update(changed)
        query.q = ""
        query.trashed = true
        query.directory = "/new"
        #expect(try db.assets(query: query).items.map(\.id) == [changed.id])
    }
}
