import Foundation
import KeepsAPI
import Testing
@testable import PhotoAssetManager

struct AICullingTests {
    @Test func rejectsDuplicatePhotoAcrossGroups() {
        let result = AICullingResult(groups: [group([photo(0)]), group([photo(0)])])
        #expect(throws: AIEditingFailure.self) { try result.validate(count: 2) }
    }

    @Test func rejectsMissingPhoto() {
        let result = AICullingResult(groups: [group([photo(0), photo(2)])])
        #expect(throws: AIEditingFailure.self) { try result.validate(count: 3) }
    }

    @Test(arguments: [-1, 2]) func rejectsOutOfRangePhoto(index: Int) {
        let result = AICullingResult(groups: [group([photo(0), photo(index)])])
        #expect(throws: AIEditingFailure.self) { try result.validate(count: 2) }
    }

    @Test func acceptsFullyRejectedGroup() throws {
        let result = AICullingResult(groups: [
            group([photo(0, rejected: true)]), group([photo(1, rejected: true)])
        ])
        try result.validate(count: 2)
    }

    @Test func acceptsMultipleRecommendationsAndUniquePhoto() throws {
        let result = AICullingResult(groups: [
            group([photo(2), photo(0), photo(1, rejected: true)]),
            group([photo(3)])
        ])
        try result.validate(count: 4)
    }

    @Test func acceptsSinglePhotoSession() throws {
        try AICullingResult(groups: [group([photo(0)])]).validate(count: 1)
    }

    @Test func rejectsEmptyGroupAlongsideValidPhotos() {
        let result = AICullingResult(groups: [group([photo(0)]), group([])])
        #expect(throws: AIEditingFailure.self) { try result.validate(count: 1) }
    }

