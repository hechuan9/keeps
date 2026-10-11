import CoreImage
import Foundation
import KeepsAPI
import Testing
@testable import PhotoAssetManager

@Suite(.serialized) @MainActor struct GeometryTaskStoreTests {
    @Test func cropRejectsChangedRevisionBeforeFetchingImage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = GeometryProtocol.State()
        GeometryProtocol.state = state
        let store = GeometryTaskStore(root: root, session: session())
        store.configure(configuration)
        store.crop(assetID: UUID(), crop: CGRect(x: 0, y: 0, width: 0.5, height: 1), expectedRevision: 2)
        try await wait { store.tasks.first?.failed == true }
        #expect(store.tasks.first?.phase == .preparing)
        #expect(state.paths == ["edit"])
        #expect(store.tasks.first?.error?.contains("conflict") == true)
    }

    @Test func persistedUploadingTaskPreservesRecipeAndRecoversLostCommitResponse() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let taskID = UUID()
        let assetID = UUID()
        let recipe = KeepsEditRecipe(recipeJSON: #"{"modules":["exposure","colorbalancergb"]}"#, xmp: #"<rdf:Description darktable:xmp_version="5"/>"#, metadata: #"{"existing":true}"#)
        let directory = root.appendingPathComponent(taskID.uuidString.lowercased())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = ["standard", "thumbnail", "browse"].map { directory.appendingPathComponent($0 + ".png") }
        for file in files {
            try CIContext().writePNGRepresentation(of: CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 16)),
                to: file, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [:])
        }
        var task = GeometryTask(id: taskID, assetID: assetID, baseURL: configuration.baseURL.absoluteString,
                                libraryID: configuration.libraryID, operation: .rotate, requestedQuarterTurns: 1)
        task.exposureEV = nil
        task.recipe = recipe
        task.expectedRevision = 3
        task.sourceHash = "negative"
        task.phase = .uploading
        task.render = GeometryRender(width: 32, height: 16, standard: files[0], thumbnail: files[1], browse: files[2])
        try JSONEncoder().encode([task]).write(to: root.appendingPathComponent("tasks.json"))
        let state = GeometryProtocol.State()
        GeometryProtocol.state = state
        let store = GeometryTaskStore(root: root, session: session())
        store.retryInterval = .milliseconds(10)
        #expect(store.tasks.first?.recipe == recipe)
        store.configure(configuration)
        try await wait { store.tasks.first?.phase == .completed }
        let committed = try #require(state.commit)
        #expect(committed.recipe == recipe)
        #expect(committed.exposureEV == nil)
        #expect(committed.negativeContentHash == "negative")
        #expect(committed.expectedRevision == 3)
        #expect(committed.requestID == taskID.uuidString.lowercased())
        #expect(committed.algorithmVersion == "geometry-v1")
        #expect(Set(committed.outputs.map(\.role)) == Set(["standard", "thumbnail", "browse"]))
        #expect(state.commitCount == 1)
        #expect(store.completionRevision == 1)
        let reopened = GeometryTaskStore(root: root, session: session())
        #expect(reopened.tasks.first?.phase == .completed)
    }

    @Test func fullRotationWithAvailableNegativePreservesRecipe() async throws {
        try await fullRotation(edited: true)
    }

    @Test func uneditedRotationCommitsZeroExposure() async throws {
        try await fullRotation(edited: false)
    }

    @Test func unavailableNegativeFailsBeforeDownloadingStandard() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = GeometryProtocol.State()
        state.sourceAvailable = false
        GeometryProtocol.state = state
        let store = GeometryTaskStore(root: root, session: session())
        store.configure(configuration)
        store.rotate(assetID: UUID(), quarterTurns: 1)
        try await wait { store.tasks.first?.failed == true }
        #expect(state.paths == ["edit"])
        #expect(store.tasks.first?.phase == .preparing)
        #expect(state.commit == nil)
    }

    private func fullRotation(edited: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let imageURL = root.appendingPathComponent("fixture.png")
        try CIContext().writePNGRepresentation(of: CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 32)),
            to: imageURL, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [:])
        let state = GeometryProtocol.State()
        state.sourceData = try Data(contentsOf: imageURL)
        state.recipe = edited ? KeepsEditRecipe(recipeJSON: #"{"modules":["exposure","colorbalancergb"]}"#,
            xmp: #"<rdf:Description darktable:xmp_version="5"/>"#, metadata: #"{"existing":true}"#) : nil
        state.exposureEV = nil
        GeometryProtocol.state = state
        let store = GeometryTaskStore(root: root, session: session())
        store.retryInterval = .milliseconds(10)
        store.configure(configuration)
        store.rotate(assetID: UUID(), quarterTurns: 1)
        try await wait { store.tasks.first?.phase == .completed || store.tasks.first?.failed == true }
        #expect(store.tasks.first?.phase == .completed)
        let committed = try #require(state.commit)
        #expect(committed.recipe == state.recipe)
        #expect(committed.exposureEV == (edited ? nil : 0))
        #expect(state.paths.contains("current-standard"))
        #expect(committed.outputs.first(where: { $0.role == "standard" })?.width == 32)
        #expect(committed.outputs.first(where: { $0.role == "standard" })?.height == 64)
        #expect(state.uploads == 3)
    }

    private var configuration: KeepsConfiguration {
        KeepsConfiguration(baseURL: URL(string: "https://geometry.test")!, libraryID: "test")
    }
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GeometryProtocol.self]
        return URLSession(configuration: config)
    }
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(predicate())
    }
}

