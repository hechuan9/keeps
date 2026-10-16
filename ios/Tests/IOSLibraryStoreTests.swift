import Foundation
import CryptoKit
import SQLite3
import Testing
import KeepsAPI
@testable import KeepsIOSState

@MainActor
struct IOSLibraryStoreTests {
    @Test func continuousNASChangesPublishEachPackageAndBoundCatchup() async throws {
        let fixture = ReplicaFixture()
        fixture.continuouslyChanging = true
        let store = await fixture.store()
        var published: [Int64] = []
        await store.synchronize { stage, completed, total in
            if stage == .importing && completed == total {
                published.append((try? fixture.database().revision) ?? -1)
            }
        }
        #expect(store.syncError == nil)
        #expect(published == [1, 2, 3])
        #expect(try fixture.database().revision == 3)
        #expect(store.hasLocalCatalog && !store.timeline.isEmpty)
        #expect(fixture.requests.filter { $0 == "POST /libraries/library/offline-rebuild" }.count == 3)
    }

    @Test func committedSnapshotSurvivesAckFailureAndRetriesWithoutRedownload() async throws {
        let fixture = ReplicaFixture()
        fixture.syncGeneration = UUID().uuidString
        fixture.ackStatus = 503
        let store = await fixture.store()
        await store.synchronize()
        #expect(store.syncError != nil)
        #expect(try fixture.database().revision == 1)
        #expect(try fixture.database().generation == fixture.syncGeneration)
        #expect(store.hasLocalCatalog)
        let before = fixture.requests.count
        fixture.ackStatus = 200
        await store.synchronize()
        #expect(store.syncError == nil)
        let retry = Array(fixture.requests.dropFirst(before))
        #expect(retry.count == 2)
        #expect(retry[0].hasSuffix("revision"))
        #expect(retry[1].hasSuffix("ack"))
        #expect(!retry.contains { $0.contains("download") || $0.contains("offline-rebuild") })
    }

    @Test func generationMismatchBootstrapsEvenWhenRevisionMatches() async throws {
        let fixture = ReplicaFixture()
        fixture.syncGeneration = UUID().uuidString
        let local = try fixture.database()
        try local.completeSync(revision: 1, isStable: true)
        var db: OpaquePointer?
        #expect(sqlite3_open(local.fileURL.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "INSERT INTO metadata VALUES('generation','\(UUID().uuidString)')", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let store = await fixture.store()
        await store.synchronize()
        #expect(store.syncError == nil)
        #expect(fixture.requests.contains("POST /libraries/library/offline-rebuild"))
        #expect(try local.generation == fixture.syncGeneration)
    }

    @Test func expiredReplicaTriggersFullBootstrapEvenWhenRevisionMatches() async throws {
        let fixture = ReplicaFixture()
        fixture.syncGeneration = UUID().uuidString
        let store = await fixture.store()
        await store.synchronize()
        #expect(store.syncError == nil)
        fixture.ackStatus = 409
        let before = fixture.requests.count
        await store.synchronize()
        #expect(fixture.requests.dropFirst(before).contains("POST /libraries/library/offline-rebuild"))
        #expect(try fixture.database().revision == 1)
    }

