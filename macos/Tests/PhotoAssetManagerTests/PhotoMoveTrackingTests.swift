import Foundation
import Testing
import KeepsAPI
@testable import PhotoAssetManager

@MainActor struct PhotoMoveTrackingTests {
    @Test func restartRestoresAcceptedTaskAndOnlyQueriesPersistedID() async throws {
        let id = UUID()
        let fixture = makeFixture(.complete, restoredID: id)
        #expect((fixture.store.photoMove != nil))
        #expect(fixture.store.photoMove?.payload.sourcePath == "/source")
        await fixture.store.photoMoveTracking?.value
        #expect(!(fixture.store.photoMove != nil))
        #expect(fixture.state.postCount == 0)
        #expect(fixture.state.getIDs == [id.uuidString.lowercased()])
        #expect(fixture.preferences.data(forKey: "keeps.pendingPhotoMove") == nil)
    }

    @Test func missingAcceptedTaskRequiresAcknowledgementWithoutResubmitting() async throws {
        let fixture = makeFixture(.missing, restoredID: UUID())
        await fixture.store.photoMoveTracking?.value
        #expect(fixture.store.photoMoveFinished)
        #expect((fixture.store.photoMove != nil))
        #expect(fixture.state.postCount == 0)
        #expect(fixture.state.getIDs.count == 1)
        #expect(fixture.store.photoMoveMessage != nil)
        fixture.store.acknowledgePhotoMoveFailure()
        #expect(!(fixture.store.photoMove != nil))
    }

    @Test func failureSurvivesRestartAndRequiresAcknowledgement() async throws {
        let fixture = makeFixture(.failed, restoredID: UUID())
        await fixture.store.photoMoveTracking?.value
        #expect(fixture.store.photoMoveFinished)
        #expect(fixture.store.photoMoveMessage?.contains("destination exists") == true)
        let restored = makeStore(host: fixture.host, preferences: fixture.preferences)
        #expect(restored.photoMoveFinished)
        #expect(restored.photoMoveTracking == nil)
        #expect(restored.isOperationBlocking)
        restored.acknowledgePhotoMoveFailure()
        #expect(!restored.isOperationBlocking)
    }

    @Test func timeoutPollsSameTaskWithoutResubmission() async throws {
        let id = UUID()
        let fixture = makeFixture(.timeout, restoredID: id)
        await fixture.store.photoMoveTracking?.value
        #expect(fixture.store.photoMove == nil)
        #expect(fixture.state.postCount == 0)
        #expect(fixture.state.getIDs == [id.uuidString.lowercased(), id.uuidString.lowercased()])
    }

    @Test func restoredTaskFromDifferentServerNeverSendsRequest() async throws {
        let fixture = makeFixture(.complete, restoredID: UUID())
        fixture.store.photoMoveTracking?.cancel()
        let restored = LibraryStore(configuration: KeepsConfiguration(baseURL: URL(string: "https://other.invalid")!, libraryID: "test"),
            loadSavedSettings: false, preferences: fixture.preferences)
        #expect(restored.photoMoveFinished)
        #expect(restored.photoMoveTracking == nil)
        #expect(restored.photoMoveMessage?.contains("其他服务器") == true)
    }

    @Test func completedMoveKeepsVisibleAssetsUntilAllLoadedPagesAreRefreshed() async throws {
        let fixture = makeFixture(.complete)
        fixture.state.enableAssetPages()
        fixture.store.showLibrary(directory: "/source")
        try await waitUntil { !fixture.store.isLoading }
        fixture.store.loadMore()
        try await waitUntil { !fixture.store.isLoading }
        let original = fixture.store.assets
        #expect(original.count == 2)
        fixture.state.beginAssetRefresh()
        fixture.store.completePhotoMove()
        #expect(fixture.store.assets == original)
        try await waitUntil { fixture.state.hasPendingAssetPage }
        #expect(fixture.store.assets == original)
        #expect(fixture.state.assetCursors == ["", "next", "", "next"])
        fixture.state.releaseAssetPage()
        try await waitUntil { !fixture.store.isLoading }
        #expect(fixture.store.assets.map(\.originalFilename) == ["refreshed-2.jpg", "refreshed-3.jpg"])
        #expect(fixture.store.total == 2)
        #expect(fixture.store.nextCursor == nil)
    }

