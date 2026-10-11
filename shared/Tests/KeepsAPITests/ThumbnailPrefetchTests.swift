import Foundation
import Testing
@testable import KeepsAPI

private actor PrefetchRecorder {
    var progress: [ThumbnailPrefetch.Progress] = []
    var downloads: [UUID] = []
    var queries: [KeepsAssetQuery] = []
    func record(_ value: ThumbnailPrefetch.Progress) { progress.append(value) }
    func download(_ id: UUID) { downloads.append(id) }
    func query(_ query: KeepsAssetQuery) { queries.append(query) }
}

struct ThumbnailPrefetchTests {
    let configuration = KeepsConfiguration(baseURL: URL(string: "https://prefetch.invalid")!, libraryID: "main")

    private func asset(thumbnail: Bool = true) throws -> KeepsAsset {
        let json = """
        {"id":"\(UUID())","cameraMake":"","cameraModel":"","lensModel":"","originalFilename":"photo.jpg","contentFingerprint":"c","metadataFingerprint":"m","rating":0,"flagState":"none","tags":[],"createdAt":"","updatedAt":"","trashed":false}
        """
        var value = try JSONDecoder().decode(KeepsAsset.self, from: Data(json.utf8))
        if thumbnail {
            value.thumbnail = KeepsPreview(downloadURL: URL(string: "https://prefetch.invalid/thumb")!, width: 10, height: 10, version: "1")
        }
        value.browseThumbnail = value.thumbnail
        return value
    }

    @Test func directoryPrefetchKeepsScopeAndDownloadsEveryPage() async throws {
        let values = try [asset(), asset(), asset()]
        let suite = "prefetch-test-" + UUID().uuidString
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let recorder = PrefetchRecorder()
        let worker = ThumbnailPrefetch(defaultsSuite: suite, fetchPage: { _, query in
            await recorder.query(query)
            return KeepsAssetPage(items: [values[2]], total: 3, nextCursor: nil, revision: 1, isUpdating: false)
        }, fetchCounts: { _ in KeepsCounts(all: 0, trashed: 0, picked: 0) }, prefetch: { asset, _ in
            await recorder.download(asset.id)
            return true
        })
        var query = KeepsAssetQuery()
        query.directory = "/photos"
        query.recursive = false
        query.minRating = 2
        try await worker.runDirectory(configuration: configuration, query: query,
            firstPage: KeepsAssetPage(items: Array(values.prefix(2)), total: 3, nextCursor: "next", revision: 1, isUpdating: false))
        #expect(Set(await recorder.downloads) == Set(values.map(\.id)))
        var expected = query
        expected.cursor = "next"
        #expect(await recorder.queries == [expected])
    }

    @Test func directoryPrefetchStopsAtTenThousandAndRejectsChangedRevision() async throws {
        let value = try asset()
        let suite = "prefetch-test-" + UUID().uuidString
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let recorder = PrefetchRecorder()
        let worker = ThumbnailPrefetch(defaultsSuite: suite, fetchPage: { _, query in
            await recorder.query(query)
            return KeepsAssetPage(items: [value], total: 2, nextCursor: nil, revision: 2, isUpdating: false)
        }, fetchCounts: { _ in KeepsCounts(all: 0, trashed: 0, picked: 0) }, prefetch: { asset, _ in
            await recorder.download(asset.id)
            return true
        })
        var query = KeepsAssetQuery()
        query.directory = "/photos"
        try await worker.runDirectory(configuration: configuration, query: query,
            firstPage: KeepsAssetPage(items: [value], total: 10_000, nextCursor: "next", revision: 1, isUpdating: false))
        #expect(await recorder.downloads.isEmpty)
        #expect(await recorder.queries.isEmpty)
        try await worker.runDirectory(configuration: configuration, query: query,
            firstPage: KeepsAssetPage(items: [value], total: 2, nextCursor: "next", revision: 1, isUpdating: false))
        #expect(await recorder.downloads == [value.id])
    }

