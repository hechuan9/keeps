import Foundation
import CryptoKit
import OSLog
import SwiftUI

/// Downloads only small derivatives; pagination never mutates the visible catalog.
public actor ThumbnailPrefetch {
    public struct Progress: Codable, Equatable, Sendable {
        public var processed = 0
        public var total = 0
        public var cached = 0
        public var failed = 0
        public var unavailable = 0
        public var isComplete = false
        public var lastError: String?
    }

    private struct Checkpoint: Codable {
        var cursor: String?
        var trashed = false
        var pageCompleted: Set<UUID> = []
        var progress = Progress()
    }

    public static let shared = ThumbnailPrefetch()

    public func runDirectory(configuration: KeepsConfiguration, query: KeepsAssetQuery,
                             firstPage: KeepsAssetPage) async throws {
        guard query.directory != nil, firstPage.total < 10_000 else { return }
        var page = firstPage
        var requested = query
        while true {
            try Task.checkCancellation()
            guard page.total < 10_000, page.revision == firstPage.revision else { return }
            try await withThrowingTaskGroup(of: Void.self) { group in
                var pending = page.items.makeIterator()
                func enqueue(_ asset: KeepsAsset) {
                    group.addTask { [directoryPrefetch] in
                        try Task.checkCancellation()
                        guard try await directoryPrefetch(asset, configuration) else {
                            throw CocoaError(.fileWriteOutOfSpace)
                        }
                    }
                }
                for _ in 0..<4 { if let asset = pending.next() { enqueue(asset) } }
                while try await group.next() != nil {
                    try Task.checkCancellation()
                    if let asset = pending.next() { enqueue(asset) }
                }
            }
            guard let cursor = page.nextCursor else { return }
            requested.cursor = cursor
            page = try await fetchPage(configuration, requested)
        }
    }
    private var running: Set<String> = []
    private let defaults: UserDefaults
    private let fetchPage: @Sendable (KeepsConfiguration, KeepsAssetQuery) async throws -> KeepsAssetPage
    private let fetchCounts: @Sendable (KeepsConfiguration) async throws -> KeepsCounts
    private let prefetch: @Sendable (KeepsAsset, KeepsConfiguration) async throws -> Bool
    private let directoryPrefetch: @Sendable (KeepsAsset, KeepsConfiguration) async throws -> Bool
    private let browseCache: PreviewCache
    private let localCache: PreviewCache
    private let delay: Duration

    public init(cache: PreviewCache = .thumbnails, browseCache: PreviewCache = .browsing) {
        self.browseCache = browseCache
        localCache = cache
        defaults = .standard
        fetchPage = { try await KeepsClient(configuration: $0).assets(query: $1) }
        fetchCounts = { try await KeepsClient(configuration: $0).counts(showHidden: true) }
        directoryPrefetch = { asset, configuration in
            for (descriptor, target) in [(asset.thumbnail, cache), (asset.browseThumbnail, browseCache)] {
                guard let descriptor else { continue }
                guard try await target.prefetch(assetID: asset.id, preview: descriptor,
                                                configuration: configuration, skipWhenBusy: false) else { return false }
            }
            return true
        }
        prefetch = { asset, configuration in
            while await PreviewCache.standards.isDownloading {
                try await Task.sleep(for: .seconds(1))
            }
            for (descriptor, cache) in [(asset.thumbnail, cache), (asset.browseThumbnail, browseCache)] {
                guard let descriptor else { continue }
                guard try await cache.prefetch(assetID: asset.id, preview: descriptor, configuration: configuration) else { return false }
            }
            return true
        }
        delay = .milliseconds(250)
    }

    init(defaultsSuite: String,
         fetchPage: @escaping @Sendable (KeepsConfiguration, KeepsAssetQuery) async throws -> KeepsAssetPage,
         fetchCounts: @escaping @Sendable (KeepsConfiguration) async throws -> KeepsCounts,
         prefetch: @escaping @Sendable (KeepsAsset, KeepsConfiguration) async throws -> Bool) {
        browseCache = .browsing
        localCache = .thumbnails
        defaults = UserDefaults(suiteName: defaultsSuite)!
        self.fetchPage = fetchPage
        self.fetchCounts = fetchCounts
        self.prefetch = prefetch
        directoryPrefetch = prefetch
        delay = .zero
    }

    @discardableResult
    public func run(configuration: KeepsConfiguration, singlePass: Bool = false,
                    progress: (@Sendable (Progress) async -> Void)? = nil) async -> Bool {
        let identity = [configuration.baseURL.absoluteString, configuration.libraryID].map { "\($0.utf8.count):\($0)" }.joined()
        let checkpoint = "thumbnail-prefetch-v3-" + SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        while running.contains(checkpoint) {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return false }
        }
        guard !Task.isCancelled else { return false }
        running.insert(checkpoint)
        defer { running.remove(checkpoint) }
        var state = defaults.data(forKey: checkpoint).flatMap { try? JSONDecoder().decode(Checkpoint.self, from: $0) } ?? Checkpoint()
        if state.progress.isComplete { state = Checkpoint() }
        while !Task.isCancelled {
            do {
                let counts = try await fetchCounts(configuration)
                state.progress.total = counts.all + counts.trashed
                if state.progress.failed == 0 { state.progress.lastError = nil }
                await progress?(state.progress)
                repeat {
                    var query = KeepsAssetQuery()
                    query.showHidden = true
                    query.limit = 100
                    query.cursor = state.cursor
                    query.trashed = state.trashed
                    let page = try await fetchPage(configuration, query)
                    try await process(page, state: &state, key: checkpoint, configuration: configuration,
                                      singlePass: singlePass, progress: progress)
                    state.pageCompleted.removeAll()
                    state.cursor = page.nextCursor
                    if page.nextCursor == nil {
                        if state.trashed { state.progress.isComplete = true }
                        else { state.trashed = true }
                    }
                    try save(state, key: checkpoint)
                } while !state.progress.isComplete
                let result = state.progress.failed == 0 && state.progress.unavailable == 0
                defaults.removeObject(forKey: checkpoint)
                await progress?(state.progress)
                if singlePass { return result }
                state = Checkpoint()
                try await Task.sleep(for: .seconds(300))
            } catch {
                if Task.isCancelled { return false }
                state.progress.lastError = (error as? CacheUnavailable)?.errorDescription ?? String(reflecting: error)
                await progress?(state.progress)
                Logger(subsystem: "local.keeps", category: "thumbnail-prefetch").error("Thumbnail prefetch failed: \(String(reflecting: error), privacy: .public)")
                if singlePass { return false }
                do { try await Task.sleep(for: .seconds(60)) } catch { return false }
            }
        }
        return false
    }

    /// Reads the complete local replica without involving the visible gallery window.
    @discardableResult
    public func runLocal(configuration: KeepsConfiguration, downloadMissing: Bool,
                         databaseRoot: URL? = nil,
                         progress: (@Sendable (Progress) async -> Void)? = nil) async -> Bool {
        var state = Progress()
        do {
            try Task.checkCancellation()
            let database = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: databaseRoot)
            guard let revision = try database.revision, try database.syncCheckpoint == nil else {
                throw LocalCatalogUnavailable()
            }
            var cachedKeys: [KeepsMediaRole: Set<String>] = [
                .thumbnail: try await localCache.cachedKeys(), .browse: try await browseCache.cachedKeys()
            ]
            var requirements: [[(KeepsMediaRole, String)]] = []
            var downloaded = false
            var pages: [(KeepsAssetQuery, KeepsAssetPage)] = []
            for trashed in [false, true] {
                var query = KeepsAssetQuery()
                query.showHidden = true
                query.trashed = trashed
                query.limit = 100
                let page = try database.assets(query: query)
                state.total += page.total
                pages.append((query, page))
            }
            await progress?(state)
            let clock = ContinuousClock()
            var lastProgress = clock.now
            for (query, firstPage) in pages {
                var page = firstPage
                while true {
                    try Task.checkCancellation()
                    guard try database.revision == revision, try database.syncCheckpoint == nil else {
                        throw LocalCatalogUnavailable()
                    }
                    for asset in page.items {
                        try Task.checkCancellation()
                        var required: [(KeepsMediaRole, String)] = []
                        for (role, descriptor, cache) in [
                            (KeepsMediaRole.thumbnail, asset.thumbnail, localCache),
                            (KeepsMediaRole.browse, asset.browseThumbnail, browseCache)
                        ] {
                            guard let descriptor else { continue }
                            let key = PreviewCache.key(assetID: asset.id, preview: descriptor,
                                                       configuration: configuration, role: role)
                            required.append((role, key))
                            if cachedKeys[role]!.contains(key) || !downloadMissing { continue }
                            do {
                                downloaded = true
                                guard try await cache.prefetch(assetID: asset.id, preview: descriptor,
                                                               configuration: configuration),
                                      try await cache.containsCachedKey(key) else { throw CacheUnavailable() }
                                cachedKeys[role]!.insert(key)
                            } catch {
                                try Task.checkCancellation()
                                state.lastError = String(reflecting: error)
                                Logger(subsystem: "local.keeps", category: "thumbnail-prefetch")
                                    .error("Local \(role.rawValue) \(asset.id) failed: \(String(reflecting: error), privacy: .public)")
                            }
                        }
                        requirements.append(required)
                        if required.contains(where: { !cachedKeys[$0.0]!.contains($0.1) }) { state.failed += 1 }
                        else if required.count == 2 { state.cached += 1 }
                        else { state.unavailable += 1 }
                        state.processed += 1
                        if lastProgress.duration(to: clock.now) >= .seconds(1) {
                            await progress?(state)
                            lastProgress = clock.now
                        }
                    }
                    await progress?(state)
                    lastProgress = clock.now
                    guard page.nextCursor != nil, let boundary = page.items.last else { break }
                    page = try database.assets(query: query, olderThan: boundary, knownTotal: firstPage.total)
                }
            }
            try Task.checkCancellation()
            guard try database.revision == revision, try database.syncCheckpoint == nil else {
                throw LocalCatalogUnavailable()
            }
            if downloaded {
                cachedKeys = [.thumbnail: try await localCache.cachedKeys(), .browse: try await browseCache.cachedKeys()]
                state.cached = 0
                state.failed = 0
                state.unavailable = 0
                for required in requirements {
                    if required.contains(where: { !cachedKeys[$0.0]!.contains($0.1) }) { state.failed += 1 }
                    else if required.count == 2 { state.cached += 1 }
                    else { state.unavailable += 1 }
                }
            }
            try Task.checkCancellation()
            guard try database.revision == revision, try database.syncCheckpoint == nil else {
                throw LocalCatalogUnavailable()
            }
            // Missing NAS derivatives use placeholders; existing descriptors must be persisted before entry.
            state.isComplete = state.processed == state.total && state.failed == 0
            if !state.isComplete, state.lastError == nil {
                state.lastError = "已有缩略图尚未全部缓存：缺失 \(state.failed)。"
            }
            await progress?(state)
            return state.isComplete
        } catch {
            state.lastError = (error as? LocalCatalogUnavailable)?.errorDescription ?? String(reflecting: error)
            await progress?(state)
            return false
        }
    }

    private struct LocalCatalogUnavailable: Error, LocalizedError {
        var errorDescription: String? { "本地图库尚未完成稳定同步，请先完成照片记录同步。" }
    }

    private struct CacheUnavailable: Error, LocalizedError {
        var errorDescription: String? { "缩略图缓存暂不可用（空间不足或其他下载正在进行），进度已保留，请稍后重试。" }
    }

    private func cache(_ asset: KeepsAsset, configuration: KeepsConfiguration, singlePass: Bool) async throws {
        var attempts = 0
        while !(try await prefetch(asset, configuration)) {
            attempts += 1
            if singlePass && attempts >= 3 { throw CacheUnavailable() }
            try await Task.sleep(for: delay == .zero ? .zero : .seconds(2))
        }
        try Task.checkCancellation()
    }

    private func process(_ page: KeepsAssetPage, state: inout Checkpoint, key: String,
                         configuration: KeepsConfiguration, singlePass: Bool,
                         progress: (@Sendable (Progress) async -> Void)?) async throws {
        for asset in page.items where !state.pageCompleted.contains(asset.id) {
            try Task.checkCancellation()
            if asset.thumbnail == nil && asset.browseThumbnail == nil {
                state.progress.unavailable += 1
            } else {
                do {
                    try await cache(asset, configuration: configuration, singlePass: singlePass)
                    if asset.thumbnail != nil && asset.browseThumbnail != nil { state.progress.cached += 1 }
                    else { state.progress.unavailable += 1 }
                } catch is CacheUnavailable {
                    throw CacheUnavailable()
                } catch {
                    try Task.checkCancellation()
                    state.progress.failed += 1
                    state.progress.lastError = String(reflecting: error)
                    Logger(subsystem: "local.keeps", category: "thumbnail-prefetch").error("Thumbnail \(asset.id) failed: \(String(reflecting: error), privacy: .public)")
                }
            }
            state.progress.processed += 1
            state.pageCompleted.insert(asset.id)
            try save(state, key: key)
            await progress?(state.progress)
            try await Task.sleep(for: delay)
        }
    }

    private func save(_ state: Checkpoint, key: String) throws {
        defaults.set(try JSONEncoder().encode(state), forKey: key)
    }
}

private struct ThumbnailPrefetchModifier: ViewModifier {
    let configuration: KeepsConfiguration?
    @Environment(\.scenePhase) private var scenePhase
    private var identity: String {
        "\(String(describing: configuration))|\(scenePhase == .active)"
    }
    func body(content: Content) -> some View {
        content.task(id: identity, priority: .background) {
            guard scenePhase == .active, let configuration else { return }
            await ThumbnailPrefetch.shared.run(configuration: configuration)
        }
    }
}

extension View {
    public func prefetchKeepsThumbnails(configuration: KeepsConfiguration?) -> some View {
        modifier(ThumbnailPrefetchModifier(configuration: configuration))
    }
}
