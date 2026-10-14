import CryptoKit
import Foundation
import SQLite3
import OSLog

/// iCloud transports snapshots and immutable thumbnails; SQLite remains the active local catalog.
public actor KeepsCloudReplica {
    public static let shared = KeepsCloudReplica()
    private let cloudRoot: URL?
    private let cache: PreviewCache
    private let browsingCache: PreviewCache

    public init(cloudRoot: URL? = nil, cache: PreviewCache = .thumbnails, browsingCache: PreviewCache = .browsing) {
        self.cloudRoot = cloudRoot
        self.cache = cache
        self.browsingCache = browsingCache
    }

    @discardableResult
    public func restore(configuration: KeepsConfiguration, databaseRoot: URL? = nil, includeThumbnails: Bool = true,
                        progress: (@Sendable (String) async -> Void)? = nil,
                        workProgress: (@Sendable (Int64, Int64) async -> Void)? = nil) async throws -> Bool {
        guard let root = replicaRoot(configuration) else {
            await progress?("iCloud 当前不可用，本地图库保留。")
            return false
        }
        try Task.checkCancellation()
        await progress?("正在查找 iCloud 图库副本…")
        let inventory = try await inventory(root, snapshotOnly: !includeThumbnails)
        let snapshot = root.appendingPathComponent("catalog.snapshot", isDirectory: false)
        guard inventory.contains(snapshot) else { return false }
        let temporary = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        await progress?("正在从 iCloud 恢复图库数据库…")
        try await makeAvailable(snapshot)
        let localSnapshot = temporary.appendingPathComponent("catalog.snapshot", isDirectory: false)
        try coordinatedRead(snapshot, to: localSnapshot)
        if !includeThumbnails {
            try Task.checkCancellation()
            let local = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: databaseRoot)
            let restored = try local.restoreSnapshot(from: localSnapshot)
            await workProgress?(1, 1)
            return restored
        }
        let database = try KeepsLibraryDatabase(snapshotURL: localSnapshot)
        let work = ReplicaWorkProgress(total: try thumbnailWorkTotal(database), callback: workProgress)
        await work.advance(1, force: true)
        var processed = 0
        var cached = try await cache.cachedKeys()
        cached.formUnion(try await browsingCache.cachedKeys())
        let clock = ContinuousClock()
        var lastProgress = clock.now
        try await forEachThumbnailPage(database: database, configuration: configuration) { keys, itemCount in
            let missing = keys.filter { !cached.contains($0.key) && inventory.contains(thumbnailURL($0.key, root: root)) }
            await work.advance(Int64(itemCount - missing.count))
            for item in missing {
                let key = item.key
                let targetCache = item.browsing ? browsingCache : cache
                try Task.checkCancellation()
                do {
                    let source = thumbnailURL(key, root: root)
                    if cloudRoot == nil {
                        try FileManager.default.startDownloadingUbiquitousItem(at: source)
                    }
                    try await makeAvailable(source, downloadRequested: true)
                    let localFile = temporary.appendingPathComponent(key, isDirectory: false)
                    try coordinatedRead(source, to: localFile)
                    try await targetCache.importCachedFile(from: localFile, key: key)
                    try FileManager.default.removeItem(at: localFile)
                    cached.insert(key)
                    processed += 1
                } catch {
                    try Task.checkCancellation()
                    Logger(subsystem: "local.keeps", category: "cloud-replica")
                        .error("Optional cloud thumbnail \(key, privacy: .public) failed: \(String(reflecting: error), privacy: .public)")
                }
                await work.advance(1)
                if lastProgress.duration(to: clock.now) >= .seconds(1) {
                    await progress?("已从 iCloud 恢复 \(processed) 张缩略图…")
                    lastProgress = clock.now
                }
            }
        }
        await work.report()
        try Task.checkCancellation()
        let local = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: databaseRoot)
        return try local.restoreSnapshot(from: localSnapshot)
    }

    public func backup(configuration: KeepsConfiguration, databaseRoot: URL? = nil,
                       progress: (@Sendable (String) async -> Void)? = nil,
                       workProgress: (@Sendable (Int64, Int64) async -> Void)? = nil) async throws {
        guard let root = replicaRoot(configuration) else {
            await progress?("iCloud 当前不可用，本地图库保留。")
            return
        }
        try Task.checkCancellation()
        let database = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: databaseRoot)
        let temporary = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let snapshot = temporary.appendingPathComponent("catalog.snapshot", isDirectory: false)
        try database.exportSnapshot(to: snapshot)
        let stable = try KeepsLibraryDatabase(snapshotURL: snapshot)
        await progress?("正在把图库数据库交给 iCloud 同步…")
        var existing = try await inventory(root)
        try Task.checkCancellation()
        let remoteSnapshot = root.appendingPathComponent("catalog.snapshot", isDirectory: false)
        let revision = try Self.snapshotRevision(snapshot)
        var stageCatalog = true
        if existing.contains(remoteSnapshot) {
            try await makeAvailable(remoteSnapshot)
            stageCatalog = try coordinatedRevision(remoteSnapshot) < revision
        }
        if stageCatalog {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try coordinatedWrite(snapshot, to: remoteSnapshot, replacingWithRevision: revision)
        }
        let work = ReplicaWorkProgress(total: try thumbnailWorkTotal(stable), callback: workProgress)
        await work.advance(1, force: true)
        var staged = 0
        let clock = ContinuousClock()
        var lastProgress = clock.now
        try await forEachThumbnailPage(database: stable, configuration: configuration) { keys, itemCount in
            await work.advance(Int64(itemCount - keys.count))
            for item in keys {
                let key = item.key
                let sourceCache = item.browsing ? browsingCache : cache
                try Task.checkCancellation()
                let destination = thumbnailURL(key, root: root)
                guard !existing.contains(destination), let source = try await sourceCache.cachedFileURL(forKey: key) else {
                    await work.advance(1)
                    continue
                }
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try coordinatedWrite(source, to: destination)
                existing.insert(destination)
                staged += 1
                await work.advance(1)
                if lastProgress.duration(to: clock.now) >= .seconds(1) {
                    await progress?("已把 \(staged) 张缩略图交给 iCloud 同步…")
                    lastProgress = clock.now
                }
            }
        }
        await work.report()
        await progress?("图库副本已交给 iCloud 同步，上传由系统继续完成。")
    }

    private func replicaRoot(_ configuration: KeepsConfiguration) -> URL? {
        let root = cloudRoot ?? FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.com.hechuan.Keeps")?
            .appendingPathComponent("Data/Replicas", isDirectory: true)
        let identity = [configuration.baseURL.absoluteString, configuration.libraryID]
            .map { "\($0.utf8.count):\($0)" }.joined()
        let namespace = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return root?.resolvingSymlinksInPath().appendingPathComponent(namespace, isDirectory: true)
    }

    private func thumbnailURL(_ key: String, root: URL) -> URL {
        root.appendingPathComponent("thumbnails/\(key.prefix(2))/\(key)", isDirectory: false)
    }

    private func inventory(_ root: URL, snapshotOnly: Bool = false) async throws -> Set<URL> {
        if cloudRoot != nil {
            if snapshotOnly {
                let snapshot = root.appendingPathComponent("catalog.snapshot")
                return FileManager.default.fileExists(atPath: snapshot.path) ? [snapshot.resolvingSymlinksInPath()] : []
            }
            guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
            var result: Set<URL> = []
            while let url = files.nextObject() as? URL {
                try Task.checkCancellation()
                if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { result.insert(url.resolvingSymlinksInPath()) }
            }
            return result
        }
        let discovered = try await CloudReplicaMetadata.urls(in: root, snapshotOnly: snapshotOnly)
        var result: Set<URL> = []
        for url in discovered {
            try Task.checkCancellation()
            let canonical = url.resolvingSymlinksInPath()
            if canonical.path.hasPrefix(root.path + "/") { result.insert(canonical) }
        }
        return result
    }

    private func makeAvailable(_ url: URL, downloadRequested: Bool = false) async throws {
        try Task.checkCancellation()
        guard cloudRoot == nil else { return }
        if !downloadRequested { try FileManager.default.startDownloadingUbiquitousItem(at: url) }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(120))
        while true {
            try Task.checkCancellation()
            var refreshed = url
            refreshed.removeAllCachedResourceValues()
            let values = try refreshed.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey, .ubiquitousItemDownloadingErrorKey])
            if let error = values.ubiquitousItemDownloadingError { throw error }
            if values.ubiquitousItemDownloadingStatus == .current { return }
            guard clock.now < deadline else { throw ReplicaError.downloadTimedOut(url) }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    private func thumbnailWorkTotal(_ database: KeepsLibraryDatabase) throws -> Int64 {
        var query = KeepsAssetQuery()
        query.showHidden = true
        query.limit = 1
        let active = try database.assets(query: query).total
        query.trashed = true
        return 1 + 2 * (Int64(active) + Int64(try database.assets(query: query).total))
    }

    private func forEachThumbnailPage(database: KeepsLibraryDatabase, configuration: KeepsConfiguration,
                                  visit: ([(key: String, browsing: Bool)], Int) async throws -> Void) async throws {
        for trashed in [false, true] {
            var query = KeepsAssetQuery()
            query.showHidden = true
            query.trashed = trashed
            query.limit = 100
            var boundary: KeepsAsset?
            var total: Int?
            while true {
                try Task.checkCancellation()
                let page = try database.assets(query: query, olderThan: boundary, knownTotal: total)
                total = page.total
                let keys: [(key: String, browsing: Bool)] = page.items.flatMap { asset in
                    var keys: [(key: String, browsing: Bool)] = []
                    if let preview = asset.thumbnail {
                        keys.append((PreviewCache.key(assetID: asset.id, preview: preview,
                                                      configuration: configuration, role: .thumbnail), false))
                    }
                    if let preview = asset.browseThumbnail {
                        keys.append((PreviewCache.key(assetID: asset.id, preview: preview,
                                                      configuration: configuration, role: .browse), true))
                    }
                    return keys
                }
                try await visit(keys, page.items.count * 2)
                guard page.nextCursor != nil, let last = page.items.last else { break }
                boundary = last
            }
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("keeps-cloud-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func coordinatedRead(_ source: URL, to destination: URL) throws {
        try autoreleasepool {
            var coordinationError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { url in
                do { try FileManager.default.copyItem(at: url, to: destination) }
                catch { copyError = error }
            }
            if let error = coordinationError ?? copyError { throw error }
        }
    }

    private func coordinatedWrite(_ source: URL, to destination: URL, replacingWithRevision revision: Int64? = nil) throws {
        try autoreleasepool {
            var coordinationError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinationError) { url in
                do {
                    let exists = FileManager.default.fileExists(atPath: url.path)
                    if exists {
                        guard let revision else { return }
                        // Recheck under the write coordination in case another device advanced the snapshot.
                        if try Self.snapshotRevision(url) >= revision { return }
                    }
                    let staged = url.deletingLastPathComponent().appendingPathComponent("." + UUID().uuidString + ".stage", isDirectory: false)
                    defer { try? FileManager.default.removeItem(at: staged) }
                    try FileManager.default.copyItem(at: source, to: staged)
                    if exists { _ = try FileManager.default.replaceItemAt(url, withItemAt: staged) }
                    else { try FileManager.default.moveItem(at: staged, to: url) }
                } catch { copyError = error }
            }
            if let error = coordinationError ?? copyError { throw error }
        }
    }

    private func coordinatedRevision(_ source: URL) throws -> Int64 {
        return try autoreleasepool {
            var coordinationError: NSError?
            var result: Result<Int64, Error>?
            NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { url in
                result = Result { try Self.snapshotRevision(url) }
            }
            if let coordinationError { throw coordinationError }
            guard let result else { throw ReplicaError.snapshotUnreadable(source) }
            return try result.get()
        }
    }

    private static func snapshotRevision(_ file: URL) throws -> Int64 {
        var database: OpaquePointer?
        let opened = sqlite3_open_v2(file.path, &database, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(database) }
        func failure() -> KeepsLibraryDatabase.DatabaseError {
            .init(message: "Cloud snapshot revision at \(file.path): \(database.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open SQLite")")
        }
        guard opened == SQLITE_OK else { throw failure() }
        var statement: OpaquePointer?
        let sql = "SELECT value FROM metadata WHERE key='revision' AND NOT EXISTS (SELECT 1 FROM metadata WHERE key='sync_checkpoint')"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else {
            if result != SQLITE_DONE { throw failure() }
            throw ReplicaError.snapshotUnreadable(file)
        }
        guard let bytes = sqlite3_column_text(statement, 0), let revision = Int64(String(cString: bytes)) else {
            throw ReplicaError.snapshotUnreadable(file)
        }
        return revision
    }

    private enum ReplicaError: Error {
        case downloadTimedOut(URL)
        case snapshotUnreadable(URL)
    }
}

