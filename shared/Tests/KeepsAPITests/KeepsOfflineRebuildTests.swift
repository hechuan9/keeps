import Foundation
import CryptoKit
import Darwin
import Testing
@testable import KeepsAPI

@Suite(.serialized)
struct KeepsOfflineRebuildTests {
    private let configuration = KeepsConfiguration(baseURL: URL(string: "https://nas.invalid")!, libraryID: "main")
    private func tar(_ entries: [(String, Data)], type: UInt8 = 48) -> Data {
        var result = Data()
        for (name, body) in entries {
            var header = Data(repeating: 0, count: 512)
            func put(_ text: String, _ index: Int) { header.replaceSubrange(index..<(index + text.utf8.count), with: text.utf8) }
            put(name, 0); put(String(format: "%011o", body.count), 124)
            header[156] = type; put("ustar", 257); put("00", 263)
            for i in 148..<156 { header[i] = 32 }
            let sum = header.reduce(0) { $0 + Int($1) }
            put(String(format: "%06o", sum), 148); header[154] = 0; header[155] = 32
            result.append(header); result.append(body)
            result.append(Data(repeating: 0, count: (512 - body.count % 512) % 512))
        }
        result.append(Data(repeating: 0, count: 1024)); return result
    }
    private func fixture(_ root: URL) throws -> [(String, Data)] {
        let db = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: root.appendingPathComponent("source"))
        try db.completeSync(revision: 42, isStable: true)
        let snapshot = root.appendingPathComponent("source.sqlite")
        try db.exportSnapshot(to: snapshot)
        let manifest = KeepsOfflineManifest(formatVersion: 1, libraryID: "main", revision: 42, assetCount: 0, thumbnailCount: 0, missingThumbnailCount: 0)
        return [("manifest.json", try JSONEncoder().encode(manifest)), ("catalog.sqlite", try Data(contentsOf: snapshot))]
    }
    @Test func backgroundReceiptValidatesSystemResumedSuffixResponse() throws {
        let receipt = OfflineDownloadReceipt(offset: 0, total: 100, digest: "digest")
        func response(_ status: Int, _ range: String, etag: String = "digest") -> HTTPURLResponse {
            HTTPURLResponse(url: configuration.baseURL, statusCode: status, httpVersion: nil,
                            headerFields: ["ETag": "\"\(etag)\"", "Content-Range": range, "Content-Length": "40"])!
        }
        // URLSession's temporary file includes earlier received bytes even when its final response is a suffix.
        try receipt.validate(response(206, "bytes 60-99/100"), downloadedBytes: 100)
        #expect(throws: URLError.self) { try receipt.validate(response(206, "bytes 60-99/101"), downloadedBytes: 100) }
        #expect(throws: URLError.self) { try receipt.validate(response(206, "bytes 60-99/100", etag: "other"), downloadedBytes: 100) }
        #expect(throws: URLError.self) { try receipt.validate(response(206, "bytes 60-99/100"), downloadedBytes: 40) }
        let prefix = OfflineDownloadReceipt(offset: 20, total: 100, digest: "digest")
        try prefix.validate(response(206, "bytes 60-99/100"), downloadedBytes: 80)
        #expect(throws: URLError.self) { try prefix.validate(response(200, ""), downloadedBytes: 80) }
    }

    @Test func backgroundFragmentMergeRecoversInterruptedAppendWithoutDuplicateBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let archive = root.appendingPathComponent("bundle.tar")
        let part = root.appendingPathComponent("download.part")
        let receipt = OfflineDownloadReceipt(offset: 4, total: 10, digest: "unused")
        try Data("0123456".utf8).write(to: archive)
        try Data("456789".utf8).write(to: part)
        try receipt.merge(in: root)
        #expect(try Data(contentsOf: archive) == Data("0123456789".utf8))
        #expect(!FileManager.default.fileExists(atPath: part.path))
        // A crash after the append but before fragment removal is also recoverable.
        try Data("456789".utf8).write(to: part)
        try receipt.merge(in: root)
        #expect(try Data(contentsOf: archive) == Data("0123456789".utf8))
        try Data("123".utf8).write(to: part)
        #expect(throws: URLError.self) { try receipt.merge(in: root) }
        #expect(try Data(contentsOf: archive) == Data("0123456789".utf8))
    }

    @Test func completedBackgroundFileReplacesOnlyStagedArchive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let archive = root.appendingPathComponent("bundle.tar")
        let part = root.appendingPathComponent("download.part")
        try Data("old".utf8).write(to: archive)
        try Data("new data".utf8).write(to: part)
        try OfflineDownloadReceipt(offset: 0, total: 8, digest: "unused").merge(in: root)
        #expect(try Data(contentsOf: archive) == Data("new data".utf8))
        #expect(!FileManager.default.fileExists(atPath: part.path))
    }

    @Test func singleTransferResumesOnlyAfterInterruptionAndReusesServerJob() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = tar(try fixture(root))
        OfflineBundleProtocol.state.configure(archive)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OfflineBundleProtocol.self]
        let session = URLSession(configuration: config)
        let service = KeepsOfflineRebuild(session: session)
        let destination = root.appendingPathComponent("destination")
        await #expect(throws: (any Error).self) {
            _ = try await service.run(configuration: configuration, databaseRoot: destination)
        }
        let result = try await service.run(configuration: configuration, databaseRoot: destination)
        #expect(result.revision == 42)
        #expect(result.browseThumbnailCount == nil)
        let requests = OfflineBundleProtocol.state.requests
        #expect(requests.filter { $0.httpMethod == "POST" }.count == 1)
        let downloads = requests.filter { $0.url!.path.hasSuffix("download") }
        #expect(downloads.count == 2)
        #expect(downloads.first?.value(forHTTPHeaderField: "Range") == nil)
        #expect(downloads.last?.value(forHTTPHeaderField: "Range") == "bytes=1024-")
        let reader = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: destination)
        #expect(try reader.revision == 42)
    }

    @Test func installsCompleteSnapshotAndKeepsExistingReaderConnection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let entries = try fixture(root)
        let destination = root.appendingPathComponent("destination")
        let reader = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: destination)
        try reader.completeSync(revision: 1, isStable: true)
        let archive = root.appendingPathComponent("test.tar")
        try tar(entries).write(to: archive)
        let service = KeepsOfflineRebuild()
        let result = try await service.unpack(archive, root: root, configuration: configuration, databaseRoot: destination, progress: { _ in })
        #expect(result.revision == 42)
        #expect(try reader.revision == 42)
    }
    @Test func rejectsMalformedArchivesWithoutPublishingDatabase() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let entries = try fixture(root)
        let destination = root.appendingPathComponent("destination")
        let reader = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: destination)
        try reader.completeSync(revision: 7, isStable: true)
        let archive = root.appendingPathComponent("test.tar")
        let service = KeepsOfflineRebuild()
        let invalid = [tar(entries + [("../escape", Data())]), tar(entries, type: 50), tar(entries + [entries[0]]), tar(entries).dropLast(600)]
        for bytes in invalid {
            try reader.completeSync(revision: 7, isStable: true)
            try bytes.write(to: archive)
            await #expect(throws: (any Error).self) {
                _ = try await service.unpack(archive, root: root, configuration: configuration, databaseRoot: destination, progress: { _ in })
            }
            #expect(try reader.revision == 7)
        }
        #expect(!FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("escape").path))
    }
    @Test func optionalThumbnailFailureKeepsDatabaseAndExistingCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: root.appendingPathComponent("source"))
        let preview = KeepsPreview(downloadURL: URL(string: "https://nas.invalid/thumbnail")!, width: 1, height: 1, version: "v2")
        let asset = KeepsAsset(id: UUID(), captureTime: nil, cameraMake: "", cameraModel: "", lensModel: "", originalFilename: "test.jpg", contentFingerprint: "c", metadataFingerprint: "m", rating: 0, flagState: "none", colorLabel: nil, tags: [], createdAt: "2026-01-01", updatedAt: "2026-01-01", trashed: false, preview: nil, thumbnail: preview)
        try source.ingest([asset]); try source.completeSync(revision: 55, isStable: true)
        let snapshot = root.appendingPathComponent("snapshot.sqlite")
        try source.exportSnapshot(to: snapshot)
        let manifest = KeepsOfflineManifest(formatVersion: 1, libraryID: "main", revision: 55, assetCount: 1, thumbnailCount: 1, missingThumbnailCount: 0)
        let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aEl0AAAAASUVORK5CYII=")!
        let cache = PreviewCache(directory: root.appendingPathComponent("cache"), role: .thumbnail)
        let service = KeepsOfflineRebuild(cache: cache)
        let destination = root.appendingPathComponent("destination")
        let reader = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: destination)
        try reader.completeSync(revision: 7, isStable: true)
        let archive = root.appendingPathComponent("test.tar")
        let prefix = [("manifest.json", try JSONEncoder().encode(manifest)), ("catalog.sqlite", try Data(contentsOf: snapshot))]
        try tar(prefix + [("thumbnails/\(asset.id.uuidString).image", Data("broken".utf8))]).write(to: archive)
        let existingFile = root.appendingPathComponent("existing.png")
        try image.write(to: existingFile)
        let existingKey = String(repeating: "a", count: 64)
        try await cache.importCachedFile(from: existingFile, key: existingKey)
        _ = try await service.unpack(archive, root: root, configuration: configuration, databaseRoot: destination, progress: { _ in })
        #expect(try reader.revision == 55)
        #expect(try reader.assets(query: .init()).items.first?.id == asset.id)
        #expect(try await cache.cachedFileURL(forKey: existingKey) != nil)
        let missingKey = PreviewCache.key(assetID: asset.id, preview: preview, configuration: configuration, role: .thumbnail)
        #expect(try await cache.cachedFileURL(forKey: missingKey) == nil)
        try tar(prefix + [("thumbnails/\(asset.id.uuidString).image", image)]).write(to: archive)
        let blockedCacheFile = root.appendingPathComponent("cache").appendingPathComponent(missingKey)
        try FileManager.default.createDirectory(at: blockedCacheFile, withIntermediateDirectories: true)
        _ = try await service.unpack(archive, root: root, configuration: configuration, databaseRoot: destination, progress: { _ in })
        #expect(try reader.revision == 55)
        #expect(try await cache.cachedFileURL(forKey: existingKey) != nil)
        #expect(try await cache.cachedFileURL(forKey: missingKey) == nil)
        try FileManager.default.removeItem(at: blockedCacheFile)
        let freshDestination = root.appendingPathComponent("paused-destination")
        let paused = Task {
            try await service.unpack(archive, root: root, configuration: configuration, databaseRoot: freshDestination) { progress in
                if progress.message == "导入离线图库" { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { _ = try await paused.value }
        #expect(try KeepsLibraryDatabase(configuration: configuration, rootDirectory: freshDestination).revision == nil)
        let cachedFile = try #require(try await cache.cachedFileURL(forKey: missingKey))
        let cachedDate = try cachedFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        #expect(FileManager.default.fileExists(atPath: archive.path))
        _ = try await service.unpack(archive, root: root, configuration: configuration, databaseRoot: freshDestination, progress: { _ in })
        #expect(try KeepsLibraryDatabase(configuration: configuration, rootDirectory: freshDestination).revision == 55)
        #expect(try cachedFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == cachedDate)
        _ = try await service.unpack(archive, root: root, configuration: configuration, databaseRoot: destination, progress: { _ in })
        #expect(try reader.revision == 55)
        let key = PreviewCache.key(assetID: asset.id, preview: preview, configuration: configuration, role: .thumbnail)
        #expect(try await cache.cachedFileURL(forKey: key) != nil)
        #expect(try reader.assets(query: .init()).items.first?.id == asset.id)
    }

    @Test func browseBundleImportsBothRolesAndRejectsWrongCounts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: root.appendingPathComponent("source"))
        let preview = KeepsPreview(downloadURL: URL(string: "https://nas.invalid/thumbnail")!, width: 1, height: 1, version: "v2")
        var asset = KeepsAsset(id: UUID(), captureTime: nil, cameraMake: "", cameraModel: "", lensModel: "", originalFilename: "test.jpg", contentFingerprint: "c", metadataFingerprint: "m", rating: 0, flagState: "none", colorLabel: nil, tags: [], createdAt: "2026-01-01", updatedAt: "2026-01-01", trashed: false, preview: nil, thumbnail: preview)
        asset.browseThumbnail = preview
        try source.ingest([asset]); try source.completeSync(revision: 55, isStable: true)
        let snapshot = root.appendingPathComponent("snapshot.sqlite")
        try source.exportSnapshot(to: snapshot)
        var manifest = KeepsOfflineManifest(formatVersion: 1, libraryID: "main", revision: 55, assetCount: 1, thumbnailCount: 1, missingThumbnailCount: 0, browseThumbnailCount: 1, missingBrowseThumbnailCount: 0)
        let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aEl0AAAAASUVORK5CYII=")!
        let previewCache = PreviewCache(directory: root.appendingPathComponent("preview"), role: .thumbnail)
        let browseCache = PreviewCache(directory: root.appendingPathComponent("browse"), role: .browse)
        let service = KeepsOfflineRebuild(cache: previewCache, browsingCache: browseCache)
        let archive = root.appendingPathComponent("bundle.tar")
        let entries = [("catalog.sqlite", try Data(contentsOf: snapshot)), ("thumbnails/\(asset.id.uuidString).image", image), ("browse-thumbnails/\(asset.id.uuidString).image", image)]
        try tar([("manifest.json", try JSONEncoder().encode(manifest))] + entries).write(to: archive)
        let result = try await service.unpack(archive, root: root, configuration: configuration, databaseRoot: root.appendingPathComponent("target"), progress: { _ in })
        #expect(result.browseThumbnailCount == 1)
        #expect(try await previewCache.cachedKeys().count == 1)
        #expect(try await browseCache.cachedKeys().count == 1)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("image.tmp").path))
        let thumbnailKey = PreviewCache.key(assetID: asset.id, preview: preview, configuration: configuration, role: .thumbnail)
        let browseKey = PreviewCache.key(assetID: asset.id, preview: preview, configuration: configuration, role: .browse)
        let thumbnailFile = try #require(try await previewCache.cachedFileURL(forKey: thumbnailKey))
        let browseFile = try #require(try await browseCache.cachedFileURL(forKey: browseKey))
        let oldDate = Date(timeIntervalSince1970: 1_000)
        for file in [thumbnailFile, browseFile] {
            #expect(try autoreleasepool { try Data(contentsOf: file) == image })
            try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: file.path)
        }
        _ = try await service.unpack(archive, root: root, configuration: configuration, databaseRoot: root.appendingPathComponent("target"), progress: { _ in })
        for file in [thumbnailFile, browseFile] {
            #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date == oldDate)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("image.tmp").path))
        manifest.browseThumbnailCount = 0; manifest.missingBrowseThumbnailCount = 1
        try tar([("manifest.json", try JSONEncoder().encode(manifest))] + entries).write(to: archive)
        let rejected = root.appendingPathComponent("rejected")
        await #expect(throws: (any Error).self) {
            _ = try await service.unpack(archive, root: root, configuration: configuration, databaseRoot: rejected, progress: { _ in })
        }
        #expect(try KeepsLibraryDatabase(configuration: configuration, rootDirectory: rejected).revision == nil)
        try tar([("manifest.json", try JSONEncoder().encode(manifest))] + entries.dropLast()).write(to: archive)
        let missing = try await service.unpack(archive, root: root, configuration: configuration, databaseRoot: rejected, progress: { _ in })
        #expect(missing.missingBrowseThumbnailCount == 1)
    }

    @Test func bulkImportCancellationAndRepeatedRecoveryReuseImages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let count = Int(ProcessInfo.processInfo.environment["KEEPS_IMPORT_STRESS_COUNT"] ?? "128")!
        let source = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: root.appendingPathComponent("source"))
        let descriptor = KeepsPreview(downloadURL: URL(string: "https://nas.invalid/image")!, width: 1, height: 1, version: "stress")
        let assets = (0..<count).map { index in
            var asset = KeepsAsset(id: UUID(), captureTime: nil, cameraMake: "", cameraModel: "", lensModel: "", originalFilename: "sample-\(index).jpg", contentFingerprint: "c", metadataFingerprint: "m", rating: 0, flagState: "none", colorLabel: nil, tags: [], createdAt: "2026-01-01", updatedAt: "2026-01-01", trashed: false, preview: nil, thumbnail: descriptor)
            asset.browseThumbnail = descriptor
            return asset
        }
        try source.ingest(assets)
        try source.completeSync(revision: 71, isStable: true)
        let snapshot = root.appendingPathComponent("source.sqlite")
        try source.exportSnapshot(to: snapshot)
        let manifest = KeepsOfflineManifest(formatVersion: 1, libraryID: "main", revision: 71, assetCount: count, thumbnailCount: count, missingThumbnailCount: 0, browseThumbnailCount: count, missingBrowseThumbnailCount: 0)
        var image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aEl0AAAAASUVORK5CYII=")!
        // Padding exercises realistic transfer volume without retaining decoded photo fixtures.
        image.append(Data(repeating: 0, count: 64 * 1024 - image.count))
        let archive = root.appendingPathComponent("bundle.tar")
        try Data().write(to: archive)
        let output = try FileHandle(forWritingTo: archive)
        try output.write(contentsOf: tar([("manifest.json", try JSONEncoder().encode(manifest)), ("catalog.sqlite", try Data(contentsOf: snapshot))]).dropLast(1024))
        for asset in assets {
            try output.write(contentsOf: tar([("thumbnails/\(asset.id.uuidString).image", image), ("browse-thumbnails/\(asset.id.uuidString).image", image)]).dropLast(1024))
        }
        try output.write(contentsOf: Data(repeating: 0, count: 1024))
        try output.close()
        let thumbnail = PreviewCache(directory: root.appendingPathComponent("thumbnail"), diskLimit: Int.max, role: .thumbnail)
        let browse = PreviewCache(directory: root.appendingPathComponent("browse"), diskLimit: Int.max, role: .browse)
        let service = KeepsOfflineRebuild(cache: thumbnail, browsingCache: browse)
        let destination = root.appendingPathComponent("destination")
        let database = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: destination)
        try database.completeSync(revision: 7, isStable: true)
        let cancelled = Task {
            try await service.unpack(archive, root: root, configuration: configuration, databaseRoot: destination) { update in
                if update.message == "导入离线图库" { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
        #expect(try database.revision == 7)
        let oldDate = Date(timeIntervalSince1970: 1_000)
        var baselineUsage = rusage()
        getrusage(RUSAGE_SELF, &baselineUsage)
        for pass in 0..<3 {
            _ = try await service.unpack(archive, root: root, configuration: configuration, databaseRoot: destination, progress: { _ in })
            var importedUsage = rusage()
            getrusage(RUSAGE_SELF, &importedUsage)
            print("BULK IMPORT MEMORY pass=\(pass) peakResidentBytes=\(importedUsage.ru_maxrss)")
            #expect(try database.assets(query: .init()).total == count)
            #expect(try database.revision == 71)
            for (role, cache) in [(KeepsMediaRole.thumbnail, thumbnail), (.browse, browse)] {
                #expect(try await cache.cachedKeys().count == count)
                for asset in assets {
                    let key = PreviewCache.key(assetID: asset.id, preview: descriptor, configuration: configuration, role: role)
                    let file = try #require(try await cache.cachedFileURL(forKey: key))
                    #expect(try autoreleasepool { try Data(contentsOf: file) == image })
                    if pass == 0 { try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: file.path) }
                    else { #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date == oldDate) }
                }
            }
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("image.tmp").path))
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            print("BULK MEMORY pass=\(pass) peakResidentBytes=\(usage.ru_maxrss)")
        }
        if ProcessInfo.processInfo.environment["KEEPS_IMPORT_STRESS_COUNT"] != nil {
            var finalUsage = rusage()
            getrusage(RUSAGE_SELF, &finalUsage)
            #expect(finalUsage.ru_maxrss - baselineUsage.ru_maxrss < max(64 * 1024 * 1024, count * image.count))
        }
        print("BULK IMPORT PASS assets=\(count) imageBytes=\(count * 2 * image.count) repeatedPasses=3 cancellation=verified")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["KEEPS_SYNC_TEST_EXPORT"] != nil))
    func rustIncrementalContractMatchesFreshFullSnapshot() async throws {
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KEEPS_SYNC_TEST_EXPORT"]!)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let initialReader = try OfflineContractManifest.read(source.appendingPathComponent("initial.tar"))
        let config = KeepsConfiguration(baseURL: URL(string: "https://fixture.invalid")!, libraryID: initialReader.libraryID)
        let service = KeepsOfflineRebuild()
        let incrementalRoot = root.appendingPathComponent("incremental")
        let fullRoot = root.appendingPathComponent("full")
        let initial = try await service.unpack(source.appendingPathComponent("initial.tar"), root: root, configuration: config, databaseRoot: incrementalRoot, progress: { _ in })
        let held = try KeepsLibraryDatabase(configuration: config, rootDirectory: incrementalRoot)
        let delta = try await service.unpack(source.appendingPathComponent("delta.tar"), root: root, configuration: config, databaseRoot: incrementalRoot, progress: { _ in })
        let full = try await service.unpack(source.appendingPathComponent("full.tar"), root: root, configuration: config, databaseRoot: fullRoot, progress: { _ in })
        let fresh = try KeepsLibraryDatabase(configuration: config, rootDirectory: fullRoot)
        #expect(initial.mode == "snapshot" && delta.mode == "delta" && full.mode == "snapshot")
        #expect(delta.fromRevision == initial.revision)
        #expect(try held.revision == fresh.revision)
        #expect(try held.generation == fresh.generation)
        for trashed in [false, true] {
            var query = KeepsAssetQuery(); query.showHidden = true; query.trashed = trashed; query.limit = 1000
            #expect(try held.assets(query: query).items == fresh.assets(query: query).items)
        }
        #expect(try held.hiddenDirectories() == fresh.hiddenDirectories())
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        #expect(try held.navigation().map { try encoder.encode($0) } == fresh.navigation().map { try encoder.encode($0) })
        #expect(initial.assetCount == 3 && delta.assetCount == 2 && full.assetCount == 2)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["KEEPS_OFFLINE_BUNDLE_FIXTURE"] != nil))
    func importsRustGeneratedContractFixture() async throws {
        let archive = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KEEPS_OFFLINE_BUNDLE_FIXTURE"]!)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configuration = KeepsConfiguration(baseURL: URL(string: "https://fixture.invalid")!, libraryID: "photos")
        let cache = PreviewCache(directory: root.appendingPathComponent("cache"), role: .thumbnail)
        let browseCache = PreviewCache(directory: root.appendingPathComponent("browse-cache"), role: .browse)
        let result = try await KeepsOfflineRebuild(cache: cache, browsingCache: browseCache).unpack(archive, root: root, configuration: configuration, databaseRoot: root.appendingPathComponent("db"), progress: { _ in })
        #expect(result.assetCount == 3 && result.thumbnailCount == 1 && result.missingThumbnailCount == 2)
        #expect(result.browseThumbnailCount == 1 && result.missingBrowseThumbnailCount == 2)
        #expect(try await browseCache.cachedKeys().count == 1)
        let db = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: root.appendingPathComponent("db"))
        #expect(try db.revision == 5)
        #expect(try db.assets(query: .init()).total == 1)
        var query = KeepsAssetQuery(); query.showHidden = true
        #expect(try db.assets(query: query).total == 2)
        query.trashed = true
        #expect(try db.assets(query: query).total == 1)
        #expect(try db.hiddenDirectories().count == 1)
        let navigation = try #require(try db.navigation())
        #expect(navigation.directories.count == 1)
        #expect(try db.navigation(path: navigation.directories[0].path) != nil)
        #expect(try await cache.cachedKeys().count == 1)
    }

    @Test func manifestMismatchRetainsPriorCatalog() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var entries = try fixture(root)
        let wrong = KeepsOfflineManifest(formatVersion: 1, libraryID: "main", revision: 99, assetCount: 0, thumbnailCount: 0, missingThumbnailCount: 0)
        entries[0].1 = try JSONEncoder().encode(wrong)
        let destination = root.appendingPathComponent("destination")
        let reader = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: destination)
        try reader.completeSync(revision: 7, isStable: true)
        let archive = root.appendingPathComponent("test.tar")
        try tar(entries).write(to: archive)
        await #expect(throws: (any Error).self) {
            _ = try await KeepsOfflineRebuild().unpack(archive, root: root, configuration: configuration, databaseRoot: destination, progress: { _ in })
        }
        #expect(try reader.revision == 7)
    }
}