    @MainActor @Test(arguments: [true, false])
    func startsEntireDirectoryAndRestoresPreferenceSnapshot(recursive: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = KeepsConfiguration(baseURL: URL(string: "https://directory.invalid")!, libraryID: "test")
        let transport = URLSessionConfiguration.ephemeral
        transport.protocolClasses = [DirectoryCullingProtocol.self]
        let network = URLSession(configuration: transport)
        defer { network.invalidateAndCancel() }
        let store = AICullingStore(root: root)
        store.configure(configuration)
        try store.savePreferences("优先保留自然表情")
        let path = recursive ? "/photos/recursive" : "/photos/direct"
        store.startDirectory(client: KeepsClient(configuration: configuration, session: network),
            path: path, recursive: recursive, instruction: "每个场景保留不同瞬间", showHidden: true)
        for _ in 0..<200 where store.busy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!store.busy)
        #expect(store.error == nil)
        let state = try #require(store.session)
        #expect(state.assets.map(\.originalFilename) == ["first.jpg", "second.jpg"])
        #expect(state.sourcePath == path)
        #expect(state.recursive == recursive)
        #expect(state.preferences == "优先保留自然表情")
        #expect(state.offset == 0)
        #expect(state.groups.isEmpty)
        #expect(!store.finished)
        try store.savePreferences("优先保留构图")
        let restored = AICullingStore(root: root)
        restored.configure(configuration)
        #expect(restored.preferences == "优先保留构图")
        #expect(restored.session?.preferences == "优先保留自然表情")
        #expect(restored.session?.instruction == "每个场景保留不同瞬间")
        #expect(restored.session?.sourcePath == path)
        #expect(restored.session?.assets.map(\.id) == state.assets.map(\.id))
    }

    @MainActor @Test func editedRequirementsPersistWithoutReplacingReviewedGroups() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = KeepsConfiguration(baseURL: URL(string: "https://requirements.invalid")!, libraryID: "test")
        let store = AICullingStore(root: root)
        store.configure(configuration)
        let file = try #require(store.directory).appendingPathComponent("session.json")
        let state = AICullingStore.Session(assets: [], instruction: "旧要求", groups: [group([photo(0)])],
                                           rejected: [0], ratings: [0: 4], preferences: "旧偏好")
        try JSONEncoder().encode(state).write(to: file, options: .atomic)
        let editing = AICullingStore(root: root)
        editing.configure(configuration)
        try editing.savePreferences("新长期偏好")
        try editing.updateRequirements(preferences: "新长期偏好", instruction: "新本次要求")
        let restored = AICullingStore(root: root)
        restored.configure(configuration)
        #expect(restored.preferences == "新长期偏好")
        #expect(restored.session?.instruction == "新本次要求")
        #expect(restored.session?.prompt.contains("新长期偏好") == true)
        #expect(restored.session?.prompt.contains("新本次要求") == true)
        #expect(restored.session?.rejected == [0])
        #expect(restored.session?.groups.count == 1)
    }

    @MainActor @Test(arguments: ["revision-changed.invalid", "catalog-updating.invalid"])
    func rejectsUnstableDirectoryInventory(host: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = KeepsConfiguration(baseURL: URL(string: "https://\(host)")!, libraryID: "test")
        let transport = URLSessionConfiguration.ephemeral
        transport.protocolClasses = [DirectoryCullingProtocol.self]
        let network = URLSession(configuration: transport)
        defer { network.invalidateAndCancel() }
        let store = AICullingStore(root: root)
        store.configure(configuration)
        store.startDirectory(client: KeepsClient(configuration: configuration, session: network),
            path: "/photos/direct", recursive: false, instruction: "保留", showHidden: true)
        for _ in 0..<200 where store.busy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!store.busy)
        #expect(store.session == nil)
        #expect(store.error?.contains("发生变化") == true)
        let restored = AICullingStore(root: root)
        restored.configure(configuration)
        #expect(restored.session == nil)
    }

    @MainActor @Test func resumesFullySavedKeepAllDecisionWithoutRepeatingMutations() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = KeepsConfiguration(baseURL: URL(string: "https://culling-recovery.invalid")!, libraryID: "test")
        let initial = AICullingStore(root: root)
        initial.configure(configuration)
        let file = try #require(initial.directory).appendingPathComponent("session.json")
        let asset = try JSONDecoder().decode(KeepsAsset.self, from: Data("""
        {"id":"00000000-0000-0000-0000-000000000001","cameraMake":"","cameraModel":"","lensModel":"","originalFilename":"sample.jpg","contentFingerprint":"hash","metadataFingerprint":"meta","rating":0,"flagState":"unflagged","tags":[],"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","trashed":false}
        """.utf8))
        // The last keep-all PATCH committed before interruption, while the original selection was empty.
        let state = AICullingStore.Session(assets: [asset], instruction: "保留", offset: 1,
            groups: [group([photo(0)])], rejected: [], pending: [:], confirming: true)
        try JSONEncoder().encode(state).write(to: file, options: .atomic)
        let restored = AICullingStore(root: root)
        restored.configure(configuration)
        #expect(restored.hasPending)
        let transport = URLSessionConfiguration.ephemeral
        transport.protocolClasses = [UnexpectedCullingRequestProtocol.self]
        let session = URLSession(configuration: transport)
        defer { session.invalidateAndCancel() }
        restored.confirm(client: KeepsClient(configuration: configuration, session: session))
        for _ in 0..<200 where restored.busy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!restored.busy)
        #expect(restored.error == nil)
        #expect(restored.finished)
        #expect(!restored.hasPending)
        #expect(restored.session?.completed == 1)
        let persisted = try JSONDecoder().decode(AICullingStore.Session.self, from: Data(contentsOf: file))
        #expect(persisted.groupIndex == 1)
        #expect(!persisted.confirming)
    }

    @Test(arguments: [-1, 0, 6]) func rejectsInvalidRating(rating: Int) {
        let result = AICullingResult(groups: [group([photo(0, rating: rating)])])
        #expect(throws: AIEditingFailure.self) { try result.validate(count: 1) }
    }

    @Test func migratesLegacySelectionsAndPendingWithoutInventingRatings() throws {
        let data = Data("""
        {"assets":[{"id":"00000000-0000-0000-0000-000000000001","cameraMake":"","cameraModel":"","lensModel":"","originalFilename":"sample.jpg","contentFingerprint":"hash","metadataFingerprint":"meta","rating":4,"flagState":"unflagged","tags":[],"createdAt":"","updatedAt":"","trashed":false}],"instruction":"test","offset":1,"groups":[{"title":"group","reason":"reason","photos":[{"index":0,"recommended":true,"reason":"reason"}]}],"groupIndex":0,"kept":[],"completed":0,"pending":{"0":"picked"},"confirming":true}
        """.utf8)
        let restored = try AICullingStore.Session.restore(from: data)
        #expect(restored.rejected == [0])
        #expect(restored.ratings == [0: 4])
        #expect(restored.groups[0].photos[0].rejected == false)
        #expect(restored.groups[0].photos[0].rating == 4)
        #expect(restored.pending[0]?.flagState == "picked")
        #expect(restored.pending[0]?.rating == 4)
        let roundTrip = try AICullingStore.Session.restore(from: JSONEncoder().encode(restored))
        #expect(roundTrip.rejected == restored.rejected)
        #expect(roundTrip.pending[0]?.flagState == "picked")
    }

    @MainActor @Test(arguments: [true, false]) func aiDefaultsOrHumanOverridesCommitBothFields(humanEdits: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = KeepsConfiguration(baseURL: URL(string: "https://culling-write.invalid")!, libraryID: "test")
        let store = AICullingStore(root: root)
        store.configure(configuration)
        let file = try #require(store.directory).appendingPathComponent("session.json")
        let asset = try JSONDecoder().decode(KeepsAsset.self, from: CullingWriteProtocol.asset)
        let initial = AICullingStore.Session(assets: [asset], instruction: "test", offset: 1,
            groups: [group([photo(0, rejected: humanEdits, rating: humanEdits ? 1 : 5)])],
            rejected: humanEdits ? [0] : [], ratings: [0: humanEdits ? 1 : 5])
        try JSONEncoder().encode(initial).write(to: file)
        let editing = AICullingStore(root: root)
        editing.configure(configuration)
        if humanEdits {
            editing.setFlag(index: 0, value: "picked")
            #expect(editing.session?.picked == [0])
            #expect(editing.session?.rejected.isEmpty == true)
            let pickedRestore = AICullingStore(root: root)
            pickedRestore.configure(configuration)
            #expect(pickedRestore.session?.picked == [0])
            editing.setFlag(index: 0, value: "rejected")
            #expect(editing.session?.picked?.isEmpty == true)
            #expect(editing.session?.rejected == [0])
            editing.setFlag(index: 0, value: "unflagged")
            #expect(editing.session?.picked?.isEmpty == true)
            #expect(editing.session?.rejected.isEmpty == true)
            editing.setRating(index: 0, value: 5)
            editing.setRating(index: 0, value: 6)
        }
        let restored = AICullingStore(root: root)
        restored.configure(configuration)
        #expect(restored.session?.rejected.isEmpty == true)
        #expect(restored.session?.ratings[0] == 5)
        let transport = URLSessionConfiguration.ephemeral
        transport.protocolClasses = [CullingWriteProtocol.self]
        let network = URLSession(configuration: transport)
        defer { network.invalidateAndCancel() }
        restored.confirm(client: KeepsClient(configuration: configuration, session: network))
        for _ in 0..<200 where restored.busy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!restored.busy)
        #expect(restored.error == nil)
        #expect(restored.finished)
    }

    private func photo(_ index: Int, rejected: Bool = false, rating: Int = 3) -> AICullingResult.Photo {
        .init(index: index, rejected: rejected, rating: rating, reason: "保留不同瞬间")
    }

    private func group(_ photos: [AICullingResult.Photo]) -> AICullingResult.Group {
        .init(title: "同一场景", reason: "比较构图和瞬间", photos: photos)
    }
}