    @Test func completedDirectoryMoveRelocatesQueryWithoutClearingLoadedPages() async throws {
        let fixture = makeFixture(.complete)
        fixture.state.enableAssetPages()
        fixture.store.showLibrary(directory: "/source")
        try await waitUntil { !fixture.store.isLoading }
        fixture.store.loadMore()
        try await waitUntil { !fixture.store.isLoading }
        let original = fixture.store.assets
        #expect(original.count == 2)
        fixture.state.beginAssetRefresh()
        fixture.store.completeDirectoryMove(path: "/source", parentPath: "/target", destination: "/target/source")
        #expect(fixture.store.query.directory == "/target/source")
        #expect(fixture.store.assets == original)
        try await waitUntil { fixture.state.hasPendingAssetPage && !fixture.store.isLoadingNavigation }
        #expect(fixture.store.query.directory == "/target/source")
        #expect(fixture.store.assets == original)
        #expect(fixture.state.assetCursors == ["", "next", "", "next"])
        fixture.state.releaseAssetPage()
        try await waitUntil { !fixture.store.isLoading }
        #expect(fixture.store.query.directory == "/target/source")
        #expect(fixture.store.assets.map(\.originalFilename) == ["refreshed-2.jpg", "refreshed-3.jpg"])
        #expect(fixture.store.total == 2)
        #expect(fixture.store.nextCursor == nil)
    }

    @Test func completedMoveRefreshFailurePreservesVisibleAssets() async throws {
        let fixture = makeFixture(.complete)
        fixture.state.enableAssetPages()
        fixture.store.showLibrary(directory: "/source")
        try await waitUntil { !fixture.store.isLoading }
        fixture.store.loadMore()
        try await waitUntil { !fixture.store.isLoading }
        let original = fixture.store.assets
        fixture.state.beginAssetRefresh()
        fixture.store.completePhotoMove()
        try await waitUntil { fixture.state.hasPendingAssetPage }
        fixture.state.releaseAssetPage(fail: true)
        try await waitUntil { !fixture.store.isLoading }
        #expect(fixture.store.assets == original)
        #expect(fixture.store.lastError?.contains("移动已完成") == true)
        #expect(fixture.store.nextCursor == nil)
    }

    @Test func completedMoveRevisionConflictKeepsOldPagesAndRetryRestoresDragging() async throws {
        let fixture = makeFixture(.complete)
        fixture.state.enableAssetPages()
        fixture.store.showLibrary(directory: "/source")
        try await waitUntil { !fixture.store.isLoading }
        fixture.store.loadMore()
        try await waitUntil { !fixture.store.isLoading }
        let original = fixture.store.assets
        let firstID = try #require(original.first?.id)
        #expect(fixture.store.photoDragPayload(for: firstID) != nil)
        fixture.state.beginAssetRefresh()
        fixture.store.completePhotoMove()
        try await waitUntil { fixture.state.hasPendingAssetPage }
        fixture.state.releaseAssetPage(revision: 3)
        try await waitUntil { !fixture.store.isLoading }
        #expect(fixture.store.assets == original)
        #expect(fixture.store.query.directory == "/source")
        #expect(fixture.store.lastError?.contains("移动已完成") == true)
        #expect(!fixture.store.hasCurrentPhotoResults)
        #expect(fixture.store.photoDragPayload(for: firstID) == nil)
        fixture.store.refresh()
        try await waitUntil { fixture.state.hasPendingAssetPage }
        #expect(fixture.store.assets == original)
        fixture.state.releaseAssetPage()
        try await waitUntil { !fixture.store.isLoading }
        #expect(fixture.store.assets.map(\.originalFilename) == ["refreshed-2.jpg", "refreshed-3.jpg"])
        #expect(fixture.state.assetCursors == ["", "next", "", "next", "", "next"])
        #expect(fixture.store.lastError == nil)
        #expect(fixture.store.hasCurrentPhotoResults)
        #expect(fixture.store.photoDragPayload(for: try #require(fixture.store.assets.first?.id)) != nil)
    }

    @Test func recursiveMoveRefreshRetainsMovedPhotoReturnedByServer() async throws {
        let fixture = makeFixture(.complete)
        fixture.state.enableAssetPages()
        fixture.store.refresh()
        try await waitUntil { !fixture.store.isLoading }
        let movedID = try #require(fixture.store.assets.first?.id)
        #expect(fixture.store.query.recursive)
        fixture.state.beginAssetRefresh(retainMoved: true)
        fixture.store.completePhotoMove()
        try await waitUntil { !fixture.store.isLoading }
        #expect(fixture.store.assets.first?.id == movedID)
        #expect(fixture.store.assets.first?.originalFilename == "refreshed-1.jpg")
    }

