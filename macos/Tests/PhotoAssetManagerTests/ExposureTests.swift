import CoreImage
import Foundation
import ImageIO
import KeepsAPI
import Testing
@testable import PhotoAssetManager

struct ExposureRendererTests {
    @Test func brightPatchConstrainsPositiveExposure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let dark = CIImage(color: CIColor(red: 0.045, green: 0.045, blue: 0.045, colorSpace: space)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 200, height: 200))
        let bright = CIImage(color: CIColor(red: 0.9, green: 0.9, blue: 0.9, colorSpace: space)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 20, height: 20))
        let source = root.appendingPathComponent("source.png")
        try CIContext().writePNGRepresentation(of: bright.composited(over: dark), to: source, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [:])
        let render = try await ExposureRenderer().render(sourceURL: source, outputDirectory: root.appendingPathComponent("result"))
        #expect(render.exposureEV > 0 && render.exposureEV < 0.25)
    }

    @Test func darkImageIsBrightenedWithoutChangingSourceAndProducesAllSizes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.png")
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let image = CIImage(color: CIColor(red: 0.045, green: 0.045, blue: 0.045, colorSpace: space)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 640, height: 320))
        try CIContext().writePNGRepresentation(of: image, to: source, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [:])
        let original = try Data(contentsOf: source)
        let render = try await ExposureRenderer().render(sourceURL: source, outputDirectory: root.appendingPathComponent("render"))
        #expect(render.exposureEV > 1.8 && render.exposureEV <= 2)
        #expect(try Data(contentsOf: source) == original)
        for (url, width) in [(render.standard, 640), (render.thumbnail, 512), (render.browse, 64)] {
            let imageSource = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any])
            #expect(properties[kCGImagePropertyPixelWidth] as? Int == width)
            #expect(properties[kCGImagePropertyProfileName] != nil)
        }
        let repeated = try await ExposureRenderer().render(sourceURL: source, outputDirectory: root.appendingPathComponent("again"))
        #expect(repeated.exposureEV == render.exposureEV)
    }
}

@Suite(.serialized) @MainActor struct ExposureTaskStoreTests {
    @Test func interruptedVersionLookupNeverPersistsPartialSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = KeepsConfiguration(baseURL: URL(string: "https://exposure.test")!, libraryID: "test")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ExposureProtocol.self]
        let state = ExposureProtocol.State(requestID: "", versionLookup: true)
        ExposureProtocol.state = state
        let store = ExposureTaskStore(root: root, session: URLSession(configuration: config))
        store.retryInterval = .seconds(30)
        store.configure(configuration)
        store.setNegative(assetID: UUID(), contentHash: "newhash")
        for _ in 0..<300 {
            if store.tasks.first?.waitingForConnection == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.tasks.first?.waitingForConnection == true)
        #expect(store.tasks.first?.expectedRevision == nil)
        #expect(store.tasks.first?.sourceFilename == nil)
        let restored = ExposureTaskStore(root: root)
        #expect(restored.tasks.first?.expectedRevision == nil)
        // Rapid reconnects must wait for cancellation of the previous runner.
        store.configure(nil)
        store.configure(configuration)
        store.configure(nil)
        store.configure(configuration)
        for _ in 0..<300 {
            if store.tasks.first?.failed == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.tasks.first?.sourceFilename == "new.ARW")
        #expect(store.tasks.first?.sourceHash == "newhash")
        #expect(state.versionCalls == 2)
        store.configure(nil)
    }

    @Test func restartAfterLostCommitResponseUsesSameRequestAndDoesNotUpload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let configuration = KeepsConfiguration(baseURL: URL(string: "https://exposure.test")!, libraryID: "test")
        var job = ExposureTask(id: id, assetID: UUID(), baseURL: configuration.baseURL.absoluteString,
            libraryID: "test", operation: .automatic, requestedContentHash: nil)
        job.phase = .uploading
        job.expectedRevision = 2
        try JSONEncoder().encode([job]).write(to: root.appendingPathComponent("tasks.json"))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ExposureProtocol.self]
        let state = ExposureProtocol.State(requestID: id.uuidString.lowercased())
        ExposureProtocol.state = state
        let store = ExposureTaskStore(root: root, session: URLSession(configuration: config))
        store.retryInterval = .milliseconds(10)
        store.configure(configuration)
        for _ in 0..<300 {
            if store.tasks.first?.phase == .completed { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.tasks.first?.phase == .completed)
        #expect(state.methods == ["GET", "GET"])
        #expect(store.tasks.first?.error == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(id.uuidString.lowercased()).path))
        let restored = ExposureTaskStore(root: root)
        #expect(restored.tasks.first?.phase == .completed)
        store.configure(nil)
    }
}

private final class ExposureProtocol: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        let requestID: String
        let versionLookup: Bool
        var versionCalls = 0
        let lock = NSLock()
        var methods: [String] = []
        init(requestID: String, versionLookup: Bool = false) { self.requestID = requestID; self.versionLookup = versionLookup }
        func response(_ method: String) -> Int { lock.lock(); defer { lock.unlock() }; methods.append(method); return methods.count }
    }
    nonisolated(unsafe) static var state: State!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if Self.state.versionLookup {
            respondToVersionLookup()
            return
        }
        if Self.state.response(request.httpMethod ?? "") == 1 {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let result = KeepsEditState(negativeContentHash: "hash", revision: 3, hasEdit: true,
            sourceAvailable: true, lastRequestID: Self.state.requestID)
        do {
            let data = try JSONEncoder().encode(result)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    private func respondToVersionLookup() {
        let path = request.url!.lastPathComponent
        if path == "versions" {
            Self.state.versionCalls += 1
            if Self.state.versionCalls == 1 {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
            respond(200, data: Data(#"{"items":[{"contentHash":"newhash","width":100,"height":100,"priority":1,"isDefault":false,"userSelected":false,"available":true,"paths":[{"path":"/new.ARW","available":true}]}]}"#.utf8))
        } else if path == "edit" {
            let state = KeepsEditState(negativeContentHash: "oldhash", revision: 2, hasEdit: true,
                                      sourceFilename: "old.heic", sourceAvailable: true)
            do { respond(200, data: try JSONEncoder().encode(state)) }
            catch { client?.urlProtocol(self, didFailWithError: error) }
        } else { respond(409, data: Data("stop at download".utf8)) }
    }
    private func respond(_ status: Int, data: Data) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
