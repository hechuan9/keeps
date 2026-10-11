import Foundation
import KeepsAPI
import SwiftUI
import OSLog

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var isStartupReady = false
    @Published private(set) var startupAttempt = 0
    @Published private(set) var startupRetrySeconds: Int?
    @Published private(set) var startupError: String?
    @Published private(set) var startupExhausted = false

    func loadStartupLibrary(sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) async {
        guard !isStartupReady else { return }
        startupExhausted = false
        startupAttempt = 0
        startupRetrySeconds = nil
        startupError = nil
        guard let client, let configuration else {
            startupError = lastError ?? "请设置服务器地址和资料库。"
            return
        }
        let requestedQuery = effectiveQuery
        for attempt in 1...10 {
            guard !Task.isCancelled else { return }
            startupAttempt = attempt
            startupRetrySeconds = nil
            do {
                let summary = try await client.counts(showHidden: requestedQuery.showHidden)
                let page = try await client.assets(query: requestedQuery)
                try Task.checkCancellation()
                guard self.configuration == configuration else { return }
                counts = summary
                countsShowHidden = requestedQuery.showHidden
                lastCountsFetch = Date()
                displayedQuery = requestedQuery
                display(page)
                assetCache.store(page, for: requestedQuery)
                lastAssetFetch = Date()
                startupError = nil
                isStartupReady = true
                setActive(isActive)
                return
            } catch {
                guard !Task.isCancelled, self.configuration == configuration else { return }
                startupError = Self.describe(error)
                Self.navigationLogger.error("Startup library attempt \(attempt) failed: \(String(reflecting: error), privacy: .public)")
            }
            if attempt == 10 {
                startupExhausted = true
                return
            }
            let delay = 1 << (attempt - 1)
            startupRetrySeconds = delay
            do { try await sleep(.seconds(delay)) }
            catch { return }
        }
    }

    @Published var showsRejectedTrash = false
    @Published var rejectedTrashPreview: KeepsRejectedTrashTask?
    var rejectedTrashPreviewConfiguration: KeepsConfiguration?
    @Published var rejectedTrash: PendingRejectedTrash?
    @Published var rejectedTrashMessage: String?
    @Published var rejectedTrashFinished = false
    @Published var isPreparingRejectedTrash = false
    var rejectedTrashTracking: Task<Void, Never>?
    var rejectedTrashPollInterval: Duration = .seconds(1)
    @Published var directoryToCreate: KeepsNavigationDirectory?
    @Published var directoryToRename: KeepsNavigationDirectory?
    @Published var directoryToTrash: KeepsNavigationDirectory?
    @Published var directoryTrash: PendingDirectoryTrash?
    @Published var directoryTrashPhase = "waiting"
    @Published var directoryTrashMessage: String?
    @Published var directoryTrashFinished = false
    var directoryTrashTracking: Task<Void, Never>?
    var directoryTrashPollInterval: Duration = .seconds(1)
    var isDirectoryTrashBlocking: Bool { directoryTrash != nil }
    @Published var directoryMove: PendingDirectoryMove?
    @Published var directoryMovePhase = "waiting"
    @Published var directoryMoveMessage: String?
    @Published var directoryMoveFinished = false
    var directoryMoveTracking: Task<Void, Never>?
    var directoryMovePollInterval: Duration = .seconds(1)
    var isMovingDirectory: Bool { directoryMove != nil }
    @Published var photoMove: PendingPhotoMove?
    @Published var photoMovePhase = "waiting"
    @Published var photoMoveMessage: String?
    @Published var photoMoveFinished = false
    var photoMoveTracking: Task<Void, Never>?
    var photoMovePollInterval: Duration = .seconds(1)
    @Published var openImportWindows: Set<UUID> = []
    @Published var isImportWorkerActive = false
    var isImportingPhotos: Bool { !openImportWindows.isEmpty || isImportWorkerActive }
    @Published var isAIEditingBlocking = false
    @Published var isAISettingsBusy = false
    var isDirectoryOperationBlocking: Bool { isDirectoryTrashBlocking || isMovingDirectory || photoMove != nil || rejectedTrash != nil || isPreparingRejectedTrash }
    var isOperationBlocking: Bool { isDirectoryOperationBlocking || isAIEditingBlocking || isAISettingsBusy }
    @Published private(set) var hiddenDirectoryPaths: Set<String> = []
    @Published private(set) var isUpdatingHiddenDirectory = false
    @Published var hiddenDirectoryFilterEnabled = true {
        didSet {
            guard hiddenDirectoryFilterEnabled != oldValue else { return }
            preferences.set(hiddenDirectoryFilterEnabled, forKey: "keeps.hiddenDirectoryFilterEnabled")
            refresh()
        }
    }
    @Published private(set) var assets: [KeepsAsset] = []
    @Published var selectedIDs: Set<UUID> = []
    @Published private(set) var isSelectingAll = false
    private var selectionAnchor: UUID?
    private var selectionFocus: UUID?
    @Published var query = KeepsAssetQuery() {
        didSet {
            if query != oldValue {
                isSelectingAll = false
                cancelDirectoryPrefetch()
                saveNavigationState()
            }
        }
    }
    @Published private(set) var counts: KeepsCounts?
    @Published private(set) var directories: [KeepsNavigationDirectory] = []
    @Published private(set) var expandedPaths: Set<String> = [] { didSet { saveNavigationState() } }
    @Published private(set) var directoryChildren: [String: [KeepsNavigationDirectory]] = [:]
    @Published private(set) var directoryErrors: [String: String] = [:]
    @Published private(set) var loadingDirectories: Set<String> = []
    @Published private(set) var navigationError: String?
    @Published private(set) var isLoadingNavigation = false
    @Published private(set) var navigationGeneration = 0
    @Published private(set) var total = 0
    @Published private(set) var nextCursor: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isMutating = false
    @Published private(set) var isCheckingRevision = false
    var hasLoadedResults: Bool { displayedPage != nil }
    var hasCurrentPhotoResults: Bool { displayedPage != nil && displayedQuery == effectiveQuery }
    @Published private(set) var configuration: KeepsConfiguration?
    @Published var lastError: String?
    @Published private(set) var isCheckingConnection = false
    @Published private(set) var connectionMessage: String?
    @Published private(set) var connectionError: String?
    private(set) var client: KeepsClient?
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var paginationVisible = false
    private var rootRequestGeneration = 0
    private static let navigationLogger = Logger(subsystem: "local.keeps", category: "navigation")
    let preferences: UserDefaults
    private var restoringNavigation = false
    private struct NavigationState: Codable {
        var expanded: Set<String>
        var directory: String?
        var trashed: Bool
        var picked: Bool
    }
    private var navigationStateKey: String? {
        configuration.map { "keeps.navigation." + $0.baseURL.absoluteString + "|" + $0.libraryID }
    }
    private func saveNavigationState() {
        guard !restoringNavigation, let key = navigationStateKey else { return }
        let state = NavigationState(expanded: expandedPaths, directory: query.directory, trashed: query.trashed, picked: query.flagState == "picked")
        if let data = try? JSONEncoder().encode(state) { preferences.set(data, forKey: key) }
    }
    private func restoreNavigationState() {
        restoringNavigation = true
        defer { restoringNavigation = false }
        expandedPaths = []
        query = KeepsAssetQuery()
        guard let key = navigationStateKey, let data = preferences.data(forKey: key),
              let state = try? JSONDecoder().decode(NavigationState.self, from: data) else { return }
        expandedPaths = state.expanded
        query.directory = state.directory
        query.trashed = state.trashed
        query.flagState = state.picked ? "picked" : nil
    }
    private let session: URLSession
    private let persistConfiguration: (KeepsConfiguration) throws -> Void

    private var countsTask: Task<Void, Never>?
    private var countsGeneration = 0
    private var requestedCountsShowHidden: Bool?
    private var revisionTask: Task<Void, Never>?
    private var isActive = false
    private let assetCache = KeepsAssetCache()
    private var displayedQuery: KeepsAssetQuery?
    private var displayedPage: KeepsAssetPage?
    private var directoryPrefetchTask: Task<Void, Never>?
    private var directoryPrefetchQuery: KeepsAssetQuery?
    private var directoryPrefetchRevision: Int64?
    private var lastAssetFetch = Date.distantPast
    private var lastNavigationFetch = Date.distantPast
    private var lastCountsFetch = Date.distantPast
    private var countsShowHidden: Bool?

    func setActive(_ active: Bool) {
        isActive = active
        revisionTask?.cancel()
        revisionTask = nil
        guard active, configuration != nil, isStartupReady else { return }
        revisionTask = Task {
            while !Task.isCancelled {
                if Date().timeIntervalSince(lastNavigationFetch) >= 300 { refreshNavigation(force: false) }
                if !isLoading && !isMutating { refresh() }
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
            }
        }
    }

    init(
        configuration: KeepsConfiguration? = nil,
        session: URLSession = KeepsClient.apiSession,
        loadSavedSettings: Bool = true,
        preferences: UserDefaults = .standard,
        persistConfiguration: @escaping (KeepsConfiguration) throws -> Void = { value in
            try KeepsSettings.save(baseURLString: value.baseURL.absoluteString, libraryID: value.libraryID, accessCredential: value.accessCredential ?? "")
        }
    ) {
        self.preferences = preferences
        hiddenDirectoryFilterEnabled = preferences.object(forKey: "keeps.hiddenDirectoryFilterEnabled") as? Bool ?? true
        self.session = session
        self.persistConfiguration = persistConfiguration
        do {
            let settings = try configuration ?? (loadSavedSettings ? KeepsSettings.load() : nil)
            self.configuration = settings
            client = settings.map { KeepsClient(configuration: $0, session: session) }
        } catch { lastError = Self.describe(error) }
        restoreNavigationState()
        restoreDirectoryTrash()
        restoreDirectoryMove()
        restorePhotoMove()
        restoreRejectedTrash()
    }

    var selectedAsset: KeepsAsset? { return assets.first { selectedIDs.contains($0.id) } }

    var locationTitle: String {
        if let path = query.directory {
            let root = directories.filter { path == $0.path || path.hasPrefix($0.path + "/") }.max { $0.path.count < $1.path.count }
            if let root {
                let suffix = String(path.dropFirst(root.path.count)).split(separator: "/").joined(separator: " / ")
                return "来源 / " + root.name + (suffix.isEmpty ? "" : " / " + suffix)
            }
            let name = directoryChildren.values.lazy.flatMap { $0 }.first { $0.path == path }?.name
            return "来源 / " + (name ?? path)
        }
        return query.trashed ? "回收站" : query.flagState == "picked" ? "精选" : "全部照片"
    }

    func isDirectoryHidden(_ path: String) -> Bool {
        hiddenDirectoryPaths.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    func setDirectoryHidden(_ path: String, hidden: Bool) {
        guard !isOperationBlocking else { return }
        guard let client, !isUpdatingHiddenDirectory else { return }
        let generation = navigationGeneration
        isUpdatingHiddenDirectory = true
        assetCache.removeAll()
        Task {
            defer { isUpdatingHiddenDirectory = false }
            do {
                let response = try await client.setDirectoryHidden(path: path, hidden: hidden)
                guard generation == navigationGeneration else { return }
                hiddenDirectoryPaths = Set(response.paths)
                refresh(force: true)
            } catch {
                if generation == navigationGeneration { lastError = Self.describe(error) }
            }
        }
    }

    func canMoveDirectory(_ path: String, to parentPath: String) -> Bool {
        guard client != nil, !isOperationBlocking, !isMutating,
              !isUpdatingHiddenDirectory, !isCheckingConnection,
              path.hasPrefix("/"), parentPath.hasPrefix("/"), path != "/",
              path != parentPath, !parentPath.hasPrefix(path + "/"),
              (path as NSString).deletingLastPathComponent != parentPath else { return false }
        return !directories.contains { $0.path == path }
    }

    func completePhotoMove() {
        photoMove = nil
        preferences.removeObject(forKey: "keeps.pendingPhotoMove")
        selectedIDs = []
        assetCache.removeAll()
        displayedQuery = nil
        displayedPage = nil
        refreshNavigation()
        refresh(force: true)
    }

    func completeDirectoryMove(path: String, parentPath: String, destination: String) {
        func relocated(_ value: String) -> String {
            value == path || value.hasPrefix(path + "/") ? destination + value.dropFirst(path.count) : value
        }
        let expanded = Set(expandedPaths.map(relocated)).union([parentPath])
        if let selected = query.directory { query.directory = relocated(selected) }
        assetCache.removeAll()
        displayedQuery = nil
        displayedPage = nil
        resetNavigation()
        expandedPaths = expanded
        directoryMove = nil
        preferences.removeObject(forKey: "keeps.pendingDirectoryMove")
        refreshNavigation()
        refresh(force: true)
    }

    func setDirectoryExpanded(_ path: String, expanded: Bool) {
        guard !isOperationBlocking else { return }
        if expanded {
            expandedPaths.insert(path)
            if directoryErrors[path] == nil { loadChildren(of: path) }
        } else { expandedPaths.remove(path) }
    }

    func showLibrary(directory: String? = nil, trashed: Bool = false, picked: Bool = false) {
        guard !isOperationBlocking else { return }
        var location = KeepsAssetQuery()
        location.directory = directory
        location.recursive = true
        location.trashed = trashed
        location.flagState = picked ? "picked" : nil
        query = location
        refresh()
    }

    private func clearResults() {
        cancelDirectoryPrefetch()
        loadTask?.cancel()
        loadGeneration += 1
        isLoading = false
        paginationVisible = false
        deselectAll()
        assets = []; total = 0; nextCursor = nil; lastError = nil
    }

    @Published private(set) var submittingMetadataRefreshPaths: Set<String> = []

    func refreshDirectoryMetadata(path: String) async -> Bool {
        guard let client, !submittingMetadataRefreshPaths.contains(path) else { return false }
        let requestedConfiguration = configuration
        submittingMetadataRefreshPaths.insert(path)
        defer { submittingMetadataRefreshPaths.remove(path) }
        do {
            _ = try await client.refreshDirectoryMetadata(path: path)
            guard configuration == requestedConfiguration else { return false }
            refreshNavigation()
            loadChildren(of: path, refresh: true)
            refresh(force: true)
            return true
        } catch {
            if configuration == requestedConfiguration { lastError = Self.describe(error) }
            return false
        }
    }

    func refreshNavigation(force: Bool = true) {
        guard !isOperationBlocking else { return }
        guard let client else { return }
        if !force && navigationError == nil && Date().timeIntervalSince(lastNavigationFetch) < 300 { return }
        rootRequestGeneration += 1
        let requestGeneration = rootRequestGeneration
        let generation = navigationGeneration
        lastNavigationFetch = Date()
        isLoadingNavigation = true
        navigationError = nil
        Task {
            defer { if requestGeneration == rootRequestGeneration && generation == navigationGeneration { isLoadingNavigation = false } }
            do {
                let navigation = try await client.navigation()
                let hidden = try await client.hiddenDirectories()
                guard generation == navigationGeneration, requestGeneration == rootRequestGeneration else { return }
                removeMissingDirectories(old: directories, new: navigation.directories)
                hiddenDirectoryPaths = Set(hidden.paths)
                directories = navigation.directories
                reconcileSavedNavigation(with: navigation.directories, parent: nil)
                for directory in navigation.directories where shouldLoadChildren(directory.path) {
                    loadChildren(of: directory.path, refresh: true)
                }
            } catch {
                if generation == navigationGeneration && requestGeneration == rootRequestGeneration { navigationError = Self.describe(error) }
            }
        }
    }

    func loadChildren(of path: String, refresh: Bool = false) {
        guard !isOperationBlocking else { return }
        guard let client, (refresh || directoryChildren[path] == nil), !loadingDirectories.contains(path) else { return }
        let generation = navigationGeneration
        loadingDirectories.insert(path)
        directoryErrors[path] = nil
        let started = ContinuousClock.now
        Self.navigationLogger.info("Directory request started")
        Task {
            defer { if generation == navigationGeneration { loadingDirectories.remove(path) } }
            do {
                let navigation = try await client.navigation(path: path)
                let elapsed = started.duration(to: .now).components
                let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
                Self.navigationLogger.info("Directory request completed in \(milliseconds, privacy: .public) ms; children \(navigation.directories.count, privacy: .public)")
                guard generation == navigationGeneration else { return }
                guard directories.contains(where: { path == $0.path }) || directoryChildren.values.contains(where: { $0.contains(where: { $0.path == path }) }) else { return }
                removeMissingDirectories(old: directoryChildren[path] ?? [], new: navigation.directories)
                directoryChildren[path] = navigation.directories
                reconcileSavedNavigation(with: navigation.directories, parent: path)
                for child in navigation.directories where shouldLoadChildren(child.path) {
                    loadChildren(of: child.path, refresh: refresh)
                }
            } catch {
                let elapsed = started.duration(to: .now).components
                let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
                Self.navigationLogger.error("Directory request failed after \(milliseconds, privacy: .public) ms")
                if generation == navigationGeneration { directoryErrors[path] = Self.describe(error) }
            }
        }
    }

    private func shouldLoadChildren(_ path: String) -> Bool {
        expandedPaths.contains(path) || (query.directory?.hasPrefix(path + "/") ?? false)
    }

    private func reconcileSavedNavigation(with children: [KeepsNavigationDirectory], parent: String?) {
        func survives(_ path: String) -> Bool {
            if let parent, !path.hasPrefix(parent + "/") { return true }
            return children.contains { path == $0.path || path.hasPrefix($0.path + "/") }
        }
        expandedPaths = expandedPaths.filter(survives)
        if let selected = query.directory, !survives(selected) { showLibrary(directory: parent) }
    }

    private func removeMissingDirectories(old: [KeepsNavigationDirectory], new: [KeepsNavigationDirectory]) {
        let removed = Set(old.map(\.path)).subtracting(new.map(\.path))
        for path in removed {
            expandedPaths = expandedPaths.filter { $0 != path && !$0.hasPrefix(path + "/") }
            directoryChildren = directoryChildren.filter { $0.key != path && !$0.key.hasPrefix(path + "/") }
            directoryErrors = directoryErrors.filter { $0.key != path && !$0.key.hasPrefix(path + "/") }
            if let selected = query.directory, selected == path || selected.hasPrefix(path + "/") { showLibrary() }
        }
    }

    func pauseLibraryForDirectoryOperation() {
        cancelDirectoryPrefetch()
        isSelectingAll = false
        loadTask?.cancel()
        loadGeneration += 1
        rootRequestGeneration += 1
        navigationGeneration += 1
        isLoading = false
        isLoadingNavigation = false
        loadingDirectories = []
        isCheckingRevision = false
    }

    func resetNavigation() {
        directoryToTrash = nil
        navigationGeneration += 1
        rootRequestGeneration += 1
        directories = []; directoryChildren = [:]; directoryErrors = [:]
        loadingDirectories = []
        navigationError = nil
        hiddenDirectoryPaths = []
    }

    func clearConnectionFeedback() {
        connectionMessage = nil
        connectionError = nil
    }

    @discardableResult
    func checkConnection(baseURL: String, libraryID: String, accessCredential: String, save: Bool) async -> Bool {
        guard !isOperationBlocking, !isCheckingConnection else { return false }
        isCheckingConnection = true
        clearConnectionFeedback()
        defer { isCheckingConnection = false }
        do {
            let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let library = libraryID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: base), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  !library.isEmpty else { throw KeepsAPIError.invalidConfiguration }
            let credential = accessCredential.trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate = KeepsConfiguration(baseURL: url, libraryID: library, accessCredential: credential.isEmpty ? nil : credential)
            let candidateClient = KeepsClient(configuration: candidate, session: session)
            _ = try await candidateClient.counts()
            var probe = KeepsAssetQuery()
            probe.limit = 1
            _ = try await candidateClient.assets(query: probe)
            try Task.checkCancellation()
            if save {
                try persistConfiguration(candidate)
                configuration = candidate
                client = candidateClient
                clearResults()
                assetCache.removeAll()
                displayedQuery = nil
                displayedPage = nil
                countsTask?.cancel()
                countsTask = nil
                countsGeneration += 1
                lastCountsFetch = .distantPast
                lastNavigationFetch = .distantPast
                setActive(isActive)
                assets = []; selectedIDs = []; counts = nil
                resetNavigation()
                restoreNavigationState()
                refreshNavigation()
                refresh()
                connectionMessage = "已连接并保存 Keeps Server。"
            } else {
                connectionMessage = "连接成功，服务鉴权与资料库 API 均可用。"
            }
            return true
        } catch {
            connectionError = Self.describe(error)
            return false
        }
    }

    private var effectiveQuery: KeepsAssetQuery {
        var value = query
        value.cursor = nil
        value.showHidden = !hiddenDirectoryFilterEnabled
        return value
    }

    private func display(_ page: KeepsAssetPage) {
        displayedPage = page
        assets = page.items
        total = page.total
        nextCursor = page.nextCursor
        startDirectoryPrefetch(page)
        let available = Set(assets.map(\.id))
        selectedIDs.formIntersection(available)
        if let selectionAnchor, !available.contains(selectionAnchor) { self.selectionAnchor = nil }
        if let selectionFocus, !available.contains(selectionFocus) { self.selectionFocus = nil }
        if isSelectingAll {
            selectedIDs = available
            selectionAnchor = assets.first?.id
            selectionFocus = assets.last?.id
        }
    }

    private func cancelDirectoryPrefetch() {
        directoryPrefetchTask?.cancel()
        directoryPrefetchTask = nil
        directoryPrefetchQuery = nil
        directoryPrefetchRevision = nil
    }

    private func startDirectoryPrefetch(_ page: KeepsAssetPage) {
        let requested = effectiveQuery
        guard let configuration, requested.directory != nil, page.total < 10_000 else {
            cancelDirectoryPrefetch()
            return
        }
        guard directoryPrefetchQuery != requested || directoryPrefetchRevision != page.revision else { return }
        cancelDirectoryPrefetch()
        directoryPrefetchQuery = requested
        directoryPrefetchRevision = page.revision
        directoryPrefetchTask = Task(priority: .background) {
            do {
                try await ThumbnailPrefetch.shared.runDirectory(configuration: configuration, query: requested, firstPage: page)
            } catch {
                guard !Task.isCancelled else { return }
                Self.navigationLogger.error("Directory thumbnail prefetch failed: \(String(reflecting: error), privacy: .public)")
                directoryPrefetchQuery = nil
                directoryPrefetchRevision = nil
            }
        }
    }

    func refresh(force: Bool = false) {
        guard !isOperationBlocking else { return }
        guard let client else { isLoading = false; return }
        let requestedQuery = effectiveQuery
        let changedQuery = displayedQuery != requestedQuery
        if !changedQuery && (isMutating || (isLoading && !force)) { return }
        loadTask?.cancel()
        loadGeneration += 1
        if changedQuery {
            clearResults()
            displayedQuery = requestedQuery
            displayedPage = nil
            if let cached = assetCache.page(for: requestedQuery) { display(cached) }
        }
        let requestGeneration = loadGeneration
        if force { assetCache.removeAll() }
        let targetCount = max(assets.count, 1)
        isLoading = true
        isCheckingRevision = !force && displayedPage != nil
        lastError = nil
        loadTask = Task {
            defer { finishLoading(generation: requestGeneration) }
            do {
                var needsFetch = force || displayedPage == nil
                if !force {
                    let revision = try await client.revision(path: requestedQuery.directory)
                    try Task.checkCancellation()
                    guard requestGeneration == loadGeneration else { return }
                    needsFetch = displayedPage.map { !$0.isCurrent(at: revision) } ?? true
                    if !changedQuery, let current = displayedPage, revision.isUpdating && current.isUpdating && revision.revision == current.revision
                        && Date().timeIntervalSince(lastAssetFetch) < 30 { needsFetch = false }
                }
                isCheckingRevision = false
                if needsFetch {
                    var nextQuery = requestedQuery
                    var combined = try await client.assets(query: nextQuery)
                    while combined.items.count < targetCount, let cursor = combined.nextCursor {
                        nextQuery.cursor = cursor
                        let next = try await client.assets(query: nextQuery)
                        guard next.revision == combined.revision else {
                            combined = try await client.assets(query: requestedQuery)
                            break
                        }
                        let known = Set(combined.items.map(\.id))
                        combined = KeepsAssetPage(items: combined.items + next.items.filter { !known.contains($0.id) }, total: next.total,
                            nextCursor: next.nextCursor, revision: next.revision, isUpdating: combined.isUpdating || next.isUpdating)
                    }
                    try Task.checkCancellation()
                    guard requestGeneration == loadGeneration else { return }
                    display(combined)
                    assetCache.store(combined, for: requestedQuery)
                    lastAssetFetch = Date()
                }
                refreshCounts(client: client, showHidden: requestedQuery.showHidden, force: force)
            } catch {
                if !Task.isCancelled && requestGeneration == loadGeneration { lastError = Self.describe(error) }
            }
        }
    }

    func setPaginationVisible(_ visible: Bool) {
        paginationVisible = visible
        if visible { loadMoreIfNeeded() }
    }

    private func refreshCounts(client: KeepsClient, showHidden: Bool, force: Bool) {
        guard force || counts == nil || countsShowHidden != showHidden || Date().timeIntervalSince(lastCountsFetch) >= 60 else { return }
        if countsTask != nil, !force, requestedCountsShowHidden == showHidden { return }
        countsTask?.cancel()
        countsGeneration += 1
        let generation = countsGeneration
        requestedCountsShowHidden = showHidden
        countsTask = Task {
            defer { if generation == countsGeneration { countsTask = nil } }
            do {
                let summary = try await client.counts(showHidden: showHidden)
                try Task.checkCancellation()
                guard generation == countsGeneration, effectiveQuery.showHidden == showHidden else { return }
                counts = summary
                countsShowHidden = showHidden
                lastCountsFetch = Date()
            } catch {
                if !Task.isCancelled && generation == countsGeneration { lastError = Self.describe(error) }
            }
        }
    }

    private func loadMoreIfNeeded() {
        guard paginationVisible || isSelectingAll, lastError == nil else { return }
        loadMore()
    }

    private func finishLoading(generation: Int) {
        guard generation == loadGeneration else { return }
        isLoading = false
        isCheckingRevision = false
        if nextCursor == nil || lastError != nil { isSelectingAll = false }
        loadMoreIfNeeded()
    }

    func loadMore() {
        guard !isOperationBlocking else { return }
        guard let client, let cursor = nextCursor, !isLoading, displayedQuery == effectiveQuery else { return }
        let generation = loadGeneration
        var requestedQuery = query
        requestedQuery.cursor = cursor
        requestedQuery.showHidden = !hiddenDirectoryFilterEnabled
        isLoading = true
        lastError = nil
        loadTask = Task {
            defer { finishLoading(generation: generation) }
            do {
                let page = try await client.assets(query: requestedQuery)
                try Task.checkCancellation()
                guard generation == loadGeneration else { return }
                guard let current = displayedPage, current.revision == page.revision else {
                    isLoading = false
                    refresh(force: true)
                    return
                }
                let known = Set(assets.map(\.id))
                let combined = KeepsAssetPage(items: assets + page.items.filter { !known.contains($0.id) },
                    total: page.total, nextCursor: page.nextCursor, revision: page.revision, isUpdating: current.isUpdating || page.isUpdating)
                display(combined)
                assetCache.store(combined, for: effectiveQuery)
            } catch {
                if !Task.isCancelled && generation == loadGeneration { lastError = Self.describe(error) }
            }
        }
    }

    func select(_ id: UUID, extending: Bool = false, range: Bool = false) {
        guard !isOperationBlocking,
              let target = assets.firstIndex(where: { $0.id == id }) else { return }
        isSelectingAll = false
        if range, let anchor = selectionAnchor,
           let start = assets.firstIndex(where: { $0.id == anchor }) {
            let ids = Set(assets[min(start, target)...max(start, target)].map(\.id))
            if extending { selectedIDs.formUnion(ids) } else { selectedIDs = ids }
        } else {
            if extending {
                if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
            } else { selectedIDs = [id] }
            selectionAnchor = id
        }
        selectionFocus = id
    }

    func selectAdjacent(_ offset: Int, extending: Bool = false) {
        guard !isOperationBlocking, !assets.isEmpty else { return }
        let focus = selectionFocus.flatMap { id in assets.firstIndex { $0.id == id } }
        let selected = assets.firstIndex { selectedIDs.contains($0.id) }
        let index = focus ?? selected
        let target = index.map { min(max($0 + offset, 0), assets.count - 1) } ?? (offset < 0 ? assets.count - 1 : 0)
        select(assets[target].id, range: extending)
    }

    func selectAll() {
        guard !isOperationBlocking, client != nil, displayedQuery == effectiveQuery else { return }
        isSelectingAll = isLoading || nextCursor != nil
        selectedIDs = Set(assets.map(\.id))
        selectionAnchor = assets.first?.id
        selectionFocus = assets.last?.id
        loadMoreIfNeeded()
    }

    func deselectAll() {
        guard !isOperationBlocking else { return }
        isSelectingAll = false
        selectedIDs = []
        selectionAnchor = nil
        selectionFocus = nil
    }

    func updateSelected(_ patch: KeepsAssetPatch) {
        mutateSelected { client, id in try await client.updateAsset(id: id, patch: patch) }
    }

    func restoreSelected() { mutateSelected(refreshDirectories: true) { client, id in try await client.restoreAsset(id: id) } }

    private func mutateSelected(refreshDirectories: Bool = false, _ mutation: @escaping @Sendable (KeepsClient, UUID) async throws -> KeepsAsset) {
        guard !isOperationBlocking, !isSelectingAll, let client, !isMutating, !selectedIDs.isEmpty else { return }
        let ids = selectedIDs
        loadTask?.cancel()
        loadGeneration += 1
        isLoading = false
        isCheckingRevision = false
        let generation = loadGeneration
        isMutating = true
        assetCache.removeAll()
        lastError = nil
        Task {
            defer { isMutating = false; assetCache.removeAll() }
            var completed = 0
            do {
                for id in ids {
                    let updated = try await mutation(client, id)
                    if generation == loadGeneration, let index = assets.firstIndex(where: { $0.id == id }) { assets[index] = updated }
                    completed += 1
                }
                isMutating = false
                if generation == loadGeneration { refresh(force: true); if refreshDirectories { refreshNavigation() } }
            } catch { if generation == loadGeneration { lastError = "已完成 \(completed)/\(ids.count) 项。\n" + Self.describe(error) } }
        }
    }

    func refreshPreview(id: UUID) async throws -> URL {
        guard !isOperationBlocking, let client else { throw KeepsAPIError.invalidConfiguration }
        return try await client.refreshPreview(assetID: id)
    }

    static func describe(_ error: Error) -> String {
        String(reflecting: error) + "\n" + error.localizedDescription
    }
}
