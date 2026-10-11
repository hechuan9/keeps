import Foundation
import AppKit
import Testing
import KeepsAPI
@testable import PhotoAssetManager

@MainActor struct RemoteLibraryTests {
    @Test func metadataRefreshTargetsRightClickedDirectoryWithoutChangingSelection() async throws {
        _ = NSApplication.shared
        let store = LibraryStore(configuration: KeepsConfiguration(baseURL: URL(string: "https://tree.invalid")!, libraryID: "test"), session: stubSession(), loadSavedSettings: false)
        store.refreshNavigation()
        try await waitUntil { !store.isLoadingNavigation }
        store.query.directory = "root"
        let outline = DirectoryOutlineView.DirectoryOutline()
        let column = NSTableColumn(identifier: .init("directory"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        let coordinator = DirectoryOutlineView.Coordinator(library: store)
        coordinator.outline = outline
        outline.dataSource = coordinator
        outline.delegate = coordinator
        coordinator.update()
        var openedTracking = false
        coordinator.openTaskWindow = { openedTracking = true }
        let clicked = try #require(outline.item(atRow: 1))
        let menu = try #require(coordinator.contextMenu(for: clicked))
        let entry = try #require(menu.items.first { $0.title == "刷新目录全部元数据" })
        #expect(!openedTracking)
        #expect(NSApp.sendAction(try #require(entry.action), to: entry.target, from: entry))
        try await waitUntil { openedTracking }
        #expect(store.query.directory == "root")
        #expect(outline.selectedRow == -1)
        #expect(store.submittingMetadataRefreshPaths.isEmpty)
        #expect(!store.isDirectoryOperationBlocking)
    }

    @Test func startupPublishesLibraryOnlyAfterSuccessfulLoad() async {
        let store = LibraryStore(configuration: KeepsConfiguration(baseURL: URL(string: "https://nas.invalid")!, libraryID: "test"), session: stubSession(), loadSavedSettings: false)
        #expect(!store.isStartupReady)
        await store.loadStartupLibrary(sleep: { _ in Issue.record("successful startup should not retry") })
        #expect(store.isStartupReady)
        #expect(store.hasLoadedResults)
        #expect(store.counts != nil)
        #expect(store.startupAttempt == 1)
        #expect(!store.startupExhausted)
    }

    @Test func startupStopsAfterTenFailuresWithExponentialBackoff() async {
        let store = LibraryStore(configuration: KeepsConfiguration(baseURL: URL(string: "https://unauthorized.invalid")!, libraryID: "test"), session: stubSession(), loadSavedSettings: false)
        var delays: [Duration] = []
        await store.loadStartupLibrary(sleep: { delays.append($0) })
        #expect(delays == [1, 2, 4, 8, 16, 32, 64, 128, 256].map { Duration.seconds($0) })
        #expect(store.startupAttempt == 10)
        #expect(store.startupExhausted)
        #expect(!store.isStartupReady)
        #expect(!store.hasLoadedResults)
        #expect(store.startupError != nil)
    }

    @Test func cancelledStartupDoesNotExhaustRetriesAndCanResume() async {
        let store = LibraryStore(configuration: KeepsConfiguration(baseURL: URL(string: "https://unauthorized.invalid")!, libraryID: "test"), session: stubSession(), loadSavedSettings: false, persistConfiguration: { _ in })
        await store.loadStartupLibrary(sleep: { _ in throw CancellationError() })
        #expect(store.startupAttempt == 1)
        #expect(!store.startupExhausted)
        #expect(!store.isStartupReady)
        let saved = await store.checkConnection(baseURL: "https://nas.invalid", libraryID: "test", accessCredential: "", save: true)
        #expect(saved)
        #expect(!store.isStartupReady)
        try? await waitUntil { !store.isLoading }
        await store.loadStartupLibrary()
        #expect(store.isStartupReady)
        #expect(store.startupAttempt == 1)
    }

    @Test func directoryTrashMenuTargetsClickedFolderAndRejectsWrongConfirmation() async throws {
        _ = NSApplication.shared
        let store = LibraryStore(configuration: KeepsConfiguration(baseURL: URL(string: "https://tree.invalid")!, libraryID: "test"), session: stubSession(), loadSavedSettings: false)
        store.refreshNavigation()
        try await waitUntil { !store.isLoadingNavigation }
        let outline = DirectoryOutlineView.DirectoryOutline()
        let column = NSTableColumn(identifier: .init("directory"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        let coordinator = DirectoryOutlineView.Coordinator(library: store)
        coordinator.outline = outline
        outline.dataSource = coordinator
        outline.delegate = coordinator
        coordinator.update()
        let clicked = try #require(outline.item(atRow: 1))
        let menu = try #require(coordinator.contextMenu(for: clicked))
        let entry = try #require(menu.items.first { $0.title == "删除文件夹…" })
        #expect(store.directoryToTrash == nil)
        #expect(NSApp.sendAction(try #require(entry.action), to: entry.target, from: entry))
        let directory = try #require(store.directoryToTrash)
        #expect(directory.path == "other")
        #expect(outline.selectedRow == -1)
        do {
            try await store.trashDirectory(directory, confirmationName: "other ")
            Issue.record("mismatched name must be rejected")
        } catch {
            #expect(store.directoryToTrash?.path == "other")
        }
    }

    @Test func directoryTrashRefreshesNavigationAndLeavesDeletedScope() async throws {
        let store = LibraryStore(configuration: KeepsConfiguration(baseURL: URL(string: "https://directory-trash.invalid")!, libraryID: "test"), session: stubSession(), loadSavedSettings: false, preferences: UserDefaults(suiteName: UUID().uuidString)!)
        store.refreshNavigation()
        try await waitUntil { !store.isLoadingNavigation }
        let directory = try #require(store.directories.first)
        store.showLibrary(directory: directory.path + "/child")
        try await waitUntil { !store.isLoading }
        let generation = store.navigationGeneration
        try await store.trashDirectory(directory, confirmationName: directory.name)
        try await waitUntil { !store.isLoading && !store.isLoadingNavigation }
        #expect(store.query.directory == nil)
        #expect(store.navigationGeneration > generation)
        #expect(store.directories.isEmpty)
        #expect(store.selectedIDs.isEmpty)
        #expect(store.lastError == nil)
    }

    @Test func directoryCountRemainsFullyVisibleWhenLongNameIsTruncated() throws {
        _ = NSApplication.shared
        let cell = DirectoryOutlineView.DirectoryCell(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), styleMask: .borderless, backing: .buffered, defer: false)
        let host = try #require(window.contentView)
        host.addSubview(cell)
        cell.translatesAutoresizingMaskIntoConstraints = false
        let widthConstraint = cell.widthAnchor.constraint(equalToConstant: 100)
        NSLayoutConstraint.activate([widthConstraint, cell.heightAnchor.constraint(equalToConstant: 30), cell.leadingAnchor.constraint(equalTo: host.leadingAnchor), cell.topAnchor.constraint(equalTo: host.topAnchor)])
        let directory = try JSONDecoder().decode(KeepsNavigationDirectory.self, from: Data("""
        {"path":"/photos/long","name":"这是一个非常长的目录名称用于检查数字不会被挤出可见区域","photoCount":1234567,"hasChildren":false}
        """.utf8))
        cell.configure(directory, loading: false)
        #expect(cell.nameLabel.lineBreakMode == .byTruncatingMiddle)
        for width in [100.0, 130.0, 180.0] {
            widthConstraint.constant = width
            host.layoutSubtreeIfNeeded()
            let countAlignment = cell.countLabel.alignmentRect(forFrame: cell.countLabel.frame)
            let name = cell.nameLabel
            let nameAlignment = name.alignmentRect(forFrame: name.frame)
            #expect(abs(countAlignment.maxX - width) < 0.5)
            #expect(cell.countLabel.frame.minX >= 0)
            #expect(cell.countLabel.frame.width >= cell.countLabel.intrinsicContentSize.width)
            #expect(cell.nameLabel.frame.maxX < cell.countLabel.frame.minX)
            #expect(cell.nameLabel.frame.width > 0)
            #expect(abs(countAlignment.minX - nameAlignment.maxX - 6) < 0.5)
        }
    }
    @Test func unconfiguredLaunchHasNoLocalLibraryOrBackgroundWork() {
        let store = LibraryStore(loadSavedSettings: false)
        #expect(store.client == nil)
        store.refresh()
        #expect(!store.isLoading)
        #expect(store.assets.isEmpty)
        #expect(store.lastError == nil)
    }

    @Test func browserReadsRemoteAssetsAndSelectionRemainsPresentationState() async throws {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [LibraryStubProtocol.self]
        let store = LibraryStore(configuration: KeepsConfiguration(baseURL: URL(string: "https://nas.invalid")!, libraryID: "test-library"), session: URLSession(configuration: sessionConfiguration), loadSavedSettings: false)
        store.refresh()
        store.refreshNavigation()
        try await waitUntil { !store.isLoading && !store.isLoadingNavigation }
        #expect(store.lastError == nil)
        #expect(store.assets.count == 2)
        #expect(store.total == 2)
        #expect(store.directories.first?.path == "2026")
        let first = store.assets[0].id
        let second = store.assets[1].id
        store.select(first, extending: false)
        store.select(second, extending: true)
        #expect(store.selectedIDs == [first, second])
        store.select(second, extending: true)
        #expect(store.selectedIDs == [first])
        store.selectAdjacent(1)
        #expect(store.selectedIDs == [second])
        store.updateSelected(KeepsAssetPatch(rating: 5))
        try await waitUntil { !store.isMutating && !store.isLoading }
        #expect(store.lastError == nil)
    }

    @Test func connectionTestValidatesAPIWithoutSavingOrSwitching() async {
        var persisted = false
        let old = KeepsConfiguration(baseURL: URL(string: "https://old.invalid")!, libraryID: "old")
        let store = LibraryStore(configuration: old, session: stubSession(), loadSavedSettings: false, persistConfiguration: { _ in persisted = true })
        let success = await store.checkConnection(baseURL: "https://working.invalid", libraryID: "new", accessCredential: "test-value", save: false)
        #expect(success)
        #expect(!persisted)
        #expect(store.configuration == old)
        #expect(store.connectionMessage != nil)
        #expect(store.connectionError == nil)
    }

    @Test func validatedConnectionPersistsThenSwitches() async throws {
        var persisted: KeepsConfiguration?
        let store = LibraryStore(session: stubSession(), loadSavedSettings: false, persistConfiguration: { persisted = $0 })
        let success = await store.checkConnection(baseURL: " https://working.invalid ", libraryID: " new ", accessCredential: "test-value", save: true)
        #expect(success)
        #expect(persisted?.libraryID == "new")
        #expect(store.configuration == persisted)
        try await waitUntil { !store.isLoading }
        #expect(store.assets.count == 2)
    }

    @Test func rejectedConnectionPreservesSavedServer() async {
        var persisted = false
        let old = KeepsConfiguration(baseURL: URL(string: "https://old.invalid")!, libraryID: "old")
        let store = LibraryStore(configuration: old, session: stubSession(), loadSavedSettings: false, persistConfiguration: { _ in persisted = true })
        for host in ["unauthorized.invalid", "invalid-api.invalid"] {
            let success = await store.checkConnection(baseURL: "https://\(host)", libraryID: "new", accessCredential: "test-value", save: true)
            #expect(!success)
            #expect(!persisted)
            #expect(store.configuration == old)
            #expect(store.client?.configuration == old)
            #expect(store.connectionError != nil)
            #expect(!store.isCheckingConnection)
        }
    }

    @Test func persistenceFailureDoesNotActivateCandidateServer() async {
        let old = KeepsConfiguration(baseURL: URL(string: "https://old.invalid")!, libraryID: "old")
        let store = LibraryStore(configuration: old, session: stubSession(), loadSavedSettings: false, persistConfiguration: { _ in
            throw NSError(domain: "SettingsTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "storage unavailable"])
        })
        let success = await store.checkConnection(baseURL: "https://working.invalid", libraryID: "new", accessCredential: "test-value", save: true)
        #expect(!success)
        #expect(store.configuration == old)
        #expect(store.connectionError?.contains("storage unavailable") == true)
    }

    @Test func scopeSwitchClearsSelectionAndReturnsToUnifiedLibrary() async throws {
        let store = LibraryStore(configuration: KeepsConfiguration(baseURL: URL(string: "https://working.invalid")!, libraryID: "test"), session: stubSession(), loadSavedSettings: false)
        store.showLibrary(directory: "2026", picked: true)
        try await waitUntil { !store.isLoading }
        store.select(store.assets[0].id, extending: false)
        store.query.q = "old search"
        store.showLibrary()
        #expect(store.selectedIDs.isEmpty)
        #expect(store.query.directory == nil)
        #expect(store.query.flagState == nil)
        #expect(store.query.q.isEmpty)
        #expect(store.locationTitle == "全部照片")
        try await waitUntil { !store.isLoading }
        #expect(store.assets.count == 2)
        #expect(store.lastError == nil)
    }

    @Test func sourcesFailureDoesNotBlockHTTPAssetBrowsing() async throws {
        let store = LibraryStore(configuration: KeepsConfiguration(baseURL: URL(string: "https://sources-unavailable.invalid")!, libraryID: "test"), session: stubSession(), loadSavedSettings: false)
        store.refresh()
        store.refreshNavigation()
        try await waitUntil { !store.isLoading && !store.isLoadingNavigation }
        #expect(store.navigationError != nil)
        #expect(store.directories.isEmpty)
        #expect(store.lastError == nil)
        #expect(store.assets.count == 2)
        store.select(store.assets[0].id, extending: false)
        #expect(store.selectedAsset != nil)
    }

    @Test func unavailableServerReportsFailureWithoutLocalFallback() async throws {
        let store = LibraryStore(configuration: KeepsConfiguration(baseURL: URL(string: "https://unauthorized.invalid")!, libraryID: "test"), session: stubSession(), loadSavedSettings: false)
        store.showLibrary()
        try await waitUntil { !store.isLoading }
        #expect(store.lastError != nil)
        #expect(store.assets.isEmpty)
        #expect(store.configuration?.baseURL.host == "unauthorized.invalid")
    }

    @Test func directorySwitchClearsOldScopeAndLoadsChildrenFromServer() async throws {
        let store = LibraryStore(configuration: KeepsConfiguration(baseURL: URL(string: "https://working.invalid")!, libraryID: "test"), session: stubSession(), loadSavedSettings: false)
        store.query.flagState = "picked"
        store.query.trashed = true
        store.query.recursive = false
        store.showLibrary(directory: "2026")
        store.refreshNavigation()
        try await waitUntil { !store.isLoadingNavigation }
        store.loadChildren(of: "2026")
        try await waitUntil { !store.isLoading && store.loadingDirectories.isEmpty }
        #expect(store.query.flagState == nil)
        #expect(!store.query.trashed)
        #expect(store.query.recursive)
        #expect(store.directoryChildren["2026"]?.first?.name == "2026")
        let generation = store.navigationGeneration
        store.refreshNavigation()
        #expect(store.navigationGeneration == generation)
        #expect(store.directoryChildren["2026"] != nil)
        try await waitUntil { !store.isLoadingNavigation }
    }

    @Test func nativeOutlineRetainsExpansionSelectionAndCachedChildrenOnRefresh() async throws {
        _ = NSApplication.shared
        let store = LibraryStore(configuration: KeepsConfiguration(baseURL: URL(string: "https://tree.invalid")!, libraryID: "test"), session: stubSession(), loadSavedSettings: false)
        store.refreshNavigation()
        try await waitUntil { !store.isLoadingNavigation }
        let outline = DirectoryOutlineView.DirectoryOutline()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("directory"))
        outline.addTableColumn(column); outline.outlineTableColumn = column
        let coordinator = DirectoryOutlineView.Coordinator(library: store)
        coordinator.outline = outline
        outline.dataSource = coordinator; outline.delegate = coordinator
        coordinator.update()
        for width in [200.0, 300.0, 480.0] {
            outline.setFrameSize(NSSize(width: width, height: 400))
            for row in 0..<outline.numberOfRows {
                let frame = outline.frameOfCell(atColumn: 0, row: row)
                #expect(abs(frame.maxX - (width - 14)) < 0.5)
            }
        }
        #expect(outline.numberOfRows == 2)
        let root = try #require(outline.item(atRow: 0) as? DirectoryOutlineView.Coordinator.Node)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = outline
        window.makeFirstResponder(outline)
        outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let rightArrow = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .function, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: String(UnicodeScalar(NSRightArrowFunctionKey)!), charactersIgnoringModifiers: String(UnicodeScalar(NSRightArrowFunctionKey)!), isARepeat: false, keyCode: 124))
        outline.keyDown(with: rightArrow)
        #expect(outline.isItemExpanded(root))
        #expect(store.selectedIDs.isEmpty)
        store.loadChildren(of: "root")
        try await waitUntil { store.loadingDirectories.isEmpty }
        coordinator.update()
        #expect(outline.numberOfRows == 3)
        let child = try #require(outline.item(atRow: 1) as? DirectoryOutlineView.Coordinator.Node)
        outline.expandItem(child)
        try await waitUntil { store.loadingDirectories.isEmpty }
        coordinator.update()
        #expect(outline.numberOfRows == 4)
        outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        #expect(store.query.directory == "root/child")
        outline.collapseItem(root)
        #expect(outline.numberOfRows == 2)
        outline.expandItem(root)
        coordinator.update()
        #expect(outline.numberOfRows == 4)
        #expect(LibraryStubProtocol.treeRequests.count(for: "root") == 1)
        #expect(LibraryStubProtocol.treeRequests.count(for: "root/child") == 1)
        store.refreshNavigation()
        #expect(store.expandedPaths.contains("root"))
        #expect(store.directoryChildren["root"] != nil)
        try await waitUntil { !store.isLoadingNavigation && store.loadingDirectories.isEmpty }
        coordinator.update()
        #expect(outline.isItemExpanded(root))
        #expect(outline.isItemExpanded(child))
        #expect(outline.item(atRow: 0) as? DirectoryOutlineView.Coordinator.Node === root)
        #expect(outline.selectedRow == 1)
        #expect(store.query.directory == "root/child")

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 188, height: 400))
        window.contentView = scroll
        scroll.documentView = outline
        outline.indentationPerLevel = 100
        outline.setFrameSize(NSSize(width: 500, height: 400))
        outline.reloadData()
        outline.expandItem(root, expandChildren: true)
        scroll.layoutSubtreeIfNeeded()
        for row in 0..<outline.numberOfRows {
            let frame = outline.frameOfCell(atColumn: 0, row: row)
            #expect(abs(frame.maxX - (scroll.contentSize.width - 14)) < 0.5)
            #expect(frame.width >= 100)
            let cell = try #require(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? DirectoryOutlineView.DirectoryCell)
            cell.layoutSubtreeIfNeeded()
            let countFrame = cell.countLabel.convert(cell.countLabel.bounds, to: scroll.contentView)
            #expect(countFrame.maxX <= scroll.contentSize.width)
            #expect(countFrame.minX >= 0)
        }
    }

    @Test func switchingServerRejectsLateNavigationFromOldConnection() async throws {
        let store = LibraryStore(configuration: KeepsConfiguration(baseURL: URL(string: "https://slow-old.invalid")!, libraryID: "test"), session: stubSession(), loadSavedSettings: false, persistConfiguration: { _ in })
        store.refreshNavigation()
        try await waitUntil { LibraryStubProtocol.treeRequests.count(for: "slow-start") > 0 }
        let saved = await store.checkConnection(baseURL: "https://working.invalid", libraryID: "test", accessCredential: "", save: true)
        #expect(saved)
        try await waitUntil { !store.isLoadingNavigation }
        try await Task.sleep(for: .milliseconds(300))
        #expect(store.directories.map(\.path) == ["2026"])
        #expect(store.expandedPaths.isEmpty)
        #expect(store.directoryChildren.isEmpty)
    }

    @Test func directoryCellShowsLoadingUntilResponseAndClearsOnReuse() async throws {
        _ = NSApplication.shared
        let store = LibraryStore(configuration: KeepsConfiguration(baseURL: URL(string: "https://loading.invalid")!, libraryID: "test"), session: stubSession(), loadSavedSettings: false)
        store.refreshNavigation()
        try await waitUntil { !store.isLoadingNavigation }
        let outline = NSOutlineView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("directory"))
        outline.addTableColumn(column); outline.outlineTableColumn = column
        let coordinator = DirectoryOutlineView.Coordinator(library: store)
        coordinator.outline = outline; outline.dataSource = coordinator; outline.delegate = coordinator
        coordinator.update()
        let item = try #require(outline.item(atRow: 0))
        store.loadChildren(of: "2026")
        coordinator.update()
        let cell = try #require(coordinator.outlineView(outline, viewFor: nil, item: item) as? DirectoryOutlineView.DirectoryCell)
        #expect(!cell.spinner.isHidden)
        #expect(cell.countLabel.stringValue == "0")
        #expect(store.directoryChildren["2026"] == nil)
        try await waitUntil { store.loadingDirectories.isEmpty }
        coordinator.update()
        #expect(store.directoryChildren["2026"]?.isEmpty == true)
        let directory = try #require(store.directories.first)
        cell.configure(directory, loading: false)
        #expect(cell.spinner.isHidden)
        #expect(cell.icon.isHidden == false)
        #expect(cell.countLabel.stringValue == "0")
        cell.configure(directory, loading: true)
        #expect(!cell.spinner.isHidden)
        cell.configure(directory, loading: false)
        #expect(cell.spinner.isHidden)
    }

    @Test func visiblePaginationContinuesAfterAnInFlightPageFinishes() async throws {
        let store = LibraryStore(configuration: KeepsConfiguration(baseURL: URL(string: "https://pages.invalid")!, libraryID: "test"), session: stubSession(), loadSavedSettings: false)
        store.refresh()
        store.setPaginationVisible(true)
        try await waitUntil { !store.isLoading }
        #expect(store.assets.count == 2)
        #expect(store.nextCursor == nil)
        #expect(store.lastError == nil)
    }

    @Test func paginationWaitsUntilFooterBecomesVisible() async throws {
        let store = LibraryStore(configuration: KeepsConfiguration(baseURL: URL(string: "https://pages.invalid")!, libraryID: "test"), session: stubSession(), loadSavedSettings: false)
        store.refresh()
        try await waitUntil { !store.isLoading }
        #expect(store.assets.count == 1)
        #expect(store.nextCursor == "next")
        store.setPaginationVisible(true)
        try await waitUntil { !store.isLoading }
        #expect(store.assets.count == 2)
        #expect(store.nextCursor == nil)
    }

    @Test func hiddenDirectoryMarkInheritsWithoutMatchingSiblingPrefixes() async throws {
        let store = LibraryStore(configuration: KeepsConfiguration(baseURL: URL(string: "https://working.invalid")!, libraryID: "test"), session: stubSession(), loadSavedSettings: false)
        store.refreshNavigation()
        try await waitUntil { !store.isLoadingNavigation }
        #expect(store.isDirectoryHidden("root/private"))
        #expect(store.isDirectoryHidden("root/private/child"))
        #expect(!store.isDirectoryHidden("root/private-other"))
        #expect(!store.isDirectoryHidden("root"))
        store.showLibrary()
        try await waitUntil { !store.isLoading }
        store.select(store.assets[0].id, extending: false)
        store.setDirectoryHidden("root/private", hidden: true)
        #expect(!store.assets.isEmpty)
        try await waitUntil { !store.isUpdatingHiddenDirectory && !store.isLoading }
        #expect(store.hiddenDirectoryPaths == ["root/private"])
        #expect(store.lastError == nil)
    }

    @Test func hiddenFilterSwitchClearsSelectionPersistsAndReloads() async throws {
        let name = "KeepsTests-" + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        let store = LibraryStore(configuration: KeepsConfiguration(baseURL: URL(string: "https://working.invalid")!, libraryID: "test"), session: stubSession(), loadSavedSettings: false, preferences: preferences)
        #expect(store.hiddenDirectoryFilterEnabled)
        store.refresh()
        try await waitUntil { !store.isLoading }
        store.select(store.assets[0].id, extending: false)
        store.hiddenDirectoryFilterEnabled = false
        #expect(store.assets.isEmpty)
        #expect(store.selectedIDs.isEmpty)
        try await waitUntil { !store.isLoading }
        #expect(store.assets.count == 2)
        let reloaded = LibraryStore(loadSavedSettings: false, preferences: preferences)
        #expect(!reloaded.hiddenDirectoryFilterEnabled)
    }

    @Test func revisionPollingRefreshesOnlyWhenChangedAndStopsWhileInactive() async throws {
        let store = LibraryStore(configuration: KeepsConfiguration(baseURL: URL(string: "https://revision.invalid")!, libraryID: "test"), session: stubSession(), loadSavedSettings: false)
        await store.loadStartupLibrary()
        store.setActive(true)
        defer { store.setActive(false) }
        try await waitUntil { LibraryStubProtocol.treeRequests.count(for: "revision-poll") == 1 && !store.isLoading }
        #expect(LibraryStubProtocol.treeRequests.count(for: "revision-assets") == 1)
        store.setActive(false)
        store.setActive(true)
        try await waitUntil { LibraryStubProtocol.treeRequests.count(for: "revision-poll") == 2 }
        try await Task.sleep(for: .milliseconds(20))
        #expect(LibraryStubProtocol.treeRequests.count(for: "revision-assets") == 1)
        store.setActive(false)
        store.setActive(true)
        try await waitUntil { LibraryStubProtocol.treeRequests.count(for: "revision-assets") == 2 && !store.isLoading }
        store.setActive(false)
        try await Task.sleep(for: .milliseconds(20))
        #expect(LibraryStubProtocol.treeRequests.count(for: "revision-poll") == 3)
    }

    @Test func returningToDirectoryRestoresAllLoadedPagesWithoutAssetOrCountRequests() async throws {
        let store = LibraryStore(configuration: KeepsConfiguration(baseURL: URL(string: "https://cache-pages.invalid")!, libraryID: "test"), session: stubSession(), loadSavedSettings: false)
        store.showLibrary(directory: "A")
        try await waitUntil { !store.isLoading }
        store.loadMore()
        try await waitUntil { !store.isLoading }
        #expect(store.assets.count == 2)
        store.showLibrary(directory: "B")
        try await waitUntil { !store.isLoading }
        let requests = LibraryStubProtocol.treeRequests.count(for: "cache-assets")
        let counts = LibraryStubProtocol.treeRequests.count(for: "cache-counts")
        store.showLibrary(directory: "A")
        #expect(store.assets.count == 2)
        try await waitUntil { !store.isLoading }
        #expect(LibraryStubProtocol.treeRequests.count(for: "cache-assets") == requests)
        #expect(LibraryStubProtocol.treeRequests.count(for: "cache-counts") == counts)
        store.refresh(force: true)
        try await waitUntil { !store.isLoading }
        #expect(store.assets.count == 2)
        #expect(LibraryStubProtocol.treeRequests.count(for: "cache-assets") == requests + 2)
    }

    @Test func updatingWindowRefreshesOnceAndFinalVersionRefreshesImmediately() async throws {
        let store = LibraryStore(configuration: KeepsConfiguration(baseURL: URL(string: "https://updating.invalid")!, libraryID: "test"), session: stubSession(), loadSavedSettings: false)
        store.showLibrary(directory: "A")
        try await waitUntil { !store.isLoading }
        store.select(store.assets[0].id, extending: false)
        let selection = store.selectedIDs
        store.refresh()
        #expect(store.assets.count == 2)
        try await waitUntil { !store.isLoading }
        #expect(LibraryStubProtocol.treeRequests.count(for: "updating-assets") == 2)
        store.refresh()
        try await waitUntil { !store.isLoading }
        #expect(LibraryStubProtocol.treeRequests.count(for: "updating-assets") == 2)
        store.refresh()
        try await waitUntil { !store.isLoading }
        #expect(LibraryStubProtocol.treeRequests.count(for: "updating-assets") == 3)
        #expect(store.selectedIDs == selection)
        #expect(store.lastError == nil)
    }

    @Test func changedRevisionDuringPaginationRestartsWithoutCachingMixedPages() async throws {
        let store = LibraryStore(configuration: KeepsConfiguration(baseURL: URL(string: "https://mixed-pages.invalid")!, libraryID: "test"), session: stubSession(), loadSavedSettings: false)
        store.refresh()
        try await waitUntil { !store.isLoading }
        #expect(store.assets.count == 1)
        store.loadMore()
        try await waitUntil { !store.isLoading }
        #expect(store.assets.count == 1)
        #expect(store.nextCursor == "next")
        #expect(LibraryStubProtocol.treeRequests.count(for: "mixed-assets") == 3)
        store.refresh()
        try await waitUntil { !store.isLoading }
        #expect(LibraryStubProtocol.treeRequests.count(for: "mixed-assets") == 3)
        #expect(store.lastError == nil)
    }

    @Test func refreshedPaginationDeduplicatesOverlappingServerPages() async throws {
        let store = LibraryStore(configuration: KeepsConfiguration(baseURL: URL(string: "https://overlap-pages.invalid")!, libraryID: "test"), session: stubSession(), loadSavedSettings: false)
        store.refresh()
        try await waitUntil { !store.isLoading }
        store.loadMore()
        try await waitUntil { !store.isLoading }
        #expect(store.assets.count == 2)
        store.refresh(force: true)
        try await waitUntil { !store.isLoading }
        #expect(store.assets.count == 2)
        #expect(Set(store.assets.map(\.id)).count == 2)
        #expect(store.nextCursor == nil)
    }

    @Test func slowCountsDoNotBlockRevisionChecks() async throws {
        let store = LibraryStore(configuration: KeepsConfiguration(baseURL: URL(string: "https://slow-counts.invalid")!, libraryID: "test"), session: stubSession(), loadSavedSettings: false)
        store.refresh()
        try await waitUntil { LibraryStubProtocol.treeRequests.count(for: "slow-counts-started") == 1 }
        #expect(!store.isLoading)
        #expect(store.counts == nil)
        store.refresh()
        try await waitUntil { LibraryStubProtocol.treeRequests.count(for: "slow-counts-revision") == 2 && !store.isLoading }
        #expect(store.counts == nil)
        #expect(LibraryStubProtocol.treeRequests.count(for: "slow-counts-started") == 1)
        try await waitUntil { store.counts != nil }
        #expect(store.lastError == nil)
    }

    @Test func metadataMutationSurvivesConcurrentRefresh() async throws {
        let store = LibraryStore(configuration: KeepsConfiguration(baseURL: URL(string: "https://slow-mutation.invalid")!, libraryID: "test"), session: stubSession(), loadSavedSettings: false)
        store.refresh()
        try await waitUntil { !store.isLoading }
        store.select(try #require(store.assets.first).id)
        store.updateSelected(KeepsAssetPatch(rating: 5))
        try await waitUntil { LibraryStubProtocol.treeRequests.count(for: "slow-mutation-started") == 1 }
        store.refresh()
        #expect(!store.isLoading)
        try await waitUntil { !store.isMutating && !store.isLoading }
        #expect(store.assets.first?.rating == 5)
        #expect(LibraryStubProtocol.treeRequests.count(for: "slow-mutation-assets") == 2)
        #expect(store.lastError == nil)
    }

    private func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LibraryStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("remote request did not complete")
    }
}

