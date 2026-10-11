import Foundation
import Testing
import AppKit
import KeepsAPI
@testable import PhotoAssetManager

@MainActor struct DirectoryMoveTests {
    @Test func moveSendsNASRequestAndMigratesCurrentDescendant() async throws {
        let (store, state) = makeStore()
        store.refreshNavigation()
        store.showLibrary(directory: "/photos/source/child")
        try await waitUntil { !store.isLoading && !store.isLoadingNavigation }
        store.setDirectoryExpanded("/photos", expanded: true)
        try await waitUntil { store.loadingDirectories.isEmpty }
        store.setDirectoryExpanded("/photos/source", expanded: true)
        try await waitUntil { store.loadingDirectories.isEmpty }
        let generation = store.navigationGeneration
        await store.moveDirectory("/photos/source", to: "/photos/destination")
        try await waitUntil { !store.isLoading && !store.isLoadingNavigation && store.loadingDirectories.isEmpty }
        let request = try #require(state.moves.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/libraries/test/directories/move-tasks")
        let payload = try #require(state.payloads.first)
        #expect(payload["path"] == "/photos/source")
        #expect(payload["parentPath"] == "/photos/destination")
        #expect(UUID(uuidString: payload["requestID"] ?? "") != nil)
        #expect(store.query.directory == "/photos/destination/source/child")
        #expect(store.navigationGeneration > generation)
        #expect(store.directoryChildren["/photos"]?.map(\.path) == ["/photos/destination"])
        #expect(store.expandedPaths.contains("/photos/destination/source"))
        #expect(store.directoryChildren["/photos/destination/source"]?.first?.path == "/photos/destination/source/child")
        #expect(store.lastError == nil)
        #expect(!store.isMovingDirectory)
    }

    @Test func renameSendsNameAndFollowsSelectedDescendant() async throws {
        let (store, state) = makeStore()
        store.showLibrary(directory: "/photos/source/child")
        try await waitUntil { !store.isLoading }
        await store.renameDirectory("/photos/source", name: "旅行 2026")
        #expect(state.payloads.first?["name"] == "旅行 2026")
        #expect(state.payloads.first?["parentPath"] == "/photos")
        #expect(store.query.directory == "/photos/旅行 2026/child")
        #expect(store.lastError == nil)
        #expect(!store.isMovingDirectory)
    }

    @Test func invalidRenameAndRootNeverReachNAS() async throws {
        let (store, state) = makeStore()
        store.refreshNavigation()
        try await waitUntil { !store.isLoadingNavigation }
        for name in ["", "  ", ".", "..", "a/b", "a\0b", "source", ".hidden", "@eaDir", "#recycle", "a\\b", "a\nb"] {
            await store.renameDirectory("/photos/source", name: name)
        }
        await store.renameDirectory("/photos", name: "renamed")
        #expect(state.moves.isEmpty)
    }

    @Test func renameConflictPreservesSelectedPath() async throws {
        let (store, _) = makeStore(fail: true)
        store.showLibrary(directory: "/photos/source/child")
        try await waitUntil { !store.isLoading }
        await store.renameDirectory("/photos/source", name: "destination")
        #expect(store.query.directory == "/photos/source/child")
        #expect(store.directoryMoveFinished)
        #expect(store.lastError != nil)
    }

    @Test func rejectedNASMovePreservesCurrentPathAndNavigation() async throws {
        let (store, state) = makeStore(fail: true)
        store.refreshNavigation()
        store.showLibrary(directory: "/photos/source/child")
        try await waitUntil { !store.isLoading && !store.isLoadingNavigation }
        let generation = store.navigationGeneration
        await store.moveDirectory("/photos/source", to: "/photos/destination")
        #expect(state.moves.count == 1)
        #expect(store.query.directory == "/photos/source/child")
        #expect(store.navigationGeneration >= generation)
        #expect(store.directories.map(\.path) == ["/photos"])
        #expect(store.directoryMoveFinished)
        #expect(store.directoryMoveMessage != nil)
        #expect(store.isMovingDirectory)
        store.acknowledgeDirectoryMoveFailure()
        #expect(!store.isMovingDirectory)
    }

    @Test func invalidTargetsNeverReachNAS() async {
        let (store, state) = makeStore()
        for (source, parent) in [("/photos/source", "/photos/source"), ("/photos/source", "/photos/source/child"), ("/photos/source/child", "/photos/source"), ("/photos/source", "/photos")] {
            #expect(!store.canMoveDirectory(source, to: parent))
            await store.moveDirectory(source, to: parent)
        }
        #expect(state.moves.isEmpty)
        #expect(store.canMoveDirectory("/photos/source", to: "/photos/source-other"))
        #expect(store.canMoveDirectory("/photos/source/child", to: "/photos"))
    }

