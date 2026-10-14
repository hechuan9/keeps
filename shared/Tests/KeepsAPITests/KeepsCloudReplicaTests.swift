import Foundation
import Testing
@testable import KeepsAPI

private actor CloudReplicaProgress {
    var messages: [String] = []
    var work: [(Int64, Int64)] = []
    func appendWork(_ done: Int64, _ total: Int64) { work.append((done, total)) }
    func append(_ message: String) { messages.append(message) }
}

struct KeepsCloudReplicaTests {
    private let configuration = KeepsConfiguration(baseURL: URL(string: "https://cloud-replica.invalid")!,
                                                    libraryID: "main", accessCredential: "old-private-credential")
    private let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aEl0AAAAASUVORK5CYII=")!

    private func asset(_ number: Int, trashed: Bool = false) -> KeepsAsset {
        var asset = KeepsAsset(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!,
            captureTime: "2026-01-01", cameraMake: "", cameraModel: "", lensModel: "", originalFilename: "photo.jpg",
            contentFingerprint: "c", metadataFingerprint: "m", rating: 0, flagState: "none", colorLabel: nil,
            tags: [], createdAt: "2026-01-01", updatedAt: "2026-01-01", trashed: trashed, preview: nil,
            paths: ["/private/photo\(number).jpg"])
        asset.thumbnail = KeepsPreview(downloadURL: URL(string: "https://cloud-replica.invalid/thumb/\(number)")!,
                                       width: 1, height: 1, version: "1")
        return asset
    }

    private func cache(_ root: URL) -> PreviewCache {
        PreviewCache(directory: root, diskLimit: Int.max, role: .thumbnail)
    }

    private func key(_ asset: KeepsAsset) -> String {
        PreviewCache.key(assetID: asset.id, preview: asset.thumbnail!, configuration: configuration, role: .thumbnail)
    }