private final class RequestCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Int] = [:]
    func record(_ path: String) { lock.lock(); defer { lock.unlock() }; values[path, default: 0] += 1 }
    func count(for path: String) -> Int { lock.lock(); defer { lock.unlock() }; return values[path, default: 0] }
}

private final class LibraryStubProtocol: URLProtocol, @unchecked Sendable {
    static let treeRequests = RequestCounts()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.host == "slow-counts.invalid" {
            if request.url?.path.hasSuffix("/revision") == true { Self.treeRequests.record("slow-counts-revision") }
            if request.url?.path.hasSuffix("/counts") == true {
                Self.treeRequests.record("slow-counts-started")
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { [self] in
                    deliver(body: "{\"all\":2,\"picked\":0,\"trashed\":0}", status: 200)
                }
                return
            }
        }
        if request.url?.host == "slow-mutation.invalid" {
            if request.httpMethod == "PATCH" {
                Self.treeRequests.record("slow-mutation-started")
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { [self] in
                    Self.treeRequests.record("slow-mutation-completed")
                    deliver(body: Self.asset("00000000-0000-0000-0000-000000000001").replacingOccurrences(of: "\"rating\":0", with: "\"rating\":5"), status: 200)
                }
                return
            }
            if request.url?.path.hasSuffix("/assets") == true {
                Self.treeRequests.record("slow-mutation-assets")
                if Self.treeRequests.count(for: "slow-mutation-completed") > 0 {
                    let updated = Self.asset("00000000-0000-0000-0000-000000000001").replacingOccurrences(of: "\"rating\":0", with: "\"rating\":5")
                    deliver(body: "{\"items\":[\(updated)],\"total\":1,\"revision\":2,\"isUpdating\":false}", status: 200)
                    return
                }
            }
        }
        if request.url?.host == "directory-trash.invalid" {
            if request.url?.path.hasSuffix("/directories/trash") == true {
                Self.treeRequests.record("directory-trash")
                var data = request.httpBody ?? Data()
                if let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096); while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) } }
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let id = object?["requestID"] as? String ?? UUID().uuidString
                deliver(body: "{\"id\":\"\(id)\",\"path\":\"2026\",\"status\":\"completed\",\"phase\":\"completed\",\"createdAt\":0,\"updatedAt\":1}", status: 202)
                return
            }
            if request.url?.path.hasSuffix("/navigation") == true, Self.treeRequests.count(for: "directory-trash") > 0 {
                deliver(body: "{\"directories\":[]}", status: 200)
                return
            }
        }
        if request.url?.host == "slow-old.invalid", request.url?.path.hasSuffix("/navigation") == true {
            Self.treeRequests.record("slow-start")
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { [self] in
                deliver(body: "{\"directories\":[{\"path\":\"old-root\",\"name\":\"old-root\",\"photoCount\":0,\"hasChildren\":false}]}", status: 200)
            }
            return
        }
        if request.url?.host == "loading.invalid", request.url?.query != nil, request.url?.path.hasSuffix("/navigation") == true {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [self] in
                deliver(body: "{\"directories\":[]}", status: 200)
            }
            return
        }
        if request.url?.host == "updating.invalid" {
            if request.url?.path.hasSuffix("/revision") == true {
                Self.treeRequests.record("updating-poll")
                let poll = Self.treeRequests.count(for: "updating-poll")
                let updating = poll == 2 || poll == 3
                let revision = poll == 1 ? 1 : updating ? 2 : 3
                deliver(body: "{\"revision\":\(revision),\"isUpdating\":\(updating)}", status: 200)
                return
            }
            if request.url?.path.hasSuffix("/assets") == true { Self.treeRequests.record("updating-assets") }
        }
        if request.url?.host == "revision.invalid" {
            if request.url?.path.hasSuffix("/revision") == true {
                Self.treeRequests.record("revision-poll")
                let value = Self.treeRequests.count(for: "revision-poll") > 2 ? 2 : 1
                deliver(body: "{\"revision\":\(value),\"isUpdating\":false}", status: 200)
                return
            }
            if request.url?.path.hasSuffix("/assets") == true { Self.treeRequests.record("revision-assets") }
        }
        if request.url?.host == "cache-pages.invalid" {
            if request.url?.path.hasSuffix("/assets") == true { Self.treeRequests.record("cache-assets") }
            if request.url?.path.hasSuffix("/counts") == true { Self.treeRequests.record("cache-counts") }
        }
        if request.url?.host == "mixed-pages.invalid" {
            if request.url?.path.hasSuffix("/assets") == true { Self.treeRequests.record("mixed-assets") }
            if request.url?.path.hasSuffix("/revision") == true {
                let revision = Self.treeRequests.count(for: "mixed-assets") == 0 ? 1 : 2
                deliver(body: "{\"revision\":\(revision),\"isUpdating\":false}", status: 200)
                return
            }
        }
        let first = Self.asset("00000000-0000-0000-0000-000000000001")
        let second = Self.asset("00000000-0000-0000-0000-000000000002")
        let path = request.url!.path
        let body: String
        let status = request.url?.host == "unauthorized.invalid" || (request.url?.host == "sources-unavailable.invalid" && path.hasSuffix("/navigation")) ? 401 : 200
        if path.hasSuffix("/directories/refresh"), request.httpMethod == "POST" {
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(buffer, count: count)
                }
            }
            let submitted = try! JSONDecoder().decode([String: String].self, from: data)
            #expect(submitted == ["path": "other"])
            deliver(body: "{\"id\":\"refresh-1\",\"folderID\":\"folder-1\",\"libraryID\":\"test\",\"path\":\"other\",\"status\":\"pending\"}", status: 202)
            return
        }
        if status == 401 { body = "access denied" }
        else if request.url?.host == "invalid-api.invalid" && path.hasSuffix("/assets") { body = "{}" }
        else if request.httpMethod == "PATCH" { body = second }
        else if path.hasSuffix("/assets"), request.url?.host == "overlap-pages.invalid" {
            let hasCursor = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "cursor" } == true
            body = hasCursor ? "{\"items\":[\(first),\(second)],\"total\":2}" : "{\"items\":[\(first)],\"total\":2,\"nextCursor\":\"next\"}"
        }
        else if path.hasSuffix("/assets"), ["pages.invalid", "cache-pages.invalid", "mixed-pages.invalid"].contains(request.url?.host ?? "") {
            let hasCursor = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "cursor" } == true
            body = hasCursor ? "{\"items\":[\(second)],\"total\":2}" : "{\"items\":[\(first)],\"total\":2,\"nextCursor\":\"next\"}"
        }
        else if path.hasSuffix("/assets") { body = "{\"items\":[\(first),\(second)],\"total\":2}" }
        else if path.hasSuffix("/revision") { body = "{\"revision\":1,\"isUpdating\":false}" }
        else if path.hasSuffix("/hidden-directories") { body = "{\"paths\":[\"root/private\"]}" }
        else if path.hasSuffix("/counts") { body = "{\"all\":2,\"picked\":0,\"trashed\":0}" }
        else if path.hasSuffix("/navigation"), request.url?.host == "tree.invalid" {
            let requestedPath = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "path" }?.value ?? ""
            Self.treeRequests.record(requestedPath)
            let folders: [[String: Any]]
            switch requestedPath {
            case "root": folders = [["path": "root/child", "name": "child", "photoCount": 0, "hasChildren": true]]
            case "root/child": folders = [["path": "root/child/leaf", "name": "leaf", "photoCount": 0, "hasChildren": false]]
            default: folders = [["path": "root", "name": "root", "photoCount": 0, "hasChildren": true], ["path": "other", "name": "other", "photoCount": 0, "hasChildren": false]]
            }
            body = String(data: try! JSONSerialization.data(withJSONObject: ["directories": folders]), encoding: .utf8)!
        }
        else if path.hasSuffix("/navigation") { body = "{\"path\":null,\"directories\":[{\"path\":\"2026\",\"name\":\"2026\",\"photoCount\":0,\"hasChildren\":false}]}" }
        else if path.hasSuffix("/directories") { body = "{\"directories\":[{\"path\":\"2026\",\"count\":2}]}" }
        else { Issue.record("unexpected client request: \(path)"); body = "{}" }
        var response = body
        if path.hasSuffix("/assets"), status == 200, body.contains("\"items\"") {
            var revision = request.url?.host == "revision.invalid" && Self.treeRequests.count(for: "revision-poll") > 2 ? 2 : 1
            if request.url?.host == "mixed-pages.invalid" { revision = Self.treeRequests.count(for: "mixed-assets") == 1 ? 1 : 2 }
            if request.url?.host == "updating.invalid" {
                let poll = Self.treeRequests.count(for: "updating-poll")
                let updating = poll == 2 || poll == 3
                let revision = poll == 1 ? 1 : updating ? 2 : 3
                response = String(body.dropLast()) + ",\"revision\":\(revision),\"isUpdating\":\(updating)}"
                deliver(body: response, status: status)
                return
            }
            response = String(body.dropLast()) + ",\"revision\":\(revision),\"isUpdating\":false}"
        }
        deliver(body: response, status: status)
    }
    private func deliver(body: String, status: Int) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    private static func asset(_ id: String) -> String {
        "{\"id\":\"\(id)\",\"cameraMake\":\"\",\"cameraModel\":\"\",\"lensModel\":\"\",\"originalFilename\":\"photo.jpg\",\"contentFingerprint\":\"hash\",\"metadataFingerprint\":\"meta\",\"rating\":0,\"flagState\":\"unflagged\",\"tags\":[],\"createdAt\":\"2026-01-01T00:00:00Z\",\"updatedAt\":\"2026-01-01T00:00:00Z\",\"trashed\":false}"
    }
}