    private func makeFixture(_ behavior: PhotoMoveTrackingState.Behavior, restoredID: UUID? = nil, name: String? = nil) -> (store: LibraryStore, state: PhotoMoveTrackingState, preferences: UserDefaults, host: String) {
        let host = UUID().uuidString.lowercased() + ".invalid"
        let preferences = UserDefaults(suiteName: host)!
        let state = PhotoMoveTrackingState(behavior, name: name)
        PhotoMoveTrackingProtocol.states.add(state, host: host)
        if let id = restoredID {
            var query = KeepsAssetQuery()
            query.directory = "/source"
            let payload = PhotoDragPayload(assetIDs: [UUID(uuidString: "00000000-0000-0000-0000-000000000001")!], sourcePath: "/source", baseURL: "https://" + host, libraryID: "test", query: query)
            let pending = PendingPhotoMove(id: id, payload: payload, parentPath: "/target", startedAt: Date(), accepted: true)
            preferences.set(try! JSONEncoder().encode(pending), forKey: "keeps.pendingPhotoMove")
        }
        return (makeStore(host: host, preferences: preferences), state, preferences, host)
    }

    private func makeStore(host: String, preferences: UserDefaults) -> LibraryStore {
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [PhotoMoveTrackingProtocol.self]
        let store = LibraryStore(configuration: KeepsConfiguration(baseURL: URL(string: "https://" + host)!, libraryID: "test"),
            session: URLSession(configuration: session), loadSavedSettings: false, preferences: preferences,
            persistConfiguration: { _ in })
        store.photoMovePollInterval = .milliseconds(5)
        return store
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<400 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NSError(domain: "PhotoMoveTrackingTests.Timeout", code: 1)
    }
}

private final class PhotoMoveTrackingState: @unchecked Sendable {
    enum Behavior { case phases, timeout, complete, failed, missing }
    let name: String?
    let behavior: Behavior
    private let lock = NSLock()
    private var posts: [String] = []
    private var gets: [String] = []
    private var pending: PhotoMoveTrackingProtocol?
    init(_ behavior: Behavior, name: String? = nil) { self.behavior = behavior; self.name = name }
    var postCount: Int { lock.withLock { posts.count } }
    var postIDs: [String] { lock.withLock { posts } }
    var getIDs: [String] { lock.withLock { gets } }
    var hasPendingPoll: Bool { lock.withLock { pending != nil } }
    private var assetPagesEnabled = false
    private var refreshingAssets = false
    private var retainMovedAsset = false
    private var cursors: [String] = []
    private var pendingAssetPage: PhotoMoveTrackingProtocol?
    var assetCursors: [String] { lock.withLock { cursors } }
    var hasPendingAssetPage: Bool { lock.withLock { pendingAssetPage != nil } }
    func enableAssetPages() { lock.withLock { assetPagesEnabled = true } }
    func beginAssetRefresh(retainMoved: Bool = false) {
        lock.withLock { refreshingAssets = true; retainMovedAsset = retainMoved }
    }
    func serveAssets(_ request: PhotoMoveTrackingProtocol) -> Bool {
        let cursor = URLComponents(url: request.request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "cursor" }?.value ?? ""
        let response: (Bool, Bool, Int)? = lock.withLock {
            guard assetPagesEnabled else { return nil }
            cursors.append(cursor)
            if refreshingAssets && !cursor.isEmpty {
                pendingAssetPage = request
                return (true, true, 0)
            }
            let number = refreshingAssets && !retainMovedAsset ? 2 : (cursor.isEmpty ? 1 : 2)
            return (false, refreshingAssets, number)
        }
        guard let response else { return false }
        if !response.0 { request.assetResponse(number: response.2, refreshed: response.1, hasNext: cursor.isEmpty) }
        return true
    }
    func releaseAssetPage(fail: Bool = false, revision: Int = 2) {
        let request = lock.withLock { let value = pendingAssetPage; pendingAssetPage = nil; return value }
        if fail { request?.failAssetResponse() }
        else { request?.assetResponse(number: 3, refreshed: true, hasNext: false, revision: revision) }
    }
    func record(id: String, isPost: Bool) -> Int {
        lock.withLock {
            if isPost { posts.append(id); return posts.count }
            gets.append(id); return gets.count
        }
    }
    func hold(_ request: PhotoMoveTrackingProtocol) { lock.withLock { pending = request } }
    func release(phase: String, status: String) {
        let request = lock.withLock { let value = pending; pending = nil; return value }
        request?.taskResponse(id: request!.request.url!.lastPathComponent, phase: phase, status: status)
    }
}

