import Foundation
import Testing
import KeepsAPI
@testable import PhotoAssetManager

@MainActor struct DirectoryMoveTrackingTests {
    @Test func runningPhasesKeepInteractionBlockedUntilCompletion() async throws {
        let fixture = makeFixture(.phases)
        let store = fixture.store
        let moving = Task { await store.moveDirectory("/source", to: "/target") }
        try await waitUntil { fixture.state.hasPendingPoll }
        #expect(store.directoryMovePhase == "moving")
        #expect(store.isOperationBlocking)
        #expect(fixture.preferences.data(forKey: "keeps.pendingDirectoryMove") != nil)
        store.showLibrary(directory: "another")
        store.setDirectoryExpanded("another", expanded: true)
        #expect(store.query.directory == nil)
        #expect(store.expandedPaths.isEmpty)
        fixture.state.release(phase: "catalog", status: "running")
        try await waitUntil { store.directoryMovePhase == "catalog" && fixture.state.hasPendingPoll }
        #expect(store.isMovingDirectory)
        fixture.state.release(phase: "completed", status: "completed")
        await moving.value
        #expect(!store.isMovingDirectory)
        #expect(fixture.state.postCount == 1)
        #expect(fixture.preferences.data(forKey: "keeps.pendingDirectoryMove") == nil)
    }

    @Test func submissionTimeoutAndPollingTimeoutQuerySameTaskWithoutDuplicateMove() async throws {
        let fixture = makeFixture(.timeout)
        await fixture.store.moveDirectory("/source", to: "/target")
        #expect(!fixture.store.isMovingDirectory)
        #expect(fixture.state.postCount == 1)
        #expect(fixture.state.getIDs.count == 2)
        #expect(Set(fixture.state.getIDs) == Set(fixture.state.postIDs))
        #expect(fixture.preferences.data(forKey: "keeps.pendingDirectoryMove") == nil)
    }

    @Test func restartRestoresAcceptedTaskAndOnlyQueriesPersistedID() async throws {
        let id = UUID()
        let fixture = makeFixture(.complete, restoredID: id)
        #expect(fixture.store.isMovingDirectory)
        #expect(fixture.store.directoryMove?.path == "/source")
        await fixture.store.directoryMoveTracking?.value
        #expect(!fixture.store.isMovingDirectory)
        #expect(fixture.state.postCount == 0)
        #expect(fixture.state.getIDs == [id.uuidString.lowercased()])
        #expect(fixture.preferences.data(forKey: "keeps.pendingDirectoryMove") == nil)
    }

    @Test func restartRestoresRenameNameAndQueriesOriginalTask() async throws {
        let id = UUID()
        let fixture = makeFixture(.complete, restoredID: id, name: "旅行")
        #expect(fixture.store.directoryMove?.name == "旅行")
        await fixture.store.directoryMoveTracking?.value
        #expect(!fixture.store.isMovingDirectory)
        #expect(fixture.state.postCount == 0)
        #expect(fixture.state.getIDs == [id.uuidString.lowercased()])
        #expect(fixture.store.lastError == nil)
    }

    @Test func failedTaskStaysBlockedAcrossRestartUntilAcknowledged() async throws {
        let fixture = makeFixture(.failed)
        await fixture.store.moveDirectory("/source", to: "/target")
        #expect(fixture.store.directoryMoveFinished)
        #expect(fixture.store.isMovingDirectory)
        #expect(fixture.store.directoryMoveMessage?.contains("destination exists") == true)
        let restored = makeStore(host: fixture.host, preferences: fixture.preferences)
        #expect(restored.directoryMoveFinished)
        #expect(restored.isMovingDirectory)
        #expect(restored.directoryMoveTracking == nil)
        #expect(fixture.state.postCount == 1)
        #expect(fixture.state.getIDs.isEmpty)
        restored.acknowledgeDirectoryMoveFailure()
        #expect(!restored.isMovingDirectory)
        #expect(!restored.isOperationBlocking)
        #expect(fixture.preferences.data(forKey: "keeps.pendingDirectoryMove") == nil)
    }

