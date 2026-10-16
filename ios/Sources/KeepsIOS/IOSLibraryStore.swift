import Foundation
import SwiftUI
import OSLog
import KeepsAPI

@MainActor
final class IOSLibraryStore: ObservableObject {
    @Published private(set) var assets: [KeepsAsset] = []
    @Published private(set) var timeline: [KeepsTimelineEntry] = []
    private(set) var timelineRevision = 0
    var visibleIDs: Set<UUID> = []
    @Published private(set) var total = 0
    @Published private(set) var layoutRevision = 0
    @Published private(set) var databaseRevision = 0
    @Published private(set) var isSyncing = false
    @Published private(set) var isLoadingLocal = false
    @Published private(set) var syncError: String?
    @Published private(set) var configuration: KeepsConfiguration?
    @Published var lastError: String?
    @Published var showingTrashCleanup = false
    @Published private(set) var trashCleanup: KeepsRejectedTrashTask?
    @Published private(set) var trashCleanupBusy = false
    @Published private(set) var trashCleanupError: String?
    private var trashCleanupTracking: Task<Void, Never>?
    var hasPendingTrashCleanup: Bool { pendingTrashID != nil }
    private var pendingTrashID: UUID?
    private var pendingTrashCount: Int?
    private var trashCleanupConfiguration: KeepsConfiguration?
    @Published var search = ""
    @Published var showingTrash = false
    @Published var showingPicked = false
    @Published var directory: String?
    @Published private(set) var hasLocalCatalog = false
    let sort = "capture_desc"
    var chronologicalAssets: [KeepsAsset] { assets.reversed() }
    private var nextCursor: String?
    private var displayedQuery: KeepsAssetQuery?
    private var loadedCount = 200
    private(set) var canLoadNewer = false
    private var readSequence = 0
    private var paging = false
    private let reader = IOSCatalogReader()
    private let windowLimit = 1000
    private var generation = 0
    private var syncTask: Task<Void, Never>?
    private var syncObservers: [UUID: IOSOfflineProgress.Reporter] = [:]
    private var initialReadTask: Task<Void, Never>?
    private let session: URLSession
    private let databaseDirectory: URL?
    private let synchronizer = IOSCatalogSynchronizer()

    init(configuration: KeepsConfiguration? = nil, session: URLSession = KeepsClient.apiSession,
         loadSettings: Bool = true, databaseDirectory: URL? = nil) {
        self.session = session
        self.databaseDirectory = databaseDirectory
        if let configuration { configure(configuration) }
        else if loadSettings { reloadConfiguration() }
    }

    func configure(_ configuration: KeepsConfiguration?) {
        guard self.configuration != configuration else { return }
        trashCleanupTracking?.cancel()
        trashCleanupTracking = nil
        pendingTrashID = nil
        pendingTrashCount = nil
        trashCleanup = nil
        trashCleanupBusy = false
        trashCleanupError = nil
        showingTrashCleanup = false
        generation += 1
        readSequence += 1
        paging = false
        syncTask?.cancel()
        syncTask = nil
        initialReadTask?.cancel()
        initialReadTask = nil
        isLoadingLocal = false
        hasLocalCatalog = false
        assets = []
        timeline = []
        visibleIDs = []
        timelineRevision += 1
        total = 0
        nextCursor = nil
        displayedQuery = nil
        loadedCount = 200
        canLoadNewer = false
        layoutRevision += 1
        isSyncing = false
        syncError = nil
        lastError = nil
        self.configuration = configuration
        guard let configuration else { return }
        restoreTrashCleanup(configuration)
        isLoadingLocal = true
        let currentGeneration = generation
        initialReadTask = Task { [weak self] in
            guard let self, generation == currentGeneration, !Task.isCancelled else { return }
            await readLocal()
            guard generation == currentGeneration else { return }
            isLoadingLocal = false
            initialReadTask = nil
        }
    }

    private func trashCleanupKey(_ configuration: KeepsConfiguration) -> String {
        "keeps.ios.pendingTrash." + configuration.baseURL.absoluteString + "|" + configuration.libraryID
    }

    private func restoreTrashCleanup(_ configuration: KeepsConfiguration) {
        guard let saved = UserDefaults.standard.dictionary(forKey: trashCleanupKey(configuration)),
              let value = saved["id"] as? String, let id = UUID(uuidString: value),
              let count = saved["count"] as? Int else { return }
        pendingTrashID = id
        pendingTrashCount = count
        trashCleanupConfiguration = configuration
        showingTrashCleanup = true
        trashCleanupBusy = true
        trashCleanupTracking = Task { await trackTrashCleanup(configuration, submit: false) }
    }