/// NSMetadataQuery supports starting on its operation queue; keep its results off the UI thread.
private final class CloudReplicaMetadata: @unchecked Sendable {
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "local.keeps.cloud-metadata"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    // All mutable state, including query creation and destruction, belongs to queue.
    private var query: NSMetadataQuery?
    private var observer: NSObjectProtocol?
    private var gathered = false

    static func urls(in root: URL, snapshotOnly: Bool) async throws -> Set<URL> {
        try await CloudReplicaMetadata().gather(root, snapshotOnly: snapshotOnly)
    }

    private func perform<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.addOperation {
                continuation.resume(with: Result { try autoreleasepool(invoking: body) })
            }
        }
    }

    private func gather(_ root: URL, snapshotOnly: Bool) async throws -> Set<URL> {
        do {
            try Task.checkCancellation()
            try await perform { [self] in
                let query = NSMetadataQuery()
                self.query = query
                query.searchScopes = [NSMetadataQueryUbiquitousDataScope]
                query.predicate = NSPredicate(format: "%K CONTAINS %@", NSMetadataItemPathKey, "/" + root.lastPathComponent + "/")
                if snapshotOnly {
                    query.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                        query.predicate!, NSPredicate(format: "%K == %@", NSMetadataItemFSNameKey, "catalog.snapshot")
                    ])
                }
                query.operationQueue = queue
                observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering,
                                                                   object: query, queue: queue) { [weak self] _ in
                    self?.gathered = true
                }
                guard query.start() else { throw MetadataError.unavailable }
            }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(30))
            while try await perform({ [self] in !gathered }) {
                try Task.checkCancellation()
                guard clock.now < deadline else { throw MetadataError.timedOut }
                try await Task.sleep(for: .milliseconds(100))
            }
            let count = try await perform { [self] in
                query!.disableUpdates()
                return query!.resultCount
            }
            var result: Set<URL> = []
            for start in stride(from: 0, to: count, by: 256) {
                try Task.checkCancellation()
                let paths = try await perform { [self] in
                    (start..<min(start + 256, count)).compactMap { index in
                        (query!.result(at: index) as? NSMetadataItem)?.value(forAttribute: NSMetadataItemPathKey) as? String
                    }
                }
                // Do not retain provider-backed URLs for the entire cloud inventory.
                for path in paths { result.insert(URL(fileURLWithPath: path, isDirectory: false)) }
            }
            await cleanup()
            try Task.checkCancellation()
            return result
        } catch {
            await cleanup()
            throw error
        }
    }

    private func cleanup() async {
        await withCheckedContinuation { continuation in
            queue.addOperation { [self] in
                autoreleasepool {
                    query?.stop()
                    if let observer { NotificationCenter.default.removeObserver(observer) }
                    observer = nil
                    query = nil
                }
                continuation.resume()
            }
        }
    }

    private enum MetadataError: Error { case unavailable, timedOut }
}

/// Report only completed catalog checks and file work, never elapsed waiting time.
private actor ReplicaWorkProgress {
    let total: Int64
    let callback: (@Sendable (Int64, Int64) async -> Void)?
    private var completed: Int64 = 0
    private let clock = ContinuousClock()
    private var lastReport = ContinuousClock.now

    init(total: Int64, callback: (@Sendable (Int64, Int64) async -> Void)?) {
        self.total = total
        self.callback = callback
    }

    func advance(_ units: Int64, force: Bool = false) async {
        completed += units
        if force || lastReport.duration(to: clock.now) >= .seconds(1) { await report() }
    }

    func report() async {
        lastReport = clock.now
        await callback?(completed, total)
    }
}