    private func populate(_ root: URL, assets: [KeepsAsset], revision: Int64 = 42) throws {
        let database = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: root)
        try database.beginSync()
        try database.ingest(assets)
        try database.replaceHiddenDirectories(["/private"])
        try database.completeSync(revision: revision, isStable: true)
    }

    @Test func immutableSnapshotBrowsingDoesNotCreateAnotherCatalogOrWriteJournals() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original")
        try populate(original, assets: (1...205).map { asset($0) })
        let source = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: original)
        let snapshot = root.appendingPathComponent("catalog.snapshot")
        try source.exportSnapshot(to: snapshot)
        let originalBytes = try Data(contentsOf: snapshot)
        let originalFiles = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let reader = try KeepsLibraryDatabase(snapshotURL: snapshot)
        try populate(original, assets: [asset(999)], revision: 43)
        var query = KeepsAssetQuery()
        query.showHidden = true
        query.limit = 100
        var boundary: KeepsAsset?
        var ids: [UUID] = []
        repeat {
            let page = try reader.assets(query: query, olderThan: boundary)
            #expect(page.revision == 42)
            ids.append(contentsOf: page.items.map(\.id))
            boundary = page.nextCursor == nil ? nil : page.items.last
        } while boundary != nil
        #expect(ids.count == 205 && Set(ids).count == 205)
        #expect(throws: KeepsLibraryDatabase.DatabaseError.self) { try reader.update(asset(999)) }
        #expect(try Data(contentsOf: snapshot) == originalBytes)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(Set(files) == Set(originalFiles))

    }

    @Test func catalogOnlyRestoreSkipsAvailableCloudImagesAndCacheInventory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original"), cloud = root.appendingPathComponent("cloud")
        let value = asset(1)
        try populate(original, assets: [value])
        let source = cache(root.appendingPathComponent("source-cache"))
        try await source.store(image, key: key(value))
        try await KeepsCloudReplica(cloudRoot: cloud, cache: source).backup(configuration: configuration, databaseRoot: original)
        // A file at the cache directory makes any attempted cache inventory fail.
        let unavailableCache = root.appendingPathComponent("unavailable-cache")
        try Data().write(to: unavailableCache)
        let target = cache(unavailableCache)
        let destination = root.appendingPathComponent("restored")
        let recorder = CloudReplicaProgress()
        #expect(try await KeepsCloudReplica(cloudRoot: cloud, cache: target).restore(
            configuration: configuration, databaseRoot: destination, includeThumbnails: false,
            workProgress: { await recorder.appendWork($0, $1) }))
        let database = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: destination)
        #expect(try database.revision == 42)
        var query = KeepsAssetQuery()
        query.showHidden = true
        #expect(try database.timeline(query: query).map(\.id) == [value.id])
        #expect(await recorder.work.last?.0 == 1)
        #expect(await recorder.work.last?.1 == 1)
    }

    @Test func workProgressCountsMissingExistingAndAbsentThumbnailChecks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original")
        let cloud = root.appendingPathComponent("cloud")
        var noThumbnail = asset(3)
        noThumbnail.thumbnail = nil
        try populate(original, assets: [asset(1), asset(2), noThumbnail, asset(4, trashed: true)])
        let sourceCache = cache(root.appendingPathComponent("cache"))
        try await sourceCache.store(image, key: key(asset(1)))
        let replica = KeepsCloudReplica(cloudRoot: cloud, cache: sourceCache)
        for _ in 0..<2 {
            let recorder = CloudReplicaProgress()
            try await replica.backup(configuration: configuration, databaseRoot: original,
                workProgress: { await recorder.appendWork($0, $1) })
            let work = await recorder.work
            #expect(work.first?.0 == 1)
            #expect(work.last?.0 == 9 && work.last?.1 == 9)
            #expect(zip(work, work.dropFirst()).allSatisfy { $0.0 <= $1.0 && $0.1 == $1.1 })
        }
        let recorder = CloudReplicaProgress()
        let destination = root.appendingPathComponent("destination")
        let restored = try await replica.restore(configuration: configuration, databaseRoot: destination,
            workProgress: { await recorder.appendWork($0, $1) })
        #expect(restored)
        let work = await recorder.work
        #expect(work.last?.0 == 9 && work.last?.1 == 9)
        #expect(zip(work, work.dropFirst()).allSatisfy { $0.0 <= $1.0 && $0.1 == $1.1 })
    }

    @Test func snapshotAndThumbnailRoundTripIncludesHiddenTrashAndChangedCredential() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original")
        let cloud = root.appendingPathComponent("cloud")
        let destination = root.appendingPathComponent("restored")
        let values = (1...105).map { asset($0) } + [asset(106, trashed: true)]
        try populate(original, assets: values)
        let localCache = cache(root.appendingPathComponent("cache"))
        for asset in values { try await localCache.store(image, key: key(asset)) }
        let recorder = CloudReplicaProgress()
        try await KeepsCloudReplica(cloudRoot: cloud, cache: localCache).backup(configuration: configuration,
                databaseRoot: original) { await recorder.append($0) }
        let messages = await recorder.messages
        #expect(messages.last?.contains("交给 iCloud 同步") == true)
        #expect(messages.allSatisfy { !$0.contains("已上传") })
        let namespaces = try FileManager.default.contentsOfDirectory(at: cloud, includingPropertiesForKeys: nil)
        #expect(namespaces.count == 1 && namespaces[0].lastPathComponent.count == 64)
        let snapshot = namespaces[0].appendingPathComponent("catalog.snapshot")
        #expect(FileManager.default.fileExists(atPath: snapshot.path))
        #expect(!String(decoding: try Data(contentsOf: snapshot), as: UTF8.self).contains("old-private-credential"))
        var changed = configuration
        changed.accessCredential = "new-private-credential"
        let newCache = cache(root.appendingPathComponent("new-cache"))
        #expect(try await KeepsCloudReplica(cloudRoot: cloud, cache: newCache).restore(configuration: changed,
                                                                                   databaseRoot: destination))
        let restored = try KeepsLibraryDatabase(configuration: changed, rootDirectory: destination)
        #expect(try restored.revision == 42)
        var query = KeepsAssetQuery(); query.showHidden = true; query.limit = 200
        #expect(try restored.assets(query: query).items.count == 105)
        query.trashed = true
        #expect(try restored.assets(query: query).items.map(\.id) == [values.last!.id])
        #expect(try await newCache.cachedKeys() == Set(values.map(key)))
    }

    @Test func browseThumbnailsRoundTripAndMissingBrowseRemainsAbsent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cloud = root.appendingPathComponent("cloud")
        var first = asset(1)
        first.browseThumbnail = KeepsPreview(downloadURL: URL(string: "https://cloud-replica.invalid/browse/1")!, width: 1, height: 1, version: "browse-1")
        var second = asset(2)
        second.browseThumbnail = KeepsPreview(downloadURL: URL(string: "https://cloud-replica.invalid/browse/2")!, width: 1, height: 1, version: "browse-1")
        let database = root.appendingPathComponent("source")
        try populate(database, assets: [first, second])
        let browse = PreviewCache(directory: root.appendingPathComponent("browse"), role: .browse)
        let firstKey = PreviewCache.key(assetID: first.id, preview: first.browseThumbnail!, configuration: configuration, role: .browse)
        try await browse.store(image, key: firstKey)
        try await KeepsCloudReplica(cloudRoot: cloud, cache: cache(root.appendingPathComponent("preview")), browsingCache: browse)
            .backup(configuration: configuration, databaseRoot: database)
        let restoredBrowse = PreviewCache(directory: root.appendingPathComponent("restored-browse"), role: .browse)
        #expect(try await KeepsCloudReplica(cloudRoot: cloud, cache: cache(root.appendingPathComponent("restored-preview")), browsingCache: restoredBrowse)
            .restore(configuration: configuration, databaseRoot: root.appendingPathComponent("restored")))
        #expect(try await restoredBrowse.cachedKeys() == [firstKey])
    }

    @Test func missingCloudThumbnailsDoNotPreventDatabaseRecoveryOrOverwriteExistingLocalCatalog() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original"), cloud = root.appendingPathComponent("cloud")
        let destination = root.appendingPathComponent("destination")
        try populate(original, assets: [asset(1), asset(2)])
        let sourceCache = cache(root.appendingPathComponent("cache"))
        try await sourceCache.store(image, key: key(asset(1)))
        try await KeepsCloudReplica(cloudRoot: cloud, cache: sourceCache).backup(configuration: configuration, databaseRoot: original)
        let targetCache = cache(root.appendingPathComponent("target-cache"))
        let replica = KeepsCloudReplica(cloudRoot: cloud, cache: targetCache)
        #expect(try await replica.restore(configuration: configuration, databaseRoot: destination))
        #expect(try await targetCache.cachedKeys() == [key(asset(1))])
        let database = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: destination)
        try database.update(asset(3))
        #expect(try await replica.restore(configuration: configuration, databaseRoot: destination) == false)
        var query = KeepsAssetQuery(); query.showHidden = true
        #expect(try database.assets(query: query).total == 3)
    }

    @Test func immutableThumbnailsAreNotRestagedAndLibrariesStaySeparate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original"), cloud = root.appendingPathComponent("cloud")
        try populate(original, assets: [asset(1), asset(2)])
        let sourceCache = cache(root.appendingPathComponent("cache"))
        try await sourceCache.store(image, key: key(asset(1)))
        let replica = KeepsCloudReplica(cloudRoot: cloud, cache: sourceCache)
        try await replica.backup(configuration: configuration, databaseRoot: original)
        let namespace = try #require(FileManager.default.contentsOfDirectory(at: cloud, includingPropertiesForKeys: nil).first)
        let lateKey = key(asset(2))
        let key = key(asset(1))
        let staged = namespace.appendingPathComponent("thumbnails/\(key.prefix(2))/\(key)")
        let oldDate = Date(timeIntervalSince1970: 1000)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: staged.path)
        try await sourceCache.store(image, key: lateKey)
        try await replica.backup(configuration: configuration, databaseRoot: original)
        #expect(FileManager.default.fileExists(atPath: namespace.appendingPathComponent("thumbnails/\(lateKey.prefix(2))/\(lateKey)").path))
        #expect(try FileManager.default.attributesOfItem(atPath: staged.path)[.modificationDate] as? Date == oldDate)
        var other = configuration; other.libraryID = "another"
        #expect(try await replica.restore(configuration: other, databaseRoot: root.appendingPathComponent("other")) == false)
        other = configuration; other.baseURL = URL(string: "https://another.invalid")!
        #expect(try await replica.restore(configuration: other, databaseRoot: root.appendingPathComponent("other")) == false)
    }

    @Test func brokenOptionalCloudThumbnailDoesNotBlockDatabaseOrOtherImages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original"), cloud = root.appendingPathComponent("cloud")
        try populate(original, assets: [asset(1), asset(2)])
        let source = cache(root.appendingPathComponent("source-cache"))
        for value in [asset(1), asset(2)] { try await source.store(image, key: key(value)) }
        try await KeepsCloudReplica(cloudRoot: cloud, cache: source).backup(configuration: configuration, databaseRoot: original)
        let namespace = try #require(FileManager.default.contentsOfDirectory(at: cloud, includingPropertiesForKeys: nil).first)
        let brokenKey = key(asset(1))
        try Data("invalid image".utf8).write(to: namespace.appendingPathComponent("thumbnails/\(brokenKey.prefix(2))/\(brokenKey)"))
        let destination = root.appendingPathComponent("destination")
        let target = cache(root.appendingPathComponent("target-cache"))
        let replica = KeepsCloudReplica(cloudRoot: cloud, cache: target)
        let paused = Task {
            try await replica.restore(configuration: configuration, databaseRoot: destination,
                workProgress: { done, total in
                    if done == total { withUnsafeCurrentTask { $0?.cancel() } }
                })
        }
        await #expect(throws: CancellationError.self) { _ = try await paused.value }
        #expect(try KeepsLibraryDatabase(configuration: configuration, rootDirectory: destination).revision == nil)
        let keptImage = try #require(try await target.cachedFileURL(forKey: key(asset(2))))
        let keptDate = try keptImage.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        #expect(try await replica.restore(configuration: configuration, databaseRoot: destination))
        #expect(try keptImage.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == keptDate)
        #expect(try KeepsLibraryDatabase(configuration: configuration, rootDirectory: destination).revision == 42)
        #expect(try await target.containsCachedKey(key(asset(2))))
    }

    @Test(arguments: [false, true]) func unstableCatalogIsNeverStaged(withCheckpoint: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original"), cloud = root.appendingPathComponent("cloud")
        let database = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: original)
        try database.ingest([asset(1)])
        if withCheckpoint {
            try database.completeSync(revision: 42, isStable: true)
            try database.ingest([asset(2)], checkpoint: .init(revision: 43, stable: false))
        }
        let replica = KeepsCloudReplica(cloudRoot: cloud, cache: cache(root.appendingPathComponent("cache")))
        await #expect(throws: KeepsLibraryDatabase.DatabaseError.self) {
            try await replica.backup(configuration: configuration, databaseRoot: original)
        }
        #expect(!FileManager.default.fileExists(atPath: cloud.path))
    }
    @Test func catalogVersionOnlyAdvancesAndEqualRevisionDoesNotRewrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original"), cloud = root.appendingPathComponent("cloud")
        let replica = KeepsCloudReplica(cloudRoot: cloud, cache: cache(root.appendingPathComponent("cache")))
        try populate(original, assets: [asset(1)], revision: 42)
        try await replica.backup(configuration: configuration, databaseRoot: original)
        let namespace = try #require(FileManager.default.contentsOfDirectory(at: cloud, includingPropertiesForKeys: nil).first)
        let snapshot = namespace.appendingPathComponent("catalog.snapshot")
        let unchangedDate = Date(timeIntervalSince1970: 1000)
        try FileManager.default.setAttributes([.modificationDate: unchangedDate], ofItemAtPath: snapshot.path)
        try await replica.backup(configuration: configuration, databaseRoot: original)
        #expect(try FileManager.default.attributesOfItem(atPath: snapshot.path)[.modificationDate] as? Date == unchangedDate)

        try populate(original, assets: [asset(1), asset(2)], revision: 43)
        try await replica.backup(configuration: configuration, databaseRoot: original)
        #expect(try FileManager.default.attributesOfItem(atPath: snapshot.path)[.modificationDate] as? Date != unchangedDate)
        let newerDate = Date(timeIntervalSince1970: 2000)
        try FileManager.default.setAttributes([.modificationDate: newerDate], ofItemAtPath: snapshot.path)
        try populate(original, assets: [asset(3)], revision: 41)
        try await replica.backup(configuration: configuration, databaseRoot: original)
        #expect(try FileManager.default.attributesOfItem(atPath: snapshot.path)[.modificationDate] as? Date == newerDate)
        let restored = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: root.appendingPathComponent("restored"))
        #expect(try restored.restoreSnapshot(from: snapshot))
        #expect(try restored.revision == 43)
        var query = KeepsAssetQuery(); query.showHidden = true
        #expect(try restored.assets(query: query).items.map(\.id) == [asset(1).id, asset(2).id])
    }

    @Test func unreadableCloudCatalogIsPreservedInsteadOfOverwritten() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original"), cloud = root.appendingPathComponent("cloud")
        let replica = KeepsCloudReplica(cloudRoot: cloud, cache: cache(root.appendingPathComponent("cache")))
        try populate(original, assets: [asset(1)])
        try await replica.backup(configuration: configuration, databaseRoot: original)
        let namespace = try #require(FileManager.default.contentsOfDirectory(at: cloud, includingPropertiesForKeys: nil).first)
        let snapshot = namespace.appendingPathComponent("catalog.snapshot")
        let unreadable = Data("not a sqlite database".utf8)
        try unreadable.write(to: snapshot)
        await #expect(throws: KeepsLibraryDatabase.DatabaseError.self) {
            try await replica.backup(configuration: configuration, databaseRoot: original)
        }
        #expect(try Data(contentsOf: snapshot) == unreadable)
    }

}
