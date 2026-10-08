import Foundation
import KeepsAPI
import Testing
@testable import PhotoAssetManager

@MainActor struct ImportStoreTests {
    @Test func preparesUploadsAndFinishesActualSourceFiles() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.store.start(targetPath: "incoming")
        try await waitForCompletion(fixture.store)
        #expect(fixture.store.errorMessage == nil)
        #expect(fixture.store.job?.id == "import-job")
        #expect(fixture.store.completedFiles == 2)
        #expect(fixture.store.sentBytes == 6)
        #expect(fixture.store.totalBytes == 6)
        let snapshot = fixture.state.snapshot()
        #expect(snapshot.events == ["prepare", "upload:a.nef", "upload:nested/b.heic", "finish"])
        #expect(snapshot.manifests.first?.targetPath == "incoming")
        #expect(snapshot.manifests.first?.deduplicate == false)
        #expect(snapshot.manifests.first?.preserveStructure == false)
        #expect(snapshot.manifests.first?.files.allSatisfy { $0.sha256 == nil } == true)
        #expect(snapshot.manifests.first?.files.map(\.relativePath) == ["a.nef", "nested/b.heic"])
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent("a.nef")) == Data("abc".utf8))
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent("nested/b.heic")) == Data("abc".utf8))
    }

    @Test func optionalDeduplicationHashesSourcesAndSkipsMatchedFiles() async throws {
        let fixture = try makeFixture(skipFirst: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.store.deduplicate = true
        fixture.store.start(targetPath: "incoming")
        try await waitForCompletion(fixture.store)
        #expect(fixture.store.errorMessage == nil)
        #expect(fixture.store.skippedFiles == 1)
        #expect(fixture.store.completedFiles == 2)
        let snapshot = fixture.state.snapshot()
        #expect(snapshot.events == ["prepare", "upload:nested/b.heic", "finish"])
        #expect(snapshot.manifests.first?.deduplicate == true)
        #expect(snapshot.manifests.first?.files.allSatisfy { $0.sha256 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" } == true)
    }

    @Test func uploadFailureResumesSameManifestAndSkipsCompletedFile() async throws {
        let fixture = try makeFixture(failUpload: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.store.start(targetPath: "incoming")
        try await waitForCompletion(fixture.store)
        #expect(fixture.store.errorMessage != nil)
        #expect(fixture.store.job == nil)
        #expect(fixture.store.completedFiles == 1)
        let firstManifest = try #require(fixture.store.manifest)

        fixture.store.start(targetPath: "changed-target")
        try await waitForCompletion(fixture.store)
        #expect(fixture.store.errorMessage == nil)
        #expect(fixture.store.job?.id == "import-job")
        #expect(fixture.store.completedFiles == 2)
        let snapshot = fixture.state.snapshot()
        #expect(snapshot.events == ["prepare", "upload:a.nef", "upload:nested/b.heic", "prepare", "upload:nested/b.heic", "finish"])
        #expect(snapshot.manifests.count == 2)
        #expect(snapshot.manifests.allSatisfy { $0.id == firstManifest.id && $0.targetPath == "incoming" })
        #expect(snapshot.manifests.allSatisfy { $0.files.map(\.id) == firstManifest.files.map(\.id) })
    }

    @Test func preservedStructureSurvivesUploadRetry() async throws {
        let fixture = try makeFixture(failUpload: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.store.preserveStructure = true
        fixture.store.start(targetPath: "incoming")
        try await waitForCompletion(fixture.store)
        #expect(fixture.store.errorMessage != nil)
        fixture.store.preserveStructure = false
        fixture.store.start(targetPath: "incoming")
        try await waitForCompletion(fixture.store)
        #expect(fixture.store.errorMessage == nil)
        let manifests = fixture.state.snapshot().manifests
        #expect(manifests.count == 2)
        #expect(manifests.allSatisfy { $0.preserveStructure })
        #expect(manifests.allSatisfy { $0.files.map(\.relativePath) == ["a.nef", "nested/b.heic"] })
    }

    @Test func changedSourcePreventsResumeFromCommittingOldUploads() async throws {
        let fixture = try makeFixture(failUpload: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.store.start(targetPath: "incoming")
        try await waitForCompletion(fixture.store)
        #expect(fixture.store.completedFiles == 1)
        let previousEvents = fixture.state.snapshot().events
        try Data("changed source".utf8).write(to: fixture.root.appendingPathComponent("a.nef"))
        fixture.store.start(targetPath: "incoming")
        try await waitForCompletion(fixture.store)
        #expect(fixture.store.errorMessage?.contains("来源文件发生变化") == true)
        #expect(fixture.store.job == nil)
        #expect(fixture.state.snapshot().events == previousEvents)
    }

    @Test func finishFailureResumesWithoutUploadingAgain() async throws {
        let fixture = try makeFixture(failFinish: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.store.start(targetPath: "incoming")
        try await waitForCompletion(fixture.store)
        #expect(fixture.store.errorMessage != nil)
        #expect(fixture.store.job == nil)
        #expect(fixture.store.completedFiles == 2)
        let firstID = fixture.store.manifest?.id

        fixture.store.start(targetPath: "incoming")
        try await waitForCompletion(fixture.store)
        #expect(fixture.store.errorMessage == nil)
        #expect(fixture.store.job?.id == "import-job")
        #expect(fixture.store.sentBytes == 6)
        let snapshot = fixture.state.snapshot()
        #expect(snapshot.events == ["prepare", "upload:a.nef", "upload:nested/b.heic", "finish", "prepare", "finish"])
        #expect(snapshot.manifests.count == 2)
        #expect(snapshot.manifests.allSatisfy { $0.id == firstID })
    }

    private func makeFixture(failUpload: Bool = false, failFinish: Bool = false, skipFirst: Bool = false) throws -> (root: URL, store: ImportStore, state: ImportScenario) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: root.appendingPathComponent("a.nef"))
        try Data("abc".utf8).write(to: root.appendingPathComponent("nested/b.heic"))
        let host = UUID().uuidString.lowercased() + ".invalid"
        let state = ImportScenario(failUpload: failUpload, failFinish: failFinish, skipFirst: skipFirst)
        ImportProtocol.scenarios.register(state, host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImportProtocol.self]
        let client = KeepsClient(configuration: KeepsConfiguration(baseURL: URL(string: "https://\(host)")!, libraryID: "test"), session: URLSession(configuration: configuration))
        let store = ImportStore(client: client)
        store.selectSource(root)
        return (root, store, state)
    }

    private func waitForCompletion(_ store: ImportStore) async throws {
        for _ in 0..<400 {
            if !store.isBusy { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NSError(domain: "ImportStoreTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "导入未在测试期限内完成"])
    }
}

private final class ImportScenario: @unchecked Sendable {
    private let lock = NSLock()
    private var failUpload: Bool
    private var failFinish: Bool
    private let skipFirst: Bool
    private var manifests: [KeepsImportManifest] = []
    private var uploaded: Set<UUID> = []
    private var events: [String] = []

    init(failUpload: Bool, failFinish: Bool, skipFirst: Bool) {
        self.skipFirst = skipFirst
        self.failUpload = failUpload
        self.failFinish = failFinish
    }

    func snapshot() -> (events: [String], manifests: [KeepsImportManifest]) {
        lock.lock(); defer { lock.unlock() }
        return (events, manifests)
    }

    func respond(to request: URLRequest) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let path = request.url!.path
        if path.hasSuffix("/imports"), request.httpMethod == "POST" {
            let body = try requestBody(request)
            let manifest = try JSONDecoder().decode(KeepsImportManifest.self, from: body)
            manifests.append(manifest)
            events.append("prepare")
            return try JSONSerialization.data(withJSONObject: [
                "id": manifest.id.uuidString, "targetPath": manifest.targetPath, "finished": false,
                "files": manifest.files.map { file in
                    ["id": file.id.uuidString, "relativePath": file.relativePath,
                     "fileName": URL(fileURLWithPath: file.relativePath).lastPathComponent,
                     "size": file.size, "uploaded": uploaded.contains(file.id) || (skipFirst && file.relativePath == "a.nef"),
                     "skipped": skipFirst && file.relativePath == "a.nef"] as [String: Any]
                },
            ])
        }
        guard let manifest = manifests.last else { throw URLError(.badServerResponse) }
        if request.httpMethod == "PUT", let file = manifest.files.first(where: { path.hasSuffix($0.id.uuidString) }) {
            events.append("upload:" + file.relativePath)
            if failUpload && file.relativePath == "nested/b.heic" {
                failUpload = false
                throw URLError(.networkConnectionLost)
            }
            uploaded.insert(file.id)
            return Data("{}".utf8)
        }
        if path.hasSuffix("/finish") {
            events.append("finish")
            if failFinish {
                failFinish = false
                throw URLError(.networkConnectionLost)
            }
            return Data("{\"job\":{\"id\":\"import-job\",\"folderID\":\"folder\",\"libraryID\":\"test\",\"path\":\"incoming\",\"status\":\"queued\"}}".utf8)
        }
        throw URLError(.unsupportedURL)
    }

    private func requestBody(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { throw URLError(.badServerResponse) }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}

private final class ImportScenarioRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [String: ImportScenario] = [:]
    func register(_ state: ImportScenario, host: String) {
        lock.lock(); defer { lock.unlock() }
        states[host] = state
    }
    func state(for host: String) -> ImportScenario? {
        lock.lock(); defer { lock.unlock() }
        return states[host]
    }
}

private final class ImportProtocol: URLProtocol, @unchecked Sendable {
    static let scenarios = ImportScenarioRegistry()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let url = request.url, let state = Self.scenarios.state(for: url.host ?? "") else {
                throw URLError(.unsupportedURL)
            }
            let body = try state.respond(to: request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