private final class OfflineBundleProtocol: URLProtocol {
    private final class Delivery: @unchecked Sendable {
        let operation: () -> Void
        init(_ operation: @escaping () -> Void) { self.operation = operation }
    }
    final class State: @unchecked Sendable {
        let lock = NSLock()
        private var body = Data()
        private var recorded: [URLRequest] = []
        private var downloads = 0
        var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
        func configure(_ data: Data) { lock.lock(); defer { lock.unlock() }; body = data; recorded = []; downloads = 0 }
        func response(_ request: URLRequest) -> (Data, Int) {
            lock.lock(); defer { lock.unlock() }
            recorded.append(request)
            if request.url!.path.hasSuffix("download") { downloads += 1 }
            return (body, downloads)
        }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let (archive, downloadCount) = Self.state.response(request)
        let hash = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
        if !request.url!.path.hasSuffix("download") {
            let job: [String: Any] = ["id": "00000000-0000-0000-0000-000000000001", "state": "ready", "phase": "archive", "completed": 1, "total": 1, "revision": 42, "byteCount": archive.count, "sha256": hash]
            let data = try! JSONSerialization.data(withJSONObject: job)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": String(data.count)])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
            return
        }
        let offset = request.value(forHTTPHeaderField: "Range") == nil ? 0 : 1024
        let headers = ["Content-Length": String(archive.count - offset), "ETag": "\"\(hash)\"", "Content-Range": "bytes \(offset)-\(archive.count - 1)/\(archive.count)"]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: offset == 0 ? 200 : 206, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        if downloadCount == 1 {
            client?.urlProtocol(self, didLoad: archive.prefix(1024))
            let delivery = Delivery { self.client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { delivery.operation() }
        } else {
            client?.urlProtocol(self, didLoad: archive.dropFirst(offset))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

private enum OfflineContractManifest {
    static func read(_ archive: URL) throws -> KeepsOfflineManifest {
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 512)!
        let size = Int(String(decoding: header[124..<136].prefix(while: { $0 != 0 }), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), radix: 8)!
        return try JSONDecoder().decode(KeepsOfflineManifest.self, from: handle.read(upToCount: size)!)
    }
}