    @Test func finitePassReportsFailuresMissingAndIncludesTrash() async throws {
        let values = try [asset(), asset(), asset(thumbnail: false), asset()]
        let suite = "prefetch-test-" + UUID().uuidString
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let recorder = PrefetchRecorder()
        let worker = ThumbnailPrefetch(defaultsSuite: suite, fetchPage: { _, query in
            await recorder.query(query)
            let items = query.trashed ? [values[3]] : query.cursor == nil ? Array(values.prefix(2)) : [values[2]]
            return KeepsAssetPage(items: items, total: query.trashed ? 1 : 3, nextCursor: !query.trashed && query.cursor == nil ? "next" : nil, revision: 1, isUpdating: false)
        }, fetchCounts: { _ in KeepsCounts(all: 3, trashed: 1, picked: 0) }, prefetch: { asset, _ in
            await recorder.download(asset.id)
            if asset.id == values[1].id { throw KeepsAPIError.http(500, "test failure") }
            return true
        })
        let result = await worker.run(configuration: configuration, singlePass: true) { await recorder.record($0) }
        #expect(!result)
        let last = try #require(await recorder.progress.last)
        #expect(last.processed == 4 && last.total == 4)
        #expect(last.cached == 2 && last.failed == 1 && last.unavailable == 1)
        #expect(last.isComplete && last.lastError?.contains("500") == true)
        #expect(await recorder.queries.map(\.trashed) == [false, false, true])
        #expect(await recorder.queries.allSatisfy(\.showHidden))
    }