    func previewTrashCleanup() async {
        guard pendingTrashID == nil, !trashCleanupBusy, let configuration else { return }
        trashCleanupConfiguration = configuration
        trashCleanup = nil
        trashCleanupError = nil
        trashCleanupBusy = true
        defer { if self.configuration == configuration { trashCleanupBusy = false } }
        do {
            let preview = try await KeepsClient(configuration: configuration, session: session).previewTrash()
            guard self.configuration == configuration else { return }
            trashCleanup = preview
        } catch {
            guard self.configuration == configuration else { return }
            trashCleanupError = error.localizedDescription + "\n" + String(reflecting: error)
        }
    }

    func canConfirmTrashCleanup(_ confirmation: String) -> Bool {
        guard let task = trashCleanup else { return false }
        return !trashCleanupBusy && pendingTrashID == nil && configuration == trashCleanupConfiguration
            && task.status == "draft" && task.count > 0 && confirmation == String(task.count)
    }

    func submitTrashCleanup(_ confirmation: String) {
        guard canConfirmTrashCleanup(confirmation), let task = trashCleanup, let configuration else { return }
        pendingTrashID = task.id
        pendingTrashCount = task.count
        UserDefaults.standard.set(["id": task.id.uuidString, "count": task.count], forKey: trashCleanupKey(configuration))
        trashCleanupBusy = true
        trashCleanupTracking = Task { await trackTrashCleanup(configuration, submit: true) }
    }