    @Test func startupReturnsBeforeDatabaseIOAndReportsFailureAsynchronously() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not a directory".utf8).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = KeepsConfiguration(baseURL: URL(string: "https://example.invalid")!, libraryID: "test")
        let store = IOSLibraryStore(configuration: configuration, loadSettings: false, databaseDirectory: root)
        #expect(store.isLoadingLocal)
        #expect(store.lastError == nil)
        await store.waitForLocalLoad()
        #expect(!store.isLoadingLocal)
        #expect(store.lastError != nil)
        #expect(!store.hasLocalCatalog)
    }

    @Test func cachedCatalogBecomesReadyWithoutNetwork() async throws {
        let fixture = ReplicaFixture()
        fixture.offline = true
        let database = try fixture.database()
        try database.ingest([fixture.asset(1)])
        try database.completeSync(revision: 1, isStable: true)
        let store = await fixture.store()
        #expect(store.hasLocalCatalog)
        #expect(store.timeline.count == 1)
        #expect(fixture.requests.isEmpty)
    }

    @Test func fullTimelineSupportsDirectDistantPhotoLookupWithoutPagingOrNetwork() async throws {
        let fixture = ReplicaFixture()
        let store = await fixture.store()
        try fixture.database().ingest((1...30_000).map { try fixture.asset($0) })
        await store.refresh()
        #expect(store.timeline.count == 30_000)
        #expect(store.assets.count == 200)
        let distant = store.timeline[25_000]
        let photo = await store.asset(id: distant.id)
        #expect(photo?.originalFilename == "photo-25001")
        #expect(store.assets.count == 200)
        #expect(fixture.requests.isEmpty)
        #expect(await store.restoreWindow(around: try #require(photo)))
        #expect(store.assets.contains { $0.id == distant.id })
        #expect(store.assets.count <= 1000)
        #expect(store.timeline.count == 30_000)
        store.search = "photo-30000"
        await store.refresh()
        #expect(store.timeline.map(\.filename) == ["photo-30000"])
        #expect(await store.asset(id: distant.id) == nil)
        store.configure(nil)
        #expect(store.timeline.isEmpty)
    }

    @Test func newlyDiscoveredDirectoriesStillReportActualProgress() {
        var progress = IOSOfflineProgress()
        progress.record(.navigation, completed: 1, total: 1)
        let first = progress.completedUnitCount
        progress.record(.navigation, completed: 2, total: 200)
        #expect(progress.completedUnitCount > first)
        let second = progress.completedUnitCount
        progress.record(.navigation, completed: 2, total: 200)
        #expect(progress.completedUnitCount == second)
    }

    @Test func systemProgressAdvancesAcrossLargeStagesWithoutResetOrEarlyCompletion() {
        var progress = IOSOfflineProgress()
        for stage in IOSOfflineProgress.Stage.allCases {
            let before = progress.completedUnitCount
            progress.record(stage, completed: 1, total: 300_000)
            #expect(progress.completedUnitCount > before)
            progress.record(stage, completed: 2, total: 300_000)
            let advanced = progress.completedUnitCount
            progress.record(stage, completed: 1, total: 600_000)
            #expect(progress.completedUnitCount == advanced)
            progress.record(stage, completed: 300_000, total: 300_000)
        }
        #expect(progress.completedUnitCount == progress.totalUnitCount - 1)
        progress.record(.restore, completed: 0, total: 1)
        #expect(progress.completedUnitCount == progress.totalUnitCount - 1)
        #expect(progress.percentage == 99)
        progress.complete()
        #expect(progress.percentage == 100)
        #expect(progress.fractionCompleted == 1)
        #expect(IOSOfflineProgress().completedUnitCount == 0)
    }

    @Test func initialLocalLoadIsAsynchronousAndConfigurationSwitchDiscardsIt() async throws {
        let fixture = ReplicaFixture()
        try fixture.database().ingest((1...450).map { try fixture.asset($0) })
        let store = IOSLibraryStore(configuration: fixture.configuration, session: fixture.session, databaseDirectory: fixture.root)
        #expect(store.isLoadingLocal)
        #expect(!store.hasLoadedResults)
        #expect(store.assets.isEmpty)
        await store.waitForLocalLoad()
        #expect(!store.isLoadingLocal)
        #expect(store.assets.count == 200)
        #expect(store.total == 450)
        let switched = IOSLibraryStore(configuration: fixture.configuration, session: fixture.session, databaseDirectory: fixture.root)
        var other = fixture.configuration
        other.accessCredential = "other"
        switched.configure(other)
        await switched.waitForLocalLoad()
        #expect(switched.assets.isEmpty)
        #expect(!switched.isLoadingLocal)
    }

    @Test func coldLaunchAndLocalBrowsingNeedNoNetwork() async throws {
        let fixture = ReplicaFixture()
        let store = await fixture.store()
        let database = try fixture.database()
        try database.beginSync()
        try database.ingest((1...450).map { try fixture.asset($0) })
        try database.completeSync(revision: 1, isStable: true)
        let restarted = await fixture.store()
        #expect(restarted.assets.count == 200)
        #expect(restarted.total == 450)
        await restarted.loadMore()
        #expect(restarted.assets.count == 400)
        restarted.search = "photo-450"
        await restarted.refresh()
        #expect(restarted.assets.map(\.originalFilename) == ["photo-450"])
        restarted.search = ""
        restarted.directory = "/photos"
        await restarted.refresh()
        #expect(restarted.total == 450)
        #expect(fixture.requests.isEmpty)
    }

    @Test func refreshKeepsLoadedPhotosWhenNewPhotosArrive() async throws {
        let fixture = ReplicaFixture()
        let store = await fixture.store()
        let database = try fixture.database()
        try database.beginSync()
        try database.ingest((1...450).map { try fixture.asset($0) })
        await store.refresh()
        await store.loadMore()
        let previous = store.assets.map(\.id)
        let layoutRevision = store.layoutRevision
        var layout = KeepsPhotoGrid.Snapshot()
        layout.update(ids: previous, aspectRatios: previous.map { _ in 1 }, width: 390, density: .compact)
        let originalRows = layout.rows
        let newest = try (999...1019).map { number in
            var asset = try fixture.asset(number)
            asset.captureTime = "2026-02-01"
            return asset
        }
        try database.ingest(newest)
        await store.refresh()
        #expect(store.assets.map(\.id) == newest.map(\.id) + previous)
        #expect(store.layoutRevision == layoutRevision)
        layout.update(ids: store.assets.map(\.id), aspectRatios: store.assets.map { _ in 1 }, width: 390, density: .compact)
        // 屏幕按行倒序展示，旧行及高度不变才能保持原来的像素位置。
        #expect(Array(layout.rows.suffix(originalRows.count)) == originalRows)
        #expect(store.canLoadMore)
        await store.refresh()
        #expect(store.assets.count == 421)
        store.search = "photo-999"
        await store.refresh()
        #expect(store.assets.map(\.id) == [newest[0].id])
    }

    @Test func pagingUsesTheDisplayedBoundaryWhileBackgroundAddsNewerRows() async throws {
        let fixture = ReplicaFixture()
        try fixture.database().ingest((1...450).map { try fixture.asset($0) })
        let browsing = await fixture.store()
        var new = try fixture.asset(999)
        new.captureTime = "2026-02-01"
        try fixture.database().ingest([new])
        await browsing.loadMore()
        #expect(browsing.assets.map(\.id) == (1...400).map { try! fixture.asset($0).id })
        await browsing.loadMore()
        #expect(browsing.assets.count == 450)
        #expect(!browsing.canLoadMore)
    }

    @Test func browsingWindowStaysBoundedAndCanReturnToNewest() async throws {
        let fixture = ReplicaFixture()
        let store = await fixture.store()
        try fixture.database().ingest((1...2400).map { try fixture.asset($0) })
        await store.refresh()
        for _ in 0..<11 { await store.loadMore() }
        #expect(store.assets.count == 1000)
        #expect(store.assets.first?.id == (try fixture.asset(1401)).id)
        #expect(!store.canLoadMore)
        #expect(store.canLoadNewer)
        let window = store.assets.map(\.id)
        await store.refresh()
        #expect(store.assets.map(\.id) == window)
        for _ in 0..<7 { await store.loadNewer() }
        #expect(store.assets.count == 1000)
        #expect(store.assets.first?.id == (try fixture.asset(1)).id)
        #expect(!store.canLoadNewer)
        #expect(store.canLoadMore)
    }

    @Test func restoresEvictedAnchorsWithCorrectBidirectionalBoundaries() async throws {
        let fixture = ReplicaFixture()
        let store = await fixture.store()
        try fixture.database().ingest((1...2400).map { try fixture.asset($0) })
        await store.refresh()
        #expect(await store.restoreWindow(around: try fixture.asset(1200)))
        #expect(store.assets.map(\.id) == (1000...1399).map { try! fixture.asset($0).id })
        #expect(store.canLoadNewer)
        #expect(store.canLoadMore)
        #expect(await store.restoreWindow(around: try fixture.asset(1)))
        #expect(store.assets.count == 200)
        #expect(!store.canLoadNewer)
        #expect(store.canLoadMore)
        #expect(await store.restoreWindow(around: try fixture.asset(2400)))
        #expect(store.assets.count == 201)
        #expect(store.canLoadNewer)
        #expect(!store.canLoadMore)
        let before = store.assets
        #expect(await store.restoreWindow(around: try fixture.asset(2400)))
        #expect(store.assets == before)
    }

    @Test func restorationDoesNotResurrectMissingOrFilteredPhotosOrOverwriteNewScope() async throws {
        let fixture = ReplicaFixture()
        let store = await fixture.store()
        try fixture.database().ingest((1...600).map { try fixture.asset($0) })
        await store.refresh()
        #expect(!(await store.restoreWindow(around: try fixture.asset(999))))
        store.search = "photo-600"
        await store.refresh()
        #expect(!(await store.restoreWindow(around: try fixture.asset(1))))
        #expect(store.assets.map(\.originalFilename) == ["photo-600"])
        store.search = ""
        await store.refresh()
        let restoring = Task { await store.restoreWindow(around: try fixture.asset(500)) }
        await Task.yield()
        store.search = "photo-1"
        await store.refresh()
        _ = try await restoring.value
        #expect(store.assets.allSatisfy { $0.originalFilename.contains("photo-1") })
    }

    @Test func overlappingPagingAndFilterChangesDoNotPublishStaleResults() async throws {
        let fixture = ReplicaFixture()
        let store = await fixture.store()
        try fixture.database().ingest((1...600).map { try fixture.asset($0) })
        await store.refresh()
        async let first: Void = store.loadMore()
        async let duplicate: Void = store.loadMore()
        _ = await (first, duplicate)
        #expect(store.assets.count == 400)
        #expect(Set(store.assets.map(\.id)).count == 400)
        let oldRead = Task { await store.loadMore() }
        await Task.yield()
        store.search = "photo-600"
        await store.refresh()
        await oldRead.value
        #expect(store.assets.map(\.originalFilename) == ["photo-600"])
        #expect(!store.canLoadNewer)
    }

    @Test func startupSynchronizationSkipsUnchangedAssetsAndKeepsOfflineContent() async throws {
        let fixture = ReplicaFixture()
        let store = await fixture.store()
        await store.synchronize()
        #expect(store.assets.count == 1)
        #expect(try fixture.database().revision == 1)
        let requests = fixture.requests.count
        let reopened = await fixture.store()
        #expect(reopened.assets.count == 1)
        await reopened.synchronize()
        #expect(Array(fixture.requests.dropFirst(requests)) == ["GET /libraries/library/revision"])
        fixture.offline = true
        await reopened.synchronize()
        #expect(reopened.assets.count == 1)
        #expect(reopened.syncError != nil)
        #expect(!reopened.isSyncing)
    }

    @Test func singlePackageRebuildReplacesCatalogWhileNASIsUpdating() async throws {
        let fixture = ReplicaFixture()
        fixture.updating = true
        let store = await fixture.store()
        try fixture.database().ingest([fixture.asset(99)])
        await store.synchronize()
        #expect(store.syncError == nil)
        #expect(store.assets.map(\.originalFilename) == ["photo-1"])
        #expect(try fixture.database().revision == 1)
        #expect(fixture.requests.count == 4)
        #expect(fixture.requests[0].contains("revision"))
        #expect(fixture.requests[1] == "POST /libraries/library/offline-rebuild")
        #expect(fixture.requests[2].hasSuffix("/download"))
        #expect(try fixture.database().hiddenDirectories() == ["/private"])
        #expect(try fixture.database().navigation() != nil)
        store.showingTrash = true
        await store.refresh()
        #expect(store.assets.map(\.originalFilename) == ["photo-2"])
    }

    @Test func failedDownloadPreservesExistingCatalogAndRevision() async throws {
        let fixture = ReplicaFixture()
        let store = await fixture.store()
        let database = try fixture.database()
        try database.beginSync()
        try database.ingest([fixture.asset(99)])
        try database.completeSync(revision: 0, isStable: true)
        fixture.failDownload = true
        await store.synchronize()
        #expect(store.syncError != nil)
        #expect(try database.revision == 0)
        #expect(store.assets.map(\.originalFilename) == ["photo-99"])
        fixture.failDownload = false
        await store.synchronize()
        #expect(store.syncError == nil)
        #expect(store.assets.map(\.originalFilename) == ["photo-1"])
    }

    @Test func cancellationBeforeDownloadCompletesPreservesOldCatalogAndCanRetry() async throws {
        let fixture = ReplicaFixture()
        let store = await fixture.store()
        try fixture.database().beginSync()
        try fixture.database().ingest([fixture.asset(99)])
        try fixture.database().completeSync(revision: 0, isStable: true)
        await store.refresh()
        ReplicaProtocol.delayDownload(host: fixture.configuration.baseURL.host!)
        let sync = Task { await store.synchronize() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !fixture.requests.contains(where: { $0.hasSuffix("/download") }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(fixture.requests.contains(where: { $0.hasSuffix("/download") }))
        sync.cancel()
        await sync.value
        #expect(!store.isSyncing)
        #expect(store.syncError == nil)
        #expect(try fixture.database().revision == 0)
        #expect(store.assets.map(\.originalFilename) == ["photo-99"])
        await store.synchronize()
        #expect(store.syncError == nil)
        #expect(store.assets.map(\.originalFilename) == ["photo-1"])
    }

    @Test func interruptedNASBuildResumesPersistedJobAfterAppRelaunch() async throws {
        let fixture = ReplicaFixture()
        fixture.building = true
        let store = await fixture.store()
        let sync = Task { await store.synchronize(includeThumbnails: false) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !fixture.requests.contains("POST /libraries/library/offline-rebuild"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(fixture.requests.contains("POST /libraries/library/offline-rebuild"))
        sync.cancel()
        await sync.value
        #expect(!store.hasLocalCatalog)
        fixture.building = false
        let reopened = await fixture.store()
        await reopened.synchronize(includeThumbnails: false)
        #expect(reopened.syncError == nil)
        #expect(reopened.hasLocalCatalog)
        #expect(fixture.requests.filter { $0 == "POST /libraries/library/offline-rebuild" }.count == 1)
        #expect(fixture.requests.filter { $0.hasSuffix("/download") }.count == 1)
    }

    @Test func repeatedForegroundSynchronizationCoalescesOneDownload() async throws {
        let fixture = ReplicaFixture()
        let store = await fixture.store()
        ReplicaProtocol.delayDownload(host: fixture.configuration.baseURL.host!)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 { group.addTask { await store.synchronize() } }
        }
        #expect(store.syncError == nil)
        #expect(!store.isSyncing)
        #expect(store.assets.map(\.originalFilename) == ["photo-1"])
        #expect(fixture.requests.filter { $0 == "POST /libraries/library/offline-rebuild" }.count == 1)
        #expect(fixture.requests.filter { $0.hasSuffix("/download") }.count == 1)
        let before = fixture.requests.count
        for _ in 0..<10 { await store.synchronize() }
        #expect(Array(fixture.requests.dropFirst(before)) == Array(repeating: "GET /libraries/library/revision", count: 10))
    }

    @Test func connectionSwitchDuringDownloadCannotPublishOldCatalog() async throws {
        let fixture = ReplicaFixture()
        let store = await fixture.store()
        ReplicaProtocol.delayDownload(host: fixture.configuration.baseURL.host!)
        let sync = Task { await store.synchronize() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !fixture.requests.contains(where: { $0.hasSuffix("/download") }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(fixture.requests.contains(where: { $0.hasSuffix("/download") }))
        var other = fixture.configuration
        other.accessCredential = "switched"
        store.configure(other)
        await store.waitForLocalLoad()
        await sync.value
        #expect(store.configuration == other)
        #expect(store.assets.isEmpty)
        #expect(store.timeline.isEmpty)
        #expect(!store.isSyncing)
        #expect(store.syncError == nil)
        #expect(!store.hasLocalCatalog)
        store.configure(fixture.configuration)
        await store.waitForLocalLoad()
        await store.synchronize()
        #expect(store.assets.map(\.originalFilename) == ["photo-1"])
        #expect(store.syncError == nil)
    }

    @Test func repeatedOfflineForegroundRetriesRetainBrowsableCatalog() async throws {
        let fixture = ReplicaFixture()
        let store = await fixture.store()
        await store.synchronize()
        let expected = store.assets.map(\.id)
        fixture.offline = true
        for _ in 0..<10 {
            await store.synchronize()
            await store.refresh()
            #expect(store.assets.map(\.id) == expected)
            #expect(store.syncError != nil)
            #expect(!store.isSyncing)
            #expect(store.hasLocalCatalog)
        }
        fixture.offline = false
        await store.synchronize()
        #expect(store.syncError == nil)
        #expect(store.assets.map(\.id) == expected)
        #expect(fixture.requests.filter { $0 == "POST /libraries/library/offline-rebuild" }.count == 1)
    }

    @Test func firstSynchronizationCanBuildTimelineWithoutBundledThumbnails() async throws {
        let fixture = ReplicaFixture()
        let store = await fixture.store()
        #expect(try fixture.database().revision == nil)
        try await store.synchronizeChecked(includeThumbnails: false)
        #expect(fixture.thumbnailModes == [false])
        #expect(try fixture.database().revision == 1)
        #expect(store.timeline.map(\.id) == [try fixture.asset(1).id])
        #expect(store.timeline.first?.thumbnail == nil)
        #expect(store.timeline.first?.browseThumbnail == nil)
        #expect(store.assets.map(\.originalFilename) == ["photo-1"])
        #expect(!store.isSyncing)
    }

    @Test func onlyInitializationRequestsBundledThumbnails() async throws {
        let fixture = ReplicaFixture()
        let store = await fixture.store()
        await store.synchronize()
        #expect(fixture.thumbnailModes == [true])
        try fixture.database().completeSync(revision: 0, isStable: true)
        await store.synchronize()
        #expect(fixture.thumbnailModes == [true, false])
        try fixture.database().beginSync(checkpoint: .init(revision: 1, stable: true))
        await store.synchronize()
        #expect(fixture.thumbnailModes == [true, false, true])
    }

    @Test func forceRebuildDownloadsEvenWhenRevisionMatches() async throws {
        let fixture = ReplicaFixture()
        let store = await fixture.store()
        await store.synchronize()
        let before = fixture.requests.count
        await store.synchronize(forceRebuild: true)
        #expect(store.syncError == nil)
        #expect(fixture.requests.dropFirst(before).contains("POST /libraries/library/offline-rebuild"))
    }

    @Test func completedBackgroundSyncPublishesLocalChanges() async throws {
        let fixture = ReplicaFixture()
        try fixture.database().ingest((1...450).map { try fixture.asset($0) })
        let browsing = await fixture.store()
        await browsing.synchronize()
        #expect(browsing.assets.map(\.originalFilename) == ["photo-1"])
        #expect(try fixture.database().assets(query: KeepsAssetQuery()).items.count == 1)
        await browsing.refresh()
        #expect(browsing.assets.map(\.originalFilename) == ["photo-1"])
    }

    @Test func oldServerFailsExplicitlyWithoutPaginationFallback() async throws {
        let fixture = ReplicaFixture()
        fixture.unsupported = true
        let store = await fixture.store()
        await store.synchronize()
        #expect(store.syncError != nil)
        #expect(try fixture.database().revision == nil)
        #expect(fixture.requests.count == 2)
        #expect(!fixture.requests.contains { $0.contains("/assets") || $0.contains("navigation") })
    }

    @Test func serverMutationPersistsAndCredentialSwitchCannotShowPreviousLibrary() async throws {
        let fixture = ReplicaFixture()
        let store = await fixture.store()
        await store.synchronize()
        var asset = try #require(store.assets.first)
        asset.trashed = true
        await store.update(asset)
        let reopened = await fixture.store()
        #expect(reopened.assets.isEmpty)
        reopened.showingTrash = true
        await reopened.refresh()
        #expect(reopened.assets.first?.id == asset.id)
        var other = fixture.configuration
        other.accessCredential = "other"
        reopened.configure(other)
        #expect(reopened.assets.isEmpty)
    }
}

private final class ReplicaFixture: @unchecked Sendable {
    let configuration: KeepsConfiguration
    let session: URLSession
    let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private let lock = NSLock()
    private var recorded: [String] = []
    private var isOffline = false
    private var isBuilding = false
    var building: Bool { get { lock.withLock { isBuilding } } set { lock.withLock { isBuilding = newValue } } }
    private var isUpdating = false
    var syncGeneration: String?
    var ackStatus = 200
    var continuouslyChanging = false
    private var serverRevision: Int64 = 1
    private var modes: [Bool] = []
    var thumbnailModes: [Bool] { lock.withLock { modes } }
    private var downloadFails = false
    private var isUnsupported = false
    private var archive: Data?
    private let jobID = UUID()
    var requests: [String] { lock.withLock { recorded } }
    var offline: Bool { get { lock.withLock { isOffline } } set { lock.withLock { isOffline = newValue } } }
    var updating: Bool { get { lock.withLock { isUpdating } } set { lock.withLock { isUpdating = newValue } } }
    var failDownload: Bool { get { lock.withLock { downloadFails } } set { lock.withLock { downloadFails = newValue } } }
    var unsupported: Bool { get { lock.withLock { isUnsupported } } set { lock.withLock { isUnsupported = newValue } } }

    init() {
        let host = UUID().uuidString.lowercased() + ".invalid"
        configuration = KeepsConfiguration(baseURL: URL(string: "https://\(host)")!, libraryID: "library", accessCredential: "initial")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReplicaProtocol.self]
        session = URLSession(configuration: config)
        ReplicaProtocol.register(host: host) { [weak self] request in self!.response(request) }
    }
    deinit {
        ReplicaProtocol.remove(host: configuration.baseURL.host!)
        session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: root)
    }
    func database() throws -> KeepsLibraryDatabase {
        try KeepsLibraryDatabase(configuration: configuration, rootDirectory: root)
    }
    @MainActor func store() async -> IOSLibraryStore {
        let store = IOSLibraryStore(configuration: configuration, session: session, databaseDirectory: root)
        await store.waitForLocalLoad()
        return store
    }
    func asset(_ id: Int) throws -> KeepsAsset {
        try JSONDecoder().decode(KeepsAsset.self, from: Data(assetJSON(id).utf8))
    }
    private func assetJSON(_ id: Int) -> String {
        """
        {"id":"00000000-0000-0000-0000-\(String(format: "%012d", id))","cameraMake":"","cameraModel":"","lensModel":"","originalFilename":"photo-\(id)","contentFingerprint":"hash","metadataFingerprint":"meta","rating":0,"flagState":"unflagged","tags":[],"createdAt":"2026-01-01","updatedAt":"2026-01-01","trashed":false,"paths":["/photos/photo-\(id).jpg"]}
        """
    }
    private func makeArchive() throws -> Data {
        let database = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: root.appendingPathComponent("server"))
        try database.beginSync()
        var trash = try asset(2)
        trash.trashed = true
        try database.ingest([asset(1), trash])
        try database.replaceHiddenDirectories(["/private"])
        try database.saveNavigation(JSONDecoder().decode(KeepsNavigation.self, from: Data("{\"directories\":[]}".utf8)))
        try database.completeSync(revision: serverRevision, isStable: true)
        let snapshot = root.appendingPathComponent("server.sqlite")
        try database.exportSnapshot(to: snapshot)
        if let generation = syncGeneration {
            var db: OpaquePointer?
            guard sqlite3_open(snapshot.path, &db) == SQLITE_OK else { throw URLError(.cannotOpenFile) }
            defer { sqlite3_close(db) }
            guard sqlite3_exec(db, "INSERT OR REPLACE INTO metadata VALUES('generation','\(generation)')", nil, nil, nil) == SQLITE_OK else { throw URLError(.cannotWriteToFile) }
        }
        let extra = syncGeneration.map { ",\"mode\":\"snapshot\",\"generation\":\"\($0)\"" } ?? ""
        let format = syncGeneration == nil ? 1 : 2
        let manifest = Data("{\"formatVersion\":\(format)\(extra),\"libraryID\":\"library\",\"revision\":\(serverRevision),\"assetCount\":2,\"thumbnailCount\":0,\"missingThumbnailCount\":2}".utf8)
        var result = Data()
        for (name, body) in [("manifest.json", manifest), ("catalog.sqlite", try Data(contentsOf: snapshot))] {
            var header = Data(repeating: 0, count: 512)
            func field(_ offset: Int, _ text: String) { header.replaceSubrange(offset..<(offset + text.utf8.count), with: text.utf8) }
            field(0, name)
            field(100, "0000644")
            field(124, String(format: "%011o", body.count))
            field(148, "        ")
            field(156, "0")
            field(257, "ustar")
            field(263, "00")
            field(148, String(format: "%06o", header.reduce(0) { $0 + Int($1) }) + "\0 ")
            result.append(header)
            result.append(body)
            result.append(Data(repeating: 0, count: (512 - body.count % 512) % 512))
        }
        result.append(Data(repeating: 0, count: 1024))
        return result
    }
    private func response(_ request: URLRequest) -> ReplicaResponse {
        lock.withLock {
            let url = request.url!
            recorded.append((request.httpMethod ?? "GET") + " " + url.path + (url.query.map { "?" + $0 } ?? ""))
            if request.httpMethod == "POST" {
                var body = request.httpBody ?? Data()
                if body.isEmpty, let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var bytes = [UInt8](repeating: 0, count: 1024)
                    while true {
                        let count = stream.read(&bytes, maxLength: bytes.count)
                        guard count > 0 else { break }
                        body.append(contentsOf: bytes.prefix(count))
                    }
                }
                if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let mode = json["includeThumbnails"] as? Bool { modes.append(mode) }
            }
            if isOffline { return .text(503, "offline") }
            if url.path.hasSuffix("ack") { return .text(ackStatus, "{}") }
            if url.path.hasSuffix("revision") {
                let extra = syncGeneration.map { ",\"generation\":\"\($0)\"" } ?? ""
                return .text(200, "{\"revision\":\(serverRevision),\"isUpdating\":\(isUpdating)\(extra)}")
            }
            if isUnsupported { return .text(404, "unsupported") }
            if isBuilding {
                return .text(200, "{\"id\":\"\(jobID.uuidString)\",\"state\":\"building\",\"phase\":\"catalog\",\"completed\":0,\"total\":1}")
            }
            do {
                if archive == nil { archive = try makeArchive() }
                let data = archive!
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                if url.path.hasSuffix("download") {
                    if continuouslyChanging { serverRevision += 1; archive = nil }
                    if downloadFails { return .text(503, "download unavailable") }
                    if let range = request.value(forHTTPHeaderField: "Range"),
                       let offset = Int(range.replacingOccurrences(of: "bytes=", with: "").dropLast()),
                       offset >= 0, offset < data.count {
                        let body = data.subdata(in: offset..<data.count)
                        return ReplicaResponse(status: 206, body: body, headers: [
                            "Content-Length": String(body.count), "ETag": "\"\(digest)\"",
                            "Content-Range": "bytes \(offset)-\(data.count - 1)/\(data.count)"
                        ])
                    }
                    return ReplicaResponse(status: 200, body: data, headers: ["Content-Length": String(data.count), "ETag": "\"\(digest)\""])
                }
                return .text(200, "{\"id\":\"\(jobID.uuidString)\",\"state\":\"ready\",\"phase\":\"archive\",\"completed\":1,\"total\":1,\"revision\":1,\"byteCount\":\(data.count),\"sha256\":\"\(digest)\"}")
            } catch { return .text(500, String(describing: error)) }
        }
    }
}