    @Test func cancellationResumesPersistedPageWithoutRepeatingFinishedAssets() async throws {
        let values = try [asset(), asset()]
        let suite = "prefetch-test-" + UUID().uuidString
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let recorder = PrefetchRecorder()
        let page: @Sendable (KeepsConfiguration, KeepsAssetQuery) async throws -> KeepsAssetPage = { _, query in
            KeepsAssetPage(items: query.trashed ? [] : values, total: query.trashed ? 0 : 2, nextCursor: nil, revision: 1, isUpdating: false)
        }
        let first = ThumbnailPrefetch(defaultsSuite: suite, fetchPage: page,
            fetchCounts: { _ in KeepsCounts(all: 2, trashed: 0, picked: 0) }, prefetch: { asset, _ in
                await recorder.download(asset.id)
                return true
            })
        let task = Task {
            await first.run(configuration: configuration, singlePass: true) { value in
                if value.processed == 1 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        #expect(await task.value == false)
        let resumed = ThumbnailPrefetch(defaultsSuite: suite, fetchPage: page,
            fetchCounts: { _ in KeepsCounts(all: 2, trashed: 0, picked: 0) }, prefetch: { asset, _ in
                await recorder.download(asset.id)
                return true
            })
        #expect(await resumed.run(configuration: configuration, singlePass: true) { await recorder.record($0) })
        #expect(await recorder.downloads == values.map(\.id))
        #expect(await recorder.progress.last?.cached == 2)
    }

    @Test func finitePassDoesNotWaitForeverWhenCacheCannotAcceptDownload() async throws {
        let value = try asset()
        let suite = "prefetch-test-" + UUID().uuidString
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let recorder = PrefetchRecorder()
        let worker = ThumbnailPrefetch(defaultsSuite: suite, fetchPage: { _, query in
            KeepsAssetPage(items: query.trashed ? [] : [value], total: query.trashed ? 0 : 1, nextCursor: nil, revision: 1, isUpdating: false)
        }, fetchCounts: { _ in KeepsCounts(all: 1, trashed: 0, picked: 0) }, prefetch: { _, _ in false })
        #expect(await worker.run(configuration: configuration, singlePass: true) { await recorder.record($0) } == false)
        #expect(await recorder.progress.last?.isComplete == false)
        #expect(await recorder.progress.last?.processed == 0)
        #expect(await recorder.progress.last?.lastError != nil)
        #expect(await recorder.progress.last?.cached == 0)
    }
}

@Suite(.serialized)
struct LocalThumbnailPrefetchTests {
    private let configuration = KeepsConfiguration(baseURL: URL(string: "https://local-prefetch.invalid")!, libraryID: "all")
    private let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aEl0AAAAASUVORK5CYII=")!

    private func asset(_ number: Int, trashed: Bool = false, thumbnail: Bool = true) -> KeepsAsset {
        var value = KeepsAsset(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!,
            captureTime: "2026-01-01", cameraMake: "", cameraModel: "", lensModel: "", originalFilename: "photo.jpg",
            contentFingerprint: "c", metadataFingerprint: "m", rating: 0, flagState: "none", colorLabel: nil,
            tags: [], createdAt: "2026-01-01", updatedAt: "2026-01-01", trashed: trashed, preview: nil,
            paths: ["/hidden/photo\(number).jpg"])
        if thumbnail {
            value.thumbnail = KeepsPreview(downloadURL: URL(string: "https://local-prefetch.invalid/\(number)")!,
                                            width: 1, height: 1, version: "1")
        }
        value.browseThumbnail = value.thumbnail
        return value
    }

    private func cache(_ root: URL, session: URLSession? = nil) -> PreviewCache {
        PreviewCache(directory: root.appendingPathComponent("thumbs"), diskLimit: Int.max, session: session, role: .thumbnail)
    }

    private func seed(_ assets: [KeepsAsset], cache: PreviewCache, browseCache: PreviewCache) async throws {
        for asset in assets {
            try await browseCache.store(image, key: PreviewCache.key(assetID: asset.id, preview: asset.browseThumbnail!,
                                                                    configuration: configuration, role: .browse))
            try await cache.store(image, key: PreviewCache.key(assetID: asset.id, preview: asset.thumbnail!,
                                                             configuration: configuration, role: .thumbnail))
        }
    }

    @Test func offlineInventoryIncludesHiddenTrashAndKeysetPages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: root)
        let values = (1...205).map { asset($0) } + (206...310).map { asset($0, trashed: true) }
        try db.beginSync(); try db.ingest(values); try db.replaceHiddenDirectories(["/hidden"])
        try db.completeSync(revision: 1, isStable: true)
        let cache = cache(root)
        let browseCache = PreviewCache(directory: root.appendingPathComponent("browse"), diskLimit: Int.max, role: .browse)
        try await seed(values, cache: cache, browseCache: browseCache)
        let recorder = PrefetchRecorder()
        let worker = ThumbnailPrefetch(cache: cache, browseCache: browseCache)
        #expect(await worker.runLocal(configuration: configuration, downloadMissing: false, databaseRoot: root) {
            await recorder.record($0)
        })
        let result = try #require(await recorder.progress.last)
        #expect(result.total == 310 && result.processed == 310 && result.cached == 310 && result.isComplete)
        #expect(await recorder.progress.map(\.processed) == [0, 100, 200, 205, 305, 310, 310])
    }

    @Test func incompleteCatalogAndMissingFilesBlockButUnavailableThumbnailDoesNot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: root)
        let values = [asset(1), asset(2), asset(3, thumbnail: false)]
        try db.ingest(values)
        let cache = cache(root)
        let browseCache = PreviewCache(directory: root.appendingPathComponent("browse"), diskLimit: Int.max, role: .browse)
        let worker = ThumbnailPrefetch(cache: cache, browseCache: browseCache)
        #expect(await worker.runLocal(configuration: configuration, downloadMissing: false, databaseRoot: root) == false)
        try db.completeSync(revision: 1, isStable: true)
        try await seed([values[0]], cache: cache, browseCache: browseCache)
        let recorder = PrefetchRecorder()
        #expect(await worker.runLocal(configuration: configuration, downloadMissing: false, databaseRoot: root) {
            await recorder.record($0)
        } == false)
        #expect(await recorder.progress.last?.failed == 1)
        #expect(await recorder.progress.last?.unavailable == 1)
        try await seed([values[1]], cache: cache, browseCache: browseCache)
        #expect(await worker.runLocal(configuration: configuration, downloadMissing: false, databaseRoot: root) {
            await recorder.record($0)
        })
        #expect(await recorder.progress.last?.cached == 2)
        #expect(await recorder.progress.last?.unavailable == 1)
        #expect(await recorder.progress.last?.lastError == nil)
        #expect(await recorder.progress.last?.isComplete == true)
        try db.beginSync(checkpoint: .init(revision: 2, stable: true))
        #expect(await worker.runLocal(configuration: configuration, downloadMissing: false, databaseRoot: root) == false)
    }

    @Test func failedDownloadsBlockAndRetryDownloadsOnlyMissingFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: root)
        let values = [asset(1), asset(2), asset(3)]
        try db.beginSync(); try db.ingest(values); try db.completeSync(revision: 1, isStable: true)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LocalThumbnailProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let cache = cache(root, session: session)
        let browseCache = PreviewCache(directory: root.appendingPathComponent("browse"), diskLimit: Int.max, session: session, role: .browse)
        try await seed([values[0]], cache: cache, browseCache: browseCache)
        let worker = ThumbnailPrefetch(cache: cache, browseCache: browseCache)
        let image = image
        LocalThumbnailProtocol.reset { request in (request.url!.path == "/3" ? 500 : 200, image) }
        #expect(await worker.runLocal(configuration: configuration, downloadMissing: true, databaseRoot: root) == false)
        #expect(LocalThumbnailProtocol.paths == ["/2", "/2", "/3", "/3"])
        LocalThumbnailProtocol.reset { _ in (200, image) }
        #expect(await worker.runLocal(configuration: configuration, downloadMissing: true, databaseRoot: root))
        #expect(LocalThumbnailProtocol.paths == ["/3", "/3"])
        LocalThumbnailProtocol.reset { _ in (500, Data()) }
        #expect(await worker.runLocal(configuration: configuration, downloadMissing: false, databaseRoot: root))
        #expect(LocalThumbnailProtocol.paths.isEmpty)
    }

    @Test func missingBrowseFileBlocksEvenWhenPreviewIsCached() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: root)
        let value = asset(1)
        try db.ingest([value]); try db.completeSync(revision: 1, isStable: true)
        let cache = cache(root)
        let browse = PreviewCache(directory: root.appendingPathComponent("browse"), role: .browse)
        try await cache.store(image, key: PreviewCache.key(assetID: value.id, preview: value.thumbnail!, configuration: configuration, role: .thumbnail))
        let recorder = PrefetchRecorder()
        let worker = ThumbnailPrefetch(cache: cache, browseCache: browse)
        #expect(await worker.runLocal(configuration: configuration, downloadMissing: false, databaseRoot: root) { await recorder.record($0) } == false)
        #expect(await recorder.progress.last?.failed == 1)
        #expect(await recorder.progress.last?.cached == 0)
        var unavailable = value
        unavailable.browseThumbnail = nil
        try db.ingest([unavailable])
        #expect(await worker.runLocal(configuration: configuration, downloadMissing: false, databaseRoot: root) { await recorder.record($0) })
        #expect(await recorder.progress.last?.unavailable == 1)
        #expect(await recorder.progress.last?.cached == 0)
    }

    @Test func catalogRevisionChangeDuringInventoryBlocksCompletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: root)
        let values = [asset(1)]
        try db.beginSync(); try db.ingest(values); try db.completeSync(revision: 1, isStable: true)
        let cache = cache(root)
        let browseCache = PreviewCache(directory: root.appendingPathComponent("browse"), diskLimit: Int.max, role: .browse)
        try await seed(values, cache: cache, browseCache: browseCache)
        let configuration = configuration
        #expect(await ThumbnailPrefetch(cache: cache, browseCache: browseCache).runLocal(configuration: configuration,
                downloadMissing: false, databaseRoot: root) { state in
            if state.processed == 1 {
                let writer = try! KeepsLibraryDatabase(configuration: configuration, rootDirectory: root)
                try! writer.beginSync(checkpoint: .init(revision: 2, stable: true))
            }
        } == false)
    }
}

private final class LocalThumbnailProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) private static var requests: [String] = []
    static var paths: [String] { lock.lock(); defer { lock.unlock() }; return requests }
    static func reset(_ block: @escaping (URLRequest) -> (Int, Data)) {
        lock.lock(); defer { lock.unlock() }; handler = block; requests = []
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests.append(request.url!.path); let block = Self.handler!; Self.lock.unlock()
        let (status, data) = block(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