private final class PhotoMoveTrackingStates: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: PhotoMoveTrackingState] = [:]
    func add(_ state: PhotoMoveTrackingState, host: String) { lock.withLock { values[host] = state } }
    func get(_ host: String) -> PhotoMoveTrackingState? { lock.withLock { values[host] } }
}

private final class PhotoMoveTrackingProtocol: URLProtocol, @unchecked Sendable {
    static let states = PhotoMoveTrackingStates()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let state = Self.states.get(request.url!.host!) else { return }
        let path = request.url!.path
        guard path.contains("/assets/move-tasks") else {
            if path.hasSuffix("/navigation"), URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "path" && $0.value == "/target" }) == true {
                deliver("{\"directories\":[{\"path\":\"/target/source\",\"name\":\"source\",\"photoCount\":2,\"hasChildren\":false}]}")
            }
            else if path.hasSuffix("/navigation") { deliver("{\"directories\":[{\"path\":\"/source\",\"name\":\"source\",\"photoCount\":2,\"hasChildren\":false},{\"path\":\"/target\",\"name\":\"target\",\"photoCount\":1,\"hasChildren\":false}]}") }
            else if path.hasSuffix("/hidden-directories") { deliver("{\"paths\":[]}") }
            else if path.hasSuffix("/assets") { if state.serveAssets(self) { return }; deliver("{\"items\":[],\"total\":0,\"revision\":1,\"isUpdating\":false}") }
            else if path.hasSuffix("/counts") { deliver("{\"all\":0,\"picked\":0,\"trashed\":0}") }
            else if path.hasSuffix("/revision") { deliver("{\"revision\":1,\"isUpdating\":false}") }
            else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)) }
            return
        }
        let isPost = request.httpMethod == "POST"
        var id = request.url!.lastPathComponent.lowercased()
        if isPost {
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(buffer, count: count)
                }
            }
            let payload = try? JSONDecoder().decode([String: String].self, from: data)
            id = (payload?["requestID"] ?? "missing-id").lowercased()
        }
        let count = state.record(id: id, isPost: isPost)
        switch state.behavior {
        case .phases:
            if isPost { taskResponse(id: id, phase: "moving", status: "running", code: 202) }
            else { state.hold(self) }
        case .timeout:
            if isPost || count == 1 { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)) }
            else { taskResponse(id: id) }
        case .complete: taskResponse(id: id)
        case .failed: taskResponse(id: id, phase: "failed", status: "failed", error: "destination exists", code: 202)
        case .missing: deliver("{\"error\":\"task missing\"}", code: 404)
        }
    }
    func taskResponse(id: String, phase: String = "completed", status: String = "completed", error: String? = nil, code: Int = 200) {
        var body: [String: Any] = ["id": id, "sourcePath": "/source", "parentPath": "/target", "assetIDs": ["00000000-0000-0000-0000-000000000001"],
            "status": status, "phase": phase, "createdAt": 0, "updatedAt": 1]
        body["error"] = error
        deliver(String(data: try! JSONSerialization.data(withJSONObject: body), encoding: .utf8)!, code: code)
    }
    func failAssetResponse() { client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)) }
    func assetResponse(number: Int, refreshed: Bool, hasNext: Bool, revision: Int? = nil) {
        let asset: [String: Any] = [
            "id": String(format: "00000000-0000-0000-0000-%012d", number),
            "cameraMake": "", "cameraModel": "", "lensModel": "",
            "originalFilename": "\(refreshed ? "refreshed" : "original")-\(number).jpg",
            "contentFingerprint": "content-\(number)", "metadataFingerprint": "metadata-\(number)",
            "rating": 0, "flagState": "none", "tags": [], "createdAt": "", "updatedAt": "", "trashed": false
        ]
        var page: [String: Any] = ["items": [asset], "total": 2, "revision": revision ?? (refreshed ? 2 : 1), "isUpdating": false]
        if hasNext { page["nextCursor"] = "next" }
        deliver(String(data: try! JSONSerialization.data(withJSONObject: page), encoding: .utf8)!)
    }
    private func deliver(_ body: String, code: Int = 200) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