    private func trackTrashCleanup(_ configuration: KeepsConfiguration, submit: Bool) async {
        let client = KeepsClient(configuration: configuration, session: session)
        var shouldSubmit = submit
        while self.configuration == configuration, let id = pendingTrashID, let count = pendingTrashCount, !Task.isCancelled {
            do {
                let task: KeepsRejectedTrashTask
                if shouldSubmit {
                    shouldSubmit = false
                    task = try await client.submitTrash(id: id, confirmationCount: count)
                } else { task = try await client.trashTask(id: id) }
                guard self.configuration == configuration, !Task.isCancelled else { return }
                guard task.id == id, task.count == count else {
                    trashCleanupError = "服务器返回的任务与已确认清单不一致，请在 NAS 核实。"
                    trashCleanupBusy = false
                    return
                }
                trashCleanup = task
                trashCleanupError = nil
                if task.status == "completed" || task.status == "failed" {
                    pendingTrashID = nil
                    pendingTrashCount = nil
                    UserDefaults.standard.removeObject(forKey: trashCleanupKey(configuration))
                    trashCleanupBusy = false
                    if task.status == "failed" { trashCleanupError = task.error ?? "NAS 回收任务失败。" }
                    await refresh()
                    return
                }
                if task.status == "draft" { shouldSubmit = true }
            } catch {
                guard self.configuration == configuration, !Task.isCancelled else { return }
                trashCleanupError = "暂时无法确认进度；NAS 后台任务独立执行，正在查询同一任务。\n" + error.localizedDescription + "\n" + String(reflecting: error)
                if case KeepsAPIError.http(let status, _) = error, (400..<500).contains(status) {
                    if status == 409 {
                        pendingTrashID = nil
                        pendingTrashCount = nil
                        trashCleanup = nil
                        UserDefaults.standard.removeObject(forKey: trashCleanupKey(configuration))
                        trashCleanupError = "回收站清单已变化，请重新预览并确认照片总数。\n" + String(reflecting: error)
                    }
                    trashCleanupBusy = false
                    return
                }
            }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }

    func resumeTrashCleanup() {
        guard pendingTrashID != nil, !trashCleanupBusy, let configuration else { return }
        trashCleanupBusy = true
        trashCleanupTracking = Task { await trackTrashCleanup(configuration, submit: false) }
    }

    func closeTrashCleanup() {
        showingTrashCleanup = false
        if pendingTrashID == nil { trashCleanup = nil; trashCleanupError = nil }
    }

    func reloadConfiguration() {
        do { configure(try KeepsSettings.load()) }
        catch { configure(nil); lastError = String(reflecting: error) }
    }

    private var query: KeepsAssetQuery {
        var query = KeepsAssetQuery()
        query.q = search
        query.trashed = showingTrash
        query.flagState = showingPicked ? "picked" : nil
        query.directory = directory
        query.limit = 200
        return query
    }

    func waitForLocalLoad() async { await initialReadTask?.value }

    func refresh() async {
        await waitForLocalLoad()
        await readLocal()
    }

    func loadMore() async { await loadPage(newer: false) }
    func loadNewer() async { await loadPage(newer: true) }

    @discardableResult
    func restoreWindow(around asset: KeepsAsset) async -> Bool {
        await waitForLocalLoad()
        let request = query
        if displayedQuery == request, assets.contains(where: { $0.id == asset.id }) { return true }
        guard let configuration else { return false }
        readSequence += 1
        paging = false
        let sequence = readSequence
        let currentGeneration = generation
        do {
            let window = try await reader.window(configuration: configuration, root: databaseDirectory,
                                                 query: request, around: asset)
            guard generation == currentGeneration, sequence == readSequence, request == query,
                  let window else { return false }
            if displayedQuery != request { layoutRevision += 1 }
            displayedQuery = request
            assets = window.page.items
            loadedCount = max(200, assets.count)
            total = window.page.total
            nextCursor = window.page.nextCursor
            canLoadNewer = window.hasNewer
            lastError = nil
            return true
        } catch {
            guard generation == currentGeneration, sequence == readSequence, request == query else { return false }
            lastError = String(reflecting: error)
            return false
        }
    }

    private func loadPage(newer: Bool) async {
        await waitForLocalLoad()
        guard displayedQuery == query else { await readLocal(); return }
        guard !paging, newer ? canLoadNewer : nextCursor != nil,
              let configuration, let boundary = newer ? assets.first : assets.last else { return }
        paging = true
        readSequence += 1
        let sequence = readSequence
        let request = query
        let currentGeneration = generation
        defer { if sequence == readSequence { paging = false } }
        do {
            let page = try await reader.page(configuration: configuration, root: databaseDirectory,
                query: request, older: newer ? nil : boundary, newer: newer ? boundary : nil, knownTotal: total)
            guard generation == currentGeneration, sequence == readSequence, request == query else { return }
            if newer {
                assets.insert(contentsOf: page.items, at: 0)
                canLoadNewer = page.nextCursor != nil
                if assets.count > windowLimit {
                    assets.removeLast(assets.count - windowLimit)
                    nextCursor = "more"
                }
            } else {
                assets.append(contentsOf: page.items)
                nextCursor = page.nextCursor
                if assets.count > windowLimit {
                    assets.removeFirst(assets.count - windowLimit)
                    canLoadNewer = true
                }
            }
            loadedCount = assets.count
            total = page.total
            lastError = nil
        } catch {
            guard generation == currentGeneration, sequence == readSequence, request == query else { return }
            lastError = String(reflecting: error)
        }
    }

    private func readLocal() async {
        guard let configuration else { return }
        readSequence += 1
        paging = false
        let sequence = readSequence
        let currentGeneration = generation
        let currentQuery = query
        let sameQuery = displayedQuery == currentQuery
        var request = currentQuery
        request.limit = sameQuery ? max(200, loadedCount) : 200
        do {
            let hasCatalog = try await reader.hasCatalog(configuration: configuration, root: databaseDirectory)
            let index = try await reader.timeline(configuration: configuration, root: databaseDirectory, query: currentQuery)
            let page = try await reader.page(configuration: configuration, root: databaseDirectory,
                query: request, through: sameQuery && !canLoadNewer ? assets.last : nil,
                first: sameQuery && canLoadNewer ? assets.first : nil, maximumLimit: windowLimit)
            guard generation == currentGeneration, sequence == readSequence, currentQuery == query else { return }
            if !sameQuery {
                layoutRevision += 1
                canLoadNewer = false
            }
            hasLocalCatalog = hasCatalog
            displayedQuery = currentQuery
            timelineRevision += 1
            timeline = index
            loadedCount = max(200, page.items.count)
            assets = page.items
            total = page.total
            nextCursor = page.nextCursor
            lastError = nil
        } catch {
            guard generation == currentGeneration, sequence == readSequence, currentQuery == query else { return }
            lastError = String(reflecting: error)
        }
    }

    /// Grid actions resolve only the requested photo; the full timeline owns scroll positions.
    func asset(id: UUID) async -> KeepsAsset? {
        guard let configuration else { return nil }
        let currentGeneration = generation
        let request = query
        do {
            let result = try await reader.assets(configuration: configuration, root: databaseDirectory, ids: [id])
            guard generation == currentGeneration, request == query,
                  timeline.contains(where: { $0.id == id }) else { return nil }
            return result.first
        } catch {
            guard generation == currentGeneration else { return nil }
            lastError = String(reflecting: error)
            return nil
        }
    }

    func synchronize(forceRebuild: Bool = false, includeThumbnails: Bool? = nil, progress: IOSOfflineProgress.Reporter? = nil) async {
        let observerID = UUID()
        if let progress { syncObservers[observerID] = progress }
        defer { syncObservers.removeValue(forKey: observerID) }
        await waitForLocalLoad()
        if let syncTask { await syncTask.value; return }
        guard let configuration else { return }
        let currentGeneration = generation
        isSyncing = true
        syncError = nil
        let task = Task(priority: .utility) { @MainActor in
            defer {
                if generation == currentGeneration {
                    isSyncing = false
                    syncTask = nil
                    databaseRevision += 1
                }
            }
            do {
                try await synchronizer.run(configuration: configuration, root: databaseDirectory,
                    session: session, forceRebuild: forceRebuild, includeThumbnails: includeThumbnails) { stage, completed, total in
                        guard self.generation == currentGeneration else { return }
                        for observer in Array(self.syncObservers.values) { await observer(stage, completed, total) }
                        if stage == .importing && completed == total {
                            self.databaseRevision += 1
                            await self.readLocal()
                        }
                    }
            } catch {
                guard generation == currentGeneration, !Task.isCancelled else { return }
                syncError = String(reflecting: error)
                Logger(subsystem: "com.hechuan.Keeps", category: "catalog-sync")
                    .error("Catalog sync failed: \(String(reflecting: error), privacy: .public)")
            }
            if generation == currentGeneration { await readLocal() }
        }
        syncTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    func synchronizeChecked(forceRebuild: Bool = false, includeThumbnails: Bool? = nil, progress: IOSOfflineProgress.Reporter? = nil) async throws {
        await synchronize(forceRebuild: forceRebuild, includeThumbnails: includeThumbnails, progress: progress)
        try Task.checkCancellation()
        if let syncError { throw NSError(domain: "KeepsOfflineRebuild", code: 1, userInfo: [NSLocalizedDescriptionKey: syncError]) }
    }

    func update(_ asset: KeepsAsset) async {
        guard let configuration else { return }
        generation += 1
        readSequence += 1
        paging = false
        syncTask?.cancel()
        syncTask = nil
        isSyncing = false
        let currentGeneration = generation
        do {
            try await synchronizer.update(asset, configuration: configuration, root: databaseDirectory)
            guard currentGeneration == generation else { return }
            databaseRevision += 1
            await readLocal()
        } catch { lastError = String(reflecting: error) }
    }

    var canLoadMore: Bool { nextCursor != nil }
    var hasLoadedResults: Bool { !assets.isEmpty || (!isLoadingLocal && !isSyncing) }

}

// The writer owns a separate SQLite connection; page commits never publish gallery state.
private actor IOSCatalogSynchronizer {
    func update(_ asset: KeepsAsset, configuration: KeepsConfiguration, root: URL?) throws {
        let database = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: root)
        try database.update(asset)
    }

    func run(configuration: KeepsConfiguration, root: URL?, session: URLSession,
             forceRebuild: Bool, includeThumbnails: Bool?, progress: IOSOfflineProgress.Reporter?) async throws {
        try Task.checkCancellation()
        let database = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: root)
        let client = KeepsClient(configuration: configuration, session: session)
        let rebuild = KeepsOfflineRebuild(session: session)
        var force = forceRebuild
        // A continuously scanning NAS must not prevent the UI from publishing committed data.
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let remote = try await client.revision()
            if !force, try database.syncCheckpoint == nil, try database.revision == remote.revision,
               try database.generation == remote.generation {
                do {
                    try await rebuild.acknowledge(configuration: configuration, databaseRoot: root)
                    return
                } catch KeepsAPIError.http(let status, _) where status == 409 || status == 410 {
                    force = true
                }
            }
            let previous = try database.revision
            let previousGeneration = try database.generation
            let manifest = try await rebuild.run(configuration: configuration, databaseRoot: root,
                                  includeThumbnails: includeThumbnails ?? (force || previous == nil || (try database.syncCheckpoint) != nil), forceRebuild: force) { update in
            let stage: IOSOfflineProgress.Stage
            switch update.phase {
            case .building:
                switch update.step {
                case "snapshot": stage = .snapshot
                case "catalog": stage = .catalog
                case "navigation": stage = .navigation
                case "verifying": stage = .verifying
                default: stage = .archive
                }
            case .downloading: stage = .download
            case .verifying: stage = .verifyDownload
            case .importing: stage = .importing
            }
            await progress?(stage, update.completed, update.total)
            }
            force = false
            let latest = try await client.revision()
            if latest.revision == manifest.revision && latest.generation == manifest.generation { return }
            guard previous != manifest.revision || previousGeneration != manifest.generation else {
                throw NSError(domain: "KeepsSync", code: 1, userInfo: [NSLocalizedDescriptionKey: "NAS 同步包未推进图库版本，请重试"])
            }
            if attempt < 2 { try await Task.sleep(for: .seconds(1)) }
        }
    }

}