private final class DirectoryCullingProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, url.path.hasSuffix("/assets"), request.httpMethod == "GET" else {
            Issue.record("目录启动只能读取照片清单，不应调用 AI 或修改照片")
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
        #expect(query["directory"] == "/photos/recursive" || query["directory"] == "/photos/direct")
        #expect(query["recursive"] == (query["directory"] == "/photos/recursive" ? "true" : "false"))
        #expect(query["showHidden"] == "true")
        #expect(query["q"] == "")
        #expect(query["minRating"] == "0")
        #expect(query["trashed"] == "false")
        #expect(query["flagState"] == nil && query["tag"] == nil && query["colorLabel"] == nil)
        let second = query["cursor"] == "next"
        #expect(query["cursor"] == nil || second)
        let items = second ? [asset(2, name: "second.jpg"), asset(3, name: "video.mov"), asset(4, name: "trashed.jpg", trashed: true)] : [asset(1, name: "first.jpg")]
        let revision = second && url.host == "revision-changed.invalid" ? 8 : 7
        let updating = second && url.host == "catalog-updating.invalid"
        let data = Data("""
        {"items":[\(items.joined(separator: ","))],"total":4,"nextCursor":\(second ? "null" : "\"next\""),"revision":\(revision),"isUpdating":\(updating)}
        """.utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    private func asset(_ index: Int, name: String, trashed: Bool = false) -> String {
        """
        {"id":"00000000-0000-0000-0000-00000000000\(index)","cameraMake":"","cameraModel":"","lensModel":"","originalFilename":"\(name)","contentFingerprint":"hash\(index)","metadataFingerprint":"meta","rating":0,"flagState":"unflagged","tags":[],"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","trashed":\(trashed)}
        """
    }
}

private final class UnexpectedCullingRequestProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Issue.record("A fully saved culling decision must advance without repeating NAS requests")
        client?.urlProtocol(self, didFailWithError: URLError(.badURL))
    }
    override func stopLoading() {}
}

private final class CullingWriteProtocol: URLProtocol, @unchecked Sendable {
    static let asset = Data("""
    {"id":"00000000-0000-0000-0000-000000000001","cameraMake":"","cameraModel":"","lensModel":"","originalFilename":"sample.jpg","contentFingerprint":"hash","metadataFingerprint":"meta","rating":5,"flagState":"unflagged","tags":[],"createdAt":"","updatedAt":"","trashed":false}
    """.utf8)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            #expect(request.httpMethod == "PATCH")
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            let patch = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(patch["flagState"] as? String == "unflagged")
            #expect(patch["rating"] as? Int == 5)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.asset)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