private struct ReplicaResponse: Sendable {
    let status: Int
    let body: Data
    let headers: [String: String]
    static func text(_ status: Int, _ text: String) -> Self {
        Self(status: status, body: Data(text.utf8), headers: ["Content-Length": String(text.utf8.count)])
    }
}

private final class ReplicaProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: (URLRequest) -> ReplicaResponse] = [:]
    static func register(host: String, handler: @escaping (URLRequest) -> ReplicaResponse) { lock.withLock { handlers[host] = handler } }
    static func remove(host: String) { _ = lock.withLock { handlers.removeValue(forKey: host) } }
    nonisolated(unsafe) private static var delayedHosts: Set<String> = []
    private let deliveryLock = NSLock()
    private var stopped = false
    static func delayDownload(host: String) { _ = lock.withLock { delayedHosts.insert(host) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let handler = Self.lock.withLock { Self.handlers[request.url!.host!]! }
        let response = handler(request)
        let delay = Self.lock.withLock {
            request.url!.path.hasSuffix("download") == true && Self.delayedHosts.remove(request.url!.host!) != nil
        }
        if delay {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { [self] in deliver(response) }
        } else { deliver(response) }
    }
    private func deliver(_ response: ReplicaResponse) {
        deliveryLock.lock()
        defer { deliveryLock.unlock() }
        guard !stopped else { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: nil, headerFields: response.headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { deliveryLock.withLock { stopped = true } }
}