    @Test func dragExportsOnlyAppDirectoryTypeAndRejectsLibraryRoot() async throws {
        _ = NSApplication.shared
        let (store, _) = makeStore()
        store.refreshNavigation()
        try await waitUntil { !store.isLoadingNavigation }
        #expect(!store.canMoveDirectory("/photos", to: "/elsewhere"))
        store.loadChildren(of: "/photos")
        try await waitUntil { store.loadingDirectories.isEmpty }
        let outline = DirectoryOutlineView.DirectoryOutline()
        let column = NSTableColumn(identifier: .init("directory"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        let coordinator = DirectoryOutlineView.Coordinator(library: store)
        coordinator.outline = outline
        outline.dataSource = coordinator
        outline.delegate = coordinator
        coordinator.update()
        let root = try #require(outline.item(atRow: 0))
        #expect(coordinator.outlineView(outline, pasteboardWriterForItem: root) == nil)
        outline.expandItem(root)
        let child = try #require(outline.item(atRow: 1))
        let writer = try #require(coordinator.outlineView(outline, pasteboardWriterForItem: child) as? NSPasteboardItem)
        #expect(writer.types == [NSPasteboard.PasteboardType("com.keeps.directory")])
        #expect(writer.string(forType: NSPasteboard.PasteboardType("com.keeps.directory")) == "/photos/source")
        #expect(writer.string(forType: .fileURL) == nil)
        let rootRename = try #require(coordinator.contextMenu(for: root)?.items.first { $0.title == "重命名文件夹…" })
        #expect(!rootRename.isEnabled)
        store.showLibrary(directory: "/photos/destination")
        let rename = try #require(coordinator.contextMenu(for: child)?.items.first { $0.title == "重命名文件夹…" })
        #expect(rename.isEnabled)
        #expect(NSApp.sendAction(try #require(rename.action), to: rename.target, from: rename))
        #expect(store.directoryToRename?.path == "/photos/source")
        #expect(store.query.directory == "/photos/destination")
    }

    @Test func restoredDirectorySelectionWaitsForLazyTreeLoading() async throws {
        _ = NSApplication.shared
        let (store, _) = makeStore()
        store.showLibrary(directory: "/photos/source/child")
        store.setDirectoryExpanded("/photos", expanded: true)
        store.setDirectoryExpanded("/photos/source", expanded: true)
        let outline = DirectoryOutlineView.DirectoryOutline()
        let column = NSTableColumn(identifier: .init("directory"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        let coordinator = DirectoryOutlineView.Coordinator(library: store)
        coordinator.outline = outline
        outline.dataSource = coordinator
        outline.delegate = coordinator
        coordinator.update()
        #expect(outline.selectedRow == -1)
        store.refreshNavigation()
        try await waitUntil { !store.isLoadingNavigation && store.loadingDirectories.isEmpty }
        coordinator.update()
        #expect(outline.selectedRow >= 0)
        #expect(store.query.directory == "/photos/source/child")
        store.resetNavigation()
        coordinator.update()
        store.refreshNavigation()
        try await waitUntil { !store.isLoadingNavigation && store.loadingDirectories.isEmpty }
        coordinator.update()
        #expect(outline.selectedRow >= 0)
        #expect(store.expandedPaths.contains("/photos/source"))
    }

    @Test func directoryRangeSelectionSurvivesRefreshAndControlASelectsVisibleRows() async throws {
        _ = NSApplication.shared
        let (store, _) = makeStore()
        store.refreshNavigation()
        try await waitUntil { !store.isLoadingNavigation }
        store.loadChildren(of: "/photos")
        try await waitUntil { store.loadingDirectories.isEmpty }
        let outline = DirectoryOutlineView.DirectoryOutline()
        let column = NSTableColumn(identifier: .init("directory"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.allowsMultipleSelection = true
        let coordinator = DirectoryOutlineView.Coordinator(library: store)
        coordinator.outline = outline
        outline.dataSource = coordinator
        outline.delegate = coordinator
        coordinator.update()
        let root = try #require(outline.item(atRow: 0))
        outline.expandItem(root)
        outline.selectRowIndexes(IndexSet(integersIn: 1..<outline.numberOfRows), byExtendingSelection: false)
        let selection = outline.selectedRowIndexes
        #expect(selection.count > 1)
        let child = try #require(outline.item(atRow: 1))
        #expect(coordinator.outlineView(outline, pasteboardWriterForItem: child) == nil)
        coordinator.update()
        #expect(outline.selectedRowIndexes == selection)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control],
            timestamp: 0, windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a",
            isARepeat: false, keyCode: 0))
        outline.keyDown(with: event)
        #expect(outline.selectedRowIndexes.count == outline.numberOfRows)
        #expect(store.query.directory == nil)
    }

    @Test func pendingMoveBlocksAnotherMoveAndConnectionSwitch() async throws {
        let (store, state) = makeStore(hold: true)
        let original = store.configuration
        let move = Task { await store.moveDirectory("/photos/source", to: "/photos/destination") }
        try await waitUntil { state.hasPendingMove }
        #expect(store.isMovingDirectory)
        #expect(store.isOperationBlocking)
        #expect(!store.canMoveDirectory("/photos/another", to: "/photos/destination"))
        await store.moveDirectory("/photos/another", to: "/photos/destination")
        let changed = await store.checkConnection(baseURL: "https://another.invalid", libraryID: "other", accessCredential: "", save: true)
        #expect(!changed)
        #expect(store.configuration == original)
        #expect(state.moves.count == 1)
        state.release()
        await move.value
        try await waitUntil { !store.isLoading && !store.isLoadingNavigation }
        #expect(!store.isMovingDirectory)
        #expect(!store.isOperationBlocking)
    }

    @Test func dropUsesWholeRowAndHighlightsOnlyName() async throws {
        _ = NSApplication.shared
        let (store, _) = makeStore()
        store.refreshNavigation()
        try await waitUntil { !store.isLoadingNavigation }
        store.loadChildren(of: "/photos")
        try await waitUntil { store.loadingDirectories.isEmpty }
        let outline = DirectoryOutlineView.DirectoryOutline(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        let column = NSTableColumn(identifier: .init("directory"))
        column.width = 300
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 30
        let scroll = NSScrollView(frame: outline.frame)
        scroll.documentView = outline
        let window = NSWindow(contentRect: outline.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scroll
        let coordinator = DirectoryOutlineView.Coordinator(library: store)
        coordinator.outline = outline
        outline.dataSource = coordinator
        outline.delegate = coordinator
        coordinator.update()
        outline.expandItem(try #require(outline.item(atRow: 0)))
        let source = try #require(outline.item(atRow: 1))
        let writer = try #require(coordinator.outlineView(outline, pasteboardWriterForItem: source))
        let info = DirectoryTestDragInfo(source: outline, window: window)
        info.draggingPasteboard.writeObjects([writer])
        defer { info.draggingPasteboard.releaseGlobally() }
        let destinationRow = 2
        let rect = outline.rect(ofRow: destinationRow)
        for point in [NSPoint(x: 1, y: rect.minY + 1), NSPoint(x: 150, y: rect.midY), NSPoint(x: 298, y: rect.maxY - 1)] {
            info.draggingLocation = outline.convert(point, to: nil)
            let result = coordinator.outlineView(outline, validateDrop: info, proposedItem: nil, proposedChildIndex: 0)
            #expect(result == .move)
            #expect(outline.dropTargetRow == destinationRow)
            let cell = try #require(outline.view(atColumn: 0, row: destinationRow, makeIfNecessary: true) as? DirectoryOutlineView.DirectoryCell)
            #expect(cell.nameLabel.isDropTarget)
            #expect(!outline.isRowSelected(destinationRow))
        }
        info.draggingLocation = outline.convert(NSPoint(x: 150, y: outline.rect(ofRow: 1).midY), to: nil)
        #expect(coordinator.outlineView(outline, validateDrop: info, proposedItem: nil, proposedChildIndex: 0).isEmpty)
        #expect(outline.dropTargetRow == -1)
        let cell = try #require(outline.view(atColumn: 0, row: destinationRow, makeIfNecessary: true) as? DirectoryOutlineView.DirectoryCell)
        #expect(!cell.nameLabel.isDropTarget)
        outline.highlightDropTarget(row: destinationRow)
        outline.draggingExited(info)
        #expect(!cell.nameLabel.isDropTarget)
    }

    private func makeStore(fail: Bool = false, hold: Bool = false) -> (LibraryStore, DirectoryMoveState) {
        let host = UUID().uuidString.lowercased() + ".invalid"
        let state = DirectoryMoveState(fail: fail, hold: hold)
        DirectoryMoveProtocol.states.add(state, host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DirectoryMoveProtocol.self]
        let store = LibraryStore(configuration: KeepsConfiguration(baseURL: URL(string: "https://" + host)!, libraryID: "test"), session: URLSession(configuration: configuration), loadSavedSettings: false, preferences: UserDefaults(suiteName: host)!, persistConfiguration: { _ in })
        return (store, state)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<400 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NSError(domain: "DirectoryMoveTests.Timeout", code: 1)
    }
}

private final class DirectoryMoveState: @unchecked Sendable {
    let fail: Bool
    let hold: Bool
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private var bodies: [[String: String]] = []
    private var pending: DirectoryMoveProtocol?
    init(fail: Bool, hold: Bool) { self.fail = fail; self.hold = hold }
    var moves: [URLRequest] { lock.withLock { requests } }
    var payloads: [[String: String]] { lock.withLock { bodies } }
    var hasPendingMove: Bool { lock.withLock { pending != nil } }
    func record(_ request: URLRequest, body: [String: String], pending: DirectoryMoveProtocol?) {
        lock.withLock { requests.append(request); bodies.append(body); self.pending = pending }
    }
    func release() {
        let held = lock.withLock { let value = pending; pending = nil; return value }
        held?.finishMove(fail: fail)
    }
}

private final class DirectoryMoveStates: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: DirectoryMoveState] = [:]
    func add(_ state: DirectoryMoveState, host: String) { lock.withLock { values[host] = state } }
    func get(_ host: String) -> DirectoryMoveState? { lock.withLock { values[host] } }
}

private final class DirectoryMoveProtocol: URLProtocol, @unchecked Sendable {
    static let states = DirectoryMoveStates()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let state = Self.states.get(request.url!.host!) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let path = request.url!.path
        if path.hasSuffix("/directories/move-tasks") {
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
            let body = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
            state.record(request, body: body, pending: state.hold ? self : nil)
            if !state.hold { finishMove(fail: state.fail) }
        } else if path.hasSuffix("/navigation") {
            let parent = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "path" }?.value
            let paths: [String]
            if parent == nil { paths = ["/photos"] }
            else if parent == "/photos" { paths = state.moves.isEmpty || state.fail ? ["/photos/source", "/photos/destination"] : ["/photos/destination"] }
            else if parent == "/photos/destination" { paths = state.moves.isEmpty ? [] : ["/photos/destination/source"] }
            else if parent == "/photos/source" || parent == "/photos/destination/source" { paths = [parent! + "/child"] }
            else { paths = [] }
            let directories = paths.map { ["path": $0, "name": ($0 as NSString).lastPathComponent, "photoCount": 0, "hasChildren": true] as [String: Any] }
            deliver(String(data: try! JSONSerialization.data(withJSONObject: ["directories": directories]), encoding: .utf8)!)
        } else if path.hasSuffix("/hidden-directories") { deliver("{\"paths\":[]}") }
        else if path.hasSuffix("/assets") { deliver("{\"items\":[],\"total\":0,\"revision\":1,\"isUpdating\":false}") }
        else if path.hasSuffix("/counts") { deliver("{\"all\":0,\"picked\":0,\"trashed\":0}") }
        else if path.hasSuffix("/revision") { deliver("{\"revision\":1,\"isUpdating\":false}") }
        else { Issue.record("unexpected directory move request: \(path)"); deliver("{}", status: 404) }
    }
    func finishMove(fail: Bool) {
        let payload = Self.states.get(request.url!.host!)?.payloads.last ?? [:]
        let path = payload["path"] ?? ""
        let parent = payload["parentPath"] ?? ""
        let destination = (parent as NSString).appendingPathComponent(payload["name"] ?? (path as NSString).lastPathComponent)
        let response: [String: Any] = fail ? ["error": "destination exists"] : [
            "id": payload["requestID"] ?? UUID().uuidString, "path": path,
            "parentPath": parent, "destination": destination, "status": "completed",
            "phase": "completed", "createdAt": 0, "updatedAt": 1
        ]
        let body = String(data: try! JSONSerialization.data(withJSONObject: response), encoding: .utf8)!
        deliver(body, status: fail ? 409 : 202)
    }
    private func deliver(_ body: String, status: Int = 200) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor private final class DirectoryTestDragInfo: NSObject, NSDraggingInfo {
    let draggingSource: Any?
    let draggingDestinationWindow: NSWindow?
    let draggingPasteboard = NSPasteboard.withUniqueName()
    var draggingLocation = NSPoint.zero
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(source: NSOutlineView, window: NSWindow) { draggingSource = source; draggingDestinationWindow = window }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