    @Test func missingAcceptedTaskRequiresAcknowledgementWithoutResubmitting() async throws {
        let fixture = makeFixture(.missing, restoredID: UUID())
        await fixture.store.directoryMoveTracking?.value
        #expect(fixture.store.directoryMoveFinished)
        #expect(fixture.store.isMovingDirectory)
        #expect(fixture.state.postCount == 0)
        #expect(fixture.state.getIDs.count == 1)
        #expect(fixture.store.directoryMoveMessage != nil)
        fixture.store.acknowledgeDirectoryMoveFailure()
        #expect(!fixture.store.isMovingDirectory)
    }

    private func makeFixture(_ behavior: MoveTrackingState.Behavior, restoredID: UUID? = nil, name: String? = nil) -> (store: LibraryStore, state: MoveTrackingState, preferences: UserDefaults, host: String) {
        let host = UUID().uuidString.lowercased() + ".invalid"
        let preferences = UserDefaults(suiteName: host)!
        let state = MoveTrackingState(behavior, name: name)
        MoveTrackingProtocol.states.add(state, host: host)
        if let id = restoredID {
            let pending = PendingDirectoryMove(id: id, path: "/source", parentPath: name == nil ? "/target" : "/", baseURL: "https://" + host,
                libraryID: "test", startedAt: Date(), accepted: true, name: name)
            preferences.set(try! JSONEncoder().encode(pending), forKey: "keeps.pendingDirectoryMove")
        }
        return (makeStore(host: host, preferences: preferences), state, preferences, host)
    }

    private func makeStore(host: String, preferences: UserDefaults) -> LibraryStore {
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [MoveTrackingProtocol.self]
        let store = LibraryStore(configuration: KeepsConfiguration(baseURL: URL(string: "https://" + host)!, libraryID: "test"),
            session: URLSession(configuration: session), loadSavedSettings: false, preferences: preferences,
            persistConfiguration: { _ in })
        store.directoryMovePollInterval = .milliseconds(5)
        return store
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<400 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NSError(domain: "DirectoryMoveTrackingTests.Timeout", code: 1)
    }
}

private final class MoveTrackingState: @unchecked Sendable {
    enum Behavior { case phases, timeout, complete, failed, missing }
    let name: String?
    let behavior: Behavior
    private let lock = NSLock()
    private var posts: [String] = []
    private var gets: [String] = []
    private var pending: MoveTrackingProtocol?
    init(_ behavior: Behavior, name: String? = nil) { self.behavior = behavior; self.name = name }
    var postCount: Int { lock.withLock { posts.count } }
    var postIDs: [String] { lock.withLock { posts } }
    var getIDs: [String] { lock.withLock { gets } }
    var hasPendingPoll: Bool { lock.withLock { pending != nil } }
    func record(id: String, isPost: Bool) -> Int {
        lock.withLock {
            if isPost { posts.append(id); return posts.count }
            gets.append(id); return gets.count
        }
    }
    func hold(_ request: MoveTrackingProtocol) { lock.withLock { pending = request } }
    func release(phase: String, status: String) {
        let request = lock.withLock { let value = pending; pending = nil; return value }
        request?.taskResponse(id: request!.request.url!.lastPathComponent, phase: phase, status: status)
    }
}

private final class MoveTrackingStates: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: MoveTrackingState] = [:]
    func add(_ state: MoveTrackingState, host: String) { lock.withLock { values[host] = state } }
    func get(_ host: String) -> MoveTrackingState? { lock.withLock { values[host] } }
}

private final class MoveTrackingProtocol: URLProtocol, @unchecked Sendable {
    static let states = MoveTrackingStates()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let state = Self.states.get(request.url!.host!) else { return }
        let path = request.url!.path
        guard path.contains("/directories/move-tasks") else {
            if path.hasSuffix("/navigation") { deliver("{\"directories\":[]}") }
            else if path.hasSuffix("/hidden-directories") { deliver("{\"paths\":[]}") }
            else if path.hasSuffix("/assets") { deliver("{\"items\":[],\"total\":0,\"revision\":1,\"isUpdating\":false}") }
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
        var body: [String: Any] = ["id": id, "path": "/source", "parentPath": "/target", "destination": "/target/source",
            "status": status, "phase": phase, "createdAt": 0, "updatedAt": 1]
        if let name = Self.states.get(request.url!.host!)?.name {
            body["parentPath"] = "/"
            body["destination"] = "/" + name
        }
        body["error"] = error
        deliver(String(data: try! JSONSerialization.data(withJSONObject: body), encoding: .utf8)!, code: code)
    }
    private func deliver(_ body: String, code: Int = 200) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