private final class GeometryProtocol: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        let lock = NSLock()
        var paths: [String] = []
        var commit: KeepsEditCommit?
        var commitCount = 0
        var sourceData: Data?
        var recipe: KeepsEditRecipe?
        var uploads = 0
        var sourceAvailable = true
        var exposureEV: Double? = 0.75
    }
    nonisolated(unsafe) static var state: State!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let state = Self.state!
        state.lock.lock()
        defer { state.lock.unlock() }
        state.paths.append(request.url!.lastPathComponent)
        do {
            let data: Data
            if request.httpMethod == "PUT", request.url!.lastPathComponent == "edit" {
                var body = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 8192)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count <= 0 { break }
                        body.append(contentsOf: buffer.prefix(count))
                    }
                }
                let commit = try JSONDecoder().decode(KeepsEditCommit.self, from: body)
                if let recipe = commit.recipe {
                    guard commit.exposureEV == nil, recipe.engine == "darktable", recipe.engineVersion == "5.6.2",
                          let json = recipe.recipeJSON.data(using: .utf8),
                          (try? JSONSerialization.jsonObject(with: json)) is [String: Any],
                          recipe.xmp.contains("darktable:xmp_version") else {
                        throw KeepsAPIError.http(422, "Invalid recipe/exposure contract")
                    }
                } else {
                    guard let ev = commit.exposureEV, ev.isFinite, (-2...2).contains(ev) else {
                        throw KeepsAPIError.http(422, "Exposure required without recipe")
                    }
                }
                guard state.sourceAvailable else { throw KeepsAPIError.http(409, "Negative unavailable") }
                state.commit = commit
                state.commitCount += 1
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                return
            } else if request.url!.lastPathComponent == "edit" {
                data = try JSONEncoder().encode(KeepsEditState(negativeContentHash: "negative", revision: state.commit == nil ? 3 : 4,
                    hasEdit: state.recipe != nil || state.exposureEV != nil, exposureEV: state.recipe == nil ? state.exposureEV : nil, sourceAvailable: state.sourceAvailable, lastRequestID: state.commit?.requestID, recipe: state.recipe))
            } else if request.url!.lastPathComponent == "uploads" {
                data = try JSONEncoder().encode(KeepsEditUploadSession(requestID: "request", objects: ["standard", "thumbnail", "browse"].map {
                    KeepsEditUploadTarget(role: $0, objectRef: KeepsEditObjectRef(bucket: "media", key: $0), uploadURL: URL(string: "https://geometry.test/" + $0)!)
                }))
            } else if request.url!.lastPathComponent == "current-standard" {
                data = state.sourceData ?? Data()
            } else if request.httpMethod == "GET", let id = UUID(uuidString: request.url!.lastPathComponent) {
                data = Data("""
                {"id":"\(id)","cameraMake":"","cameraModel":"","lensModel":"","originalFilename":"original.ARW","contentFingerprint":"hash","metadataFingerprint":"meta","rating":0,"flagState":"unflagged","tags":[],"createdAt":"2024-01-01","updatedAt":"2024-01-01","trashed":false,"standard":{"downloadURL":"https://geometry.test/current-standard","width":64,"height":32,"version":"existing-edit"}}
                """.utf8)
            } else {
                if request.httpMethod == "PUT" { state.uploads += 1 }
                data = Data()
            }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
