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
        #expect(snapshot.events == ["prepare", "match:a.nef", "match:nested/b.heic", "upload:nested/b.heic", "finish"])
        #expect(snapshot.manifests.first?.deduplicate == true)
        #expect(snapshot.manifests.first?.files.allSatisfy { $0.sha256 == nil } == true)
    }

    @Test func matchesCompletePhotoGroupBeforeUploadThenMovesToNextPhoto() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for name in ["a.jpg", "a.nef.xmp", "a.xmp"] {
            try Data("abc".utf8).write(to: fixture.root.appendingPathComponent(name))
        }
        fixture.store.deduplicate = true
        fixture.store.start(targetPath: "incoming")
        try await waitForCompletion(fixture.store)
        #expect(fixture.store.errorMessage == nil)
        #expect(fixture.state.snapshot().events == ["prepare", "match:a.jpg,a.nef,a.nef.xmp,a.xmp", "upload:a.jpg", "upload:a.nef", "upload:a.nef.xmp", "upload:a.xmp", "match:nested/b.heic", "upload:nested/b.heic", "finish"])
        #expect(fixture.store.sentBytes == 15)
    }

    @Test func matchedGroupsResumeWithoutMatchingAgain() async throws {
        let fixture = try makeFixture(failUpload: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.store.deduplicate = true
        fixture.store.start(targetPath: "incoming")
        try await waitForCompletion(fixture.store)
        #expect(fixture.store.errorMessage != nil)
        fixture.store.start(targetPath: "incoming")
        try await waitForCompletion(fixture.store)
        #expect(fixture.store.errorMessage == nil)
        #expect(fixture.state.snapshot().events.filter { $0.hasPrefix("match:") } == ["match:a.nef", "match:nested/b.heic"])
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
        try Data("changed source".utf8).write(to: fixture.root.appendingPathComponent("nested/b.heic"))
        fixture.store.start(targetPath: "incoming")
        try await waitForCompletion(fixture.store)
        #expect(fixture.store.errorMessage?.contains("来源文件发生变化") == true)
        #expect(fixture.store.job == nil)
        #expect(fixture.state.snapshot().events == previousEvents + ["prepare"])
    }

    @Test func finishTimeoutQueriesSameBatchWithoutUploadingAgain() async throws {
        let fixture = try makeFixture(failFinish: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.store.start(targetPath: "incoming")
        try await waitForCompletion(fixture.store)
        #expect(fixture.store.errorMessage == nil)
        #expect(fixture.store.job?.id == "import-job")
        #expect(fixture.store.sentBytes == 6)
        let snapshot = fixture.state.snapshot()
        #expect(snapshot.events == ["prepare", "upload:a.nef", "upload:nested/b.heic", "finish", "status"])
        #expect(snapshot.manifests.count == 1)
    }

    @Test func publishingPollsUntilFilesAreCommitted() async throws {
        let fixture = try makeFixture(publishing: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.store.start(targetPath: "incoming")
        try await waitForCompletion(fixture.store)
        #expect(fixture.store.errorMessage == nil)
        #expect(fixture.store.job?.id == "import-job")
        #expect(fixture.store.publishedFiles == 2)
        #expect(fixture.state.snapshot().events.suffix(2) == ["finish", "status"])
    }

    @Test func prepareTimeoutRetriesOriginalManifest() async throws {
        let fixture = try makeFixture(failPrepare: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.store.start(targetPath: "incoming")
        try await waitForCompletion(fixture.store)
        #expect(fixture.store.errorMessage == nil)
        #expect(fixture.store.job?.id == "import-job")
        let manifests = fixture.state.snapshot().manifests
        #expect(manifests.count == 2)
        #expect(manifests.first?.id == manifests.last?.id)
    }

    @Test func failedPublicationCanResumeWithoutSourceFiles() async throws {
        let fixture = try makeFixture(failPublication: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.store.start(targetPath: "incoming")
        try await waitForCompletion(fixture.store)
        #expect(fixture.store.errorMessage?.contains("publication failed") == true)
        #expect(fixture.store.job == nil)
        try FileManager.default.removeItem(at: fixture.root)
        fixture.store.start(targetPath: "incoming")
        try await waitForCompletion(fixture.store)
        #expect(fixture.store.errorMessage == nil)
        #expect(fixture.store.job?.id == "import-job")
        #expect(fixture.state.snapshot().events == ["prepare", "upload:a.nef", "upload:nested/b.heic", "finish", "finish"])
    }

    @Test func restartRestoresBatchAndUploadedFiles() async throws {
        let fixture = try makeFixture(failUpload: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.store.start(targetPath: "incoming")
        try await waitForCompletion(fixture.store)
        let previous = try #require(fixture.store.manifest)
        let restored = ImportStore(client: fixture.store.client)
        #expect(restored.manifest?.id == previous.id)
        #expect(restored.fileCount == 2)
        restored.reset()
        #expect(restored.manifest?.id == previous.id)
        restored.start(targetPath: "other")
        try await waitForCompletion(restored)
        #expect(restored.job?.id == "import-job")
        #expect(fixture.state.snapshot().events.filter { $0 == "upload:a.nef" }.count == 1)
    }

    @Test func lostFinalUploadResponseResumesAfterSourceRemoval() async throws {
        let fixture = try makeFixture(failUpload: true, acceptFailedUpload: true)
        fixture.store.start(targetPath: "incoming")
        try await waitForCompletion(fixture.store)
        let id = try #require(fixture.store.manifest?.id)
        #expect(fixture.store.job == nil)
        try FileManager.default.removeItem(at: fixture.root)
        let restored = ImportStore(client: fixture.store.client)
        #expect(restored.manifest?.id == id)
        restored.start(targetPath: "incoming")
        try await waitForCompletion(restored)
        #expect(restored.errorMessage == nil)
        #expect(restored.job?.id == "import-job")
        #expect(fixture.state.snapshot().events.filter { $0 == "upload:nested/b.heic" }.count == 1)
    }

    @Test func processesFirstPhotoDuringSecondUploadAndPauseRestoresSingleConsumer() async throws {
        let fixture = try makeFixture(gatedPipeline: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.store.start(targetPath: "incoming")
        try await waitForEvent("held:upload:1", state: fixture.state)
        try await waitForEvent("source:1", state: fixture.state)
        #expect(fixture.store.completedFiles == 1)
        #expect(fixture.store.job == nil)
        #expect(!fixture.state.snapshot().events.contains("finish"))
        fixture.store.pause()
        try await waitForCompletion(fixture.store)
        #expect(fixture.state.snapshot().events.filter { $0 == "cancel:source" }.count == 1)
        #expect(fixture.state.snapshot().events.filter { $0 == "cancel:upload" }.count == 1)
        fixture.store.start(targetPath: "incoming")
        try await waitForEvent("held:upload:2", state: fixture.state)
        try await waitForEvent("source:2", state: fixture.state)
        #expect(fixture.state.snapshot().events.filter { $0 == "claim:first" }.count == 1)
        fixture.store.pause()
        try await waitForCompletion(fixture.store)
        #expect(fixture.state.snapshot().events.filter { $0 == "cancel:source" }.count == 2)
        #expect(fixture.state.snapshot().events.filter { $0 == "cancel:upload" }.count == 2)
    }

    @Test func mediaFailureCancelsPendingUploadBeforeRetry() async throws {
        let fixture = try makeFixture(gatedPipeline: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.store.start(targetPath: "incoming")
        try await waitForEvent("held:upload:1", state: fixture.state)
        try await waitForEvent("source:1", state: fixture.state)
        fixture.state.failPendingSource()
        try await waitForCompletion(fixture.store)
        #expect(fixture.store.errorMessage != nil)
        #expect(fixture.store.completedFiles == 1)
        #expect(fixture.state.snapshot().events.filter { $0 == "cancel:upload" }.count == 1)
        #expect(!fixture.state.snapshot().events.contains("finish"))
    }

    @Test func twoMediaTasksRunTogetherWhileProgressPollsAndBothRestore() async throws {
        let persistence = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: persistence) }
        let fixture = try makeFixture(gatedPipeline: true, parallelMedia: true, persistenceDirectory: persistence)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.store.start(targetPath: "incoming")
        try await waitForEvent("source:media-1:1", state: fixture.state)
        try await waitForEvent("source:media-2:1", state: fixture.state)
        try await waitForEvent("progress:2", state: fixture.state)
        let deadline = ContinuousClock.now + .seconds(30)
        while fixture.store.indexedFiles < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(fixture.store.indexedFiles >= 2)
        #expect(!fixture.state.snapshot().events.contains("claim:media-3"))
        fixture.store.pause()
        try await waitForCompletion(fixture.store)
        let checkpoint = try #require(FileManager.default.contentsOfDirectory(at: persistence, includingPropertiesForKeys: nil).first)
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: checkpoint)) as? [String: Any])
        #expect((saved["mediaTasks"] as? [[String: Any]])?.count == 2)
        let restored = ImportStore(client: fixture.store.client, persistenceDirectory: persistence)
        restored.start(targetPath: "incoming")
        try await waitForEvent("source:media-1:2", state: fixture.state)
        try await waitForEvent("source:media-2:2", state: fixture.state)
        restored.pause()
        try await waitForCompletion(restored)
        #expect(fixture.state.snapshot().events.filter { $0.hasPrefix("claim:media-") }.count == 2)
        #expect(fixture.state.snapshot().events.filter { $0 == "cancel:source:media-1" }.count == 2)
        #expect(fixture.state.snapshot().events.filter { $0 == "cancel:source:media-2" }.count == 2)
    }

    @Test func legacySingleMediaCheckpointResumesWithoutReclaimingTask() async throws {
        let persistence = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: persistence) }
        let fixture = try makeFixture(gatedPipeline: true, persistenceDirectory: persistence)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.store.start(targetPath: "incoming")
        try await waitForEvent("source:1", state: fixture.state)
        fixture.store.pause()
        try await waitForCompletion(fixture.store)
        let checkpoint = try #require(FileManager.default.contentsOfDirectory(at: persistence, includingPropertiesForKeys: nil).first)
        var saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: checkpoint)) as? [String: Any])
        saved["mediaTask"] = (saved.removeValue(forKey: "mediaTasks") as? [[String: Any]])?.first
        try JSONSerialization.data(withJSONObject: saved).write(to: checkpoint)
        let restored = ImportStore(client: fixture.store.client, persistenceDirectory: persistence)
        restored.start(targetPath: "incoming")
        try await waitForEvent("source:2", state: fixture.state)
        restored.pause()
        try await waitForCompletion(restored)
        #expect(fixture.state.snapshot().events.filter { $0 == "claim:first" }.count == 1)
    }

    private func waitForEvent(_ event: String, state: ImportScenario) async throws {
        // These gates verify ordering, not latency; leave the main actor available to drive imports.
        let deadline = ContinuousClock.now + .seconds(30)
        while !state.snapshot().events.contains(event) {
            guard ContinuousClock.now < deadline else {
                throw NSError(domain: "ImportStoreTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "未收到 HTTP 闸门事件：" + event])
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func makeFixture(failUpload: Bool = false, failFinish: Bool = false, skipFirst: Bool = false, publishing: Bool = false, failPrepare: Bool = false, failPublication: Bool = false, acceptFailedUpload: Bool = false, gatedPipeline: Bool = false, parallelMedia: Bool = false, persistenceDirectory: URL? = nil) throws -> (root: URL, store: ImportStore, state: ImportScenario) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: root.appendingPathComponent("a.nef"))
        try Data("abc".utf8).write(to: root.appendingPathComponent("nested/b.heic"))
        let host = UUID().uuidString.lowercased() + ".invalid"
        let state = ImportScenario(failUpload: failUpload, failFinish: failFinish, skipFirst: skipFirst, publishing: publishing, failPrepare: failPrepare, failPublication: failPublication, acceptFailedUpload: acceptFailedUpload, gatedPipeline: gatedPipeline, parallelMedia: parallelMedia)
        ImportProtocol.scenarios.register(state, host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImportProtocol.self]
        let client = KeepsClient(configuration: KeepsConfiguration(baseURL: URL(string: "https://\(host)")!, libraryID: "test"), session: URLSession(configuration: configuration))
        let store = ImportStore(client: client, persistenceDirectory: persistenceDirectory)
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
    private var failPrepare: Bool
    private var failPublication: Bool
    private var failFinish: Bool
    private let acceptFailedUpload: Bool
    private let skipFirst: Bool
    private let publishing: Bool
    private let gatedPipeline: Bool
    private let parallelMedia: Bool
    private var claimedMedia = 0
    private var progressPolls = 0
    private var pending: [String: ImportProtocol] = [:]
    private var sourceRequests = 0
    private var claimed = false
    private var manifests: [KeepsImportManifest] = []
    private var uploaded: Set<UUID> = []
    private var matched: Set<UUID> = []
    private var events: [String] = []

    init(failUpload: Bool, failFinish: Bool, skipFirst: Bool, publishing: Bool, failPrepare: Bool, failPublication: Bool, acceptFailedUpload: Bool, gatedPipeline: Bool, parallelMedia: Bool) {
        self.parallelMedia = parallelMedia
        self.gatedPipeline = gatedPipeline
        self.acceptFailedUpload = acceptFailedUpload
        self.failPrepare = failPrepare
        self.failPublication = failPublication
        self.publishing = publishing
        self.skipFirst = skipFirst
        self.failUpload = failUpload
        self.failFinish = failFinish
    }

    func snapshot() -> (events: [String], manifests: [KeepsImportManifest]) {
        lock.lock(); defer { lock.unlock() }
        return (events, manifests)
    }

    func hold(_ protocolInstance: ImportProtocol) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard gatedPipeline, let manifest = manifests.last else { return false }
        let request = protocolInstance.request
        let path = request.url!.path
        if request.httpMethod == "PUT", let file = manifest.files.first(where: { path.hasSuffix($0.id.uuidString) }), file.relativePath == "nested/b.heic" {
            let event = "upload:" + file.relativePath
            events.append(event)
            events.append("held:upload:\(events.filter { $0 == event }.count)")
            pending["upload"] = protocolInstance
            return true
        }
        if parallelMedia, path.hasSuffix("/source") {
            let id = request.url!.deletingLastPathComponent().lastPathComponent
            let event = "source:" + id
            events.append(event)
            events.append(event + ":\(events.filter { $0 == event }.count)")
            pending[event] = protocolInstance
            return true
        }
        if path.hasSuffix("/tasks/first/source") {
            sourceRequests += 1
            events.append("source:\(sourceRequests)")
            pending["source"] = protocolInstance
            return true
        }
        return false
    }

    func stopped(_ protocolInstance: ImportProtocol) {
        lock.lock(); defer { lock.unlock() }
        if let key = pending.first(where: { $0.value === protocolInstance })?.key {
            pending.removeValue(forKey: key)
            events.append("cancel:" + key)
        }
    }

    func failPendingSource() {
        lock.lock()
        let source = pending.removeValue(forKey: "source")
        lock.unlock()
        if let source { source.client?.urlProtocol(source, didFailWithError: URLError(.badServerResponse)) }
    }

    func respond(to request: URLRequest) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let path = request.url!.path
        if path.hasSuffix("/imports"), request.httpMethod == "POST" {
            let body = try requestBody(request)
            let manifest = try JSONDecoder().decode(KeepsImportManifest.self, from: body)
            manifests.append(manifest)
            events.append("prepare")
            if failPrepare {
                failPrepare = false
                throw URLError(.timedOut)
            }
            return try JSONSerialization.data(withJSONObject: [
                "id": manifest.id.uuidString, "targetPath": manifest.targetPath, "finished": false,
                "files": manifest.files.map { file in
                    ["id": file.id.uuidString, "relativePath": file.relativePath,
                     "fileName": URL(fileURLWithPath: file.relativePath).lastPathComponent,
                     "size": file.size, "uploaded": uploaded.contains(file.id) || (matched.contains(file.id) && skipFirst && file.relativePath == "a.nef"),
                     "skipped": matched.contains(file.id) && skipFirst && file.relativePath == "a.nef", "matched": matched.contains(file.id)] as [String: Any]
                },
            ])
        }
        guard let manifest = manifests.last else { throw URLError(.badServerResponse) }
        if path.hasSuffix("/match"), request.httpMethod == "POST" {
            struct MatchRequest: Decodable { let files: [KeepsImportFile] }
            let files = try JSONDecoder().decode(MatchRequest.self, from: requestBody(request)).files
            #expect(files.allSatisfy { $0.sha256 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" })
            events.append("match:" + files.map(\.relativePath).joined(separator: ","))
            matched.formUnion(files.map(\.id))
            return try JSONSerialization.data(withJSONObject: [
                "id": manifest.id.uuidString, "targetPath": manifest.targetPath, "finished": false,
                "files": files.map { file in
                    ["id": file.id.uuidString, "relativePath": file.relativePath,
                     "fileName": URL(fileURLWithPath: file.relativePath).lastPathComponent,
                     "size": file.size, "uploaded": uploaded.contains(file.id) || (skipFirst && file.relativePath == "a.nef"),
                     "skipped": skipFirst && file.relativePath == "a.nef", "matched": true] as [String: Any]
                },
            ])
        }
        if request.httpMethod == "PUT", let file = manifest.files.first(where: { path.hasSuffix($0.id.uuidString) }) {
            events.append("upload:" + file.relativePath)
            if failUpload && file.relativePath == "nested/b.heic" {
                failUpload = false
                if acceptFailedUpload { uploaded.insert(file.id) }
                throw NSError(domain: "ImportTest", code: 422, userInfo: [NSLocalizedDescriptionKey: "source rejected"])
            }
            uploaded.insert(file.id)
            return Data("{}".utf8)
        }
        if path.hasSuffix("/worker/claim") {
            if parallelMedia, !uploaded.isEmpty, claimedMedia < 3 {
                claimedMedia += 1
                let id = "media-\(claimedMedia)"
                events.append("claim:" + id)
                return Data("{\"task\":{\"taskID\":\"\(id)\",\"inputHash\":\"unused\",\"filename\":\"a.nef\",\"generateStandard\":false,\"thumbnailEdge\":512,\"thumbnailQuality\":85}}".utf8)
            }
            if gatedPipeline, !parallelMedia, !uploaded.isEmpty, !claimed {
                claimed = true
                events.append("claim:first")
                return Data("{\"task\":{\"taskID\":\"first\",\"inputHash\":\"unused\",\"filename\":\"a.nef\",\"generateStandard\":false,\"generateBrowse\":true,\"thumbnailEdge\":512,\"thumbnailQuality\":85}}".utf8)
            }
            return Data("{\"task\":null}".utf8)
        }
        if path.hasSuffix("/finish"), request.httpMethod == "GET", !events.contains("finish") {
            if parallelMedia {
                progressPolls += 1
                events.append("progress:\(progressPolls)")
            }
            return Data("{\"id\":\"\(manifest.id)\",\"status\":\"uploading\",\"completedFiles\":\(uploaded.count),\"totalFiles\":2,\"indexedFiles\":\(parallelMedia ? progressPolls : uploaded.count),\"indexTotal\":2,\"thumbnailTotal\":2,\"thumbnailCompleted\":0}".utf8)
        }
        if path.hasSuffix("/finish") {
            events.append(request.httpMethod == "GET" ? "status" : "finish")
            #expect(path.contains(manifest.id.uuidString))
            if request.httpMethod == "POST" {
                #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "async", value: "true")])
            }
            if failFinish {
                failFinish = false
                throw URLError(.timedOut)
            }
            if failPublication {
                failPublication = false
                return Data("{\"id\":\"\(manifest.id)\",\"status\":\"failed\",\"completedFiles\":1,\"totalFiles\":2,\"error\":\"publication failed\"}".utf8)
            }
            if publishing, request.httpMethod == "POST" {
                return Data("{\"id\":\"\(manifest.id)\",\"status\":\"publishing\",\"completedFiles\":1,\"totalFiles\":2}".utf8)
            }
            return Data("{\"id\":\"\(manifest.id)\",\"status\":\"finished\",\"completedFiles\":2,\"totalFiles\":2,\"job\":{\"id\":\"import-job\",\"folderID\":\"folder\",\"libraryID\":\"test\",\"path\":\"incoming\",\"status\":\"queued\"}}".utf8)
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
            if state.hold(self) { return }
            let body = try state.respond(to: request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {
        Self.scenarios.state(for: request.url?.host ?? "")?.stopped(self)
    }
}