// A separate connection keeps SQLite work and snapshot decoding off the UI executor.
actor IOSCatalogReader {
    private var configuration: KeepsConfiguration?
    private var database: KeepsLibraryDatabase?

    private func open(configuration: KeepsConfiguration, root: URL?) throws -> KeepsLibraryDatabase {
        if self.configuration != configuration {
            database = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: root)
            self.configuration = configuration
        }
        return database!
    }

    func hasCatalog(configuration: KeepsConfiguration, root: URL? = nil) throws -> Bool {
        let database = try open(configuration: configuration, root: root)
        return try database.revision != nil && database.syncCheckpoint == nil
    }

    func timeline(configuration: KeepsConfiguration, root: URL?, query: KeepsAssetQuery) throws -> [KeepsTimelineEntry] {
        try open(configuration: configuration, root: root).timeline(query: query)
    }

    func assets(configuration: KeepsConfiguration, root: URL?, ids: [UUID]) throws -> [KeepsAsset] {
        try open(configuration: configuration, root: root).assets(ids: ids)
    }

    func window(configuration: KeepsConfiguration, root: URL?, query: KeepsAssetQuery,
                around asset: KeepsAsset) throws -> (page: KeepsAssetPage, hasNewer: Bool)? {
        var request = query
        request.limit = 200
        let older = try page(configuration: configuration, root: root, query: request, first: asset)
        guard older.items.first?.id == asset.id else { return nil }
        let newer = try page(configuration: configuration, root: root, query: request,
                             newer: asset, knownTotal: older.total)
        return (KeepsAssetPage(items: newer.items + older.items, total: older.total,
                               nextCursor: older.nextCursor, revision: older.revision,
                               isUpdating: older.isUpdating), newer.nextCursor != nil)
    }

    func page(configuration: KeepsConfiguration, root: URL?, query: KeepsAssetQuery,
              older: KeepsAsset? = nil, newer: KeepsAsset? = nil, through: KeepsAsset? = nil,
              first: KeepsAsset? = nil, maximumLimit: Int? = nil, knownTotal: Int? = nil) throws -> KeepsAssetPage {
        return try open(configuration: configuration, root: root).assets(query: query, includingThrough: through, olderThan: older,
                                    newerThan: newer, startingAt: first, maximumLimit: maximumLimit, knownTotal: knownTotal)
    }
}

// Fixed stage budgets keep later phases from resetting the system progress to zero.
struct IOSOfflineProgress {
    enum Stage: Int, CaseIterable, Sendable {
        case restore, check, snapshot, catalog, navigation, archive, verifying, download, verifyDownload, importing, thumbnails, backup
    }
    typealias Reporter = @MainActor @Sendable (Stage, Int64, Int64) async -> Void
    static let stageUnits: Int64 = 1_000_000_000
    let totalUnitCount = Int64(Stage.allCases.count) * stageUnits
    private(set) var completedUnitCount: Int64 = 0
    private var reportedStage: Stage?
    private var reportedCompleted: Int64 = 0
    var fractionCompleted: Double { Double(completedUnitCount) / Double(totalUnitCount) }
    var percentage: Int { Int(completedUnitCount * 100 / totalUnitCount) }

    mutating func complete() { completedUnitCount = totalUnitCount }

    mutating func record(_ stage: Stage, completed: Int64, total: Int64) {
        guard completed >= 0, total > 0 else { return }
        guard reportedStage.map({ stage.rawValue >= $0.rawValue }) ?? true else { return }
        let denominator = stage == .navigation ? Double(max(total, completed)) + 1 : Double(total)
        let fraction = min(1, Double(completed) / denominator)
        let base = Int64(stage.rawValue) * Self.stageUnits
        var units = base + Int64(fraction * Double(Self.stageUnits))
        // Directory discovery may increase the denominator while actual completed work increases.
        if stage == reportedStage, completed > reportedCompleted, units <= completedUnitCount {
            units = min(base + Self.stageUnits - 1, completedUnitCount + 1)
        }
        if stage != reportedStage { reportedCompleted = 0 }
        reportedStage = stage
        reportedCompleted = max(reportedCompleted, completed)
        completedUnitCount = min(totalUnitCount - 1, max(completedUnitCount, units))
    }
}
