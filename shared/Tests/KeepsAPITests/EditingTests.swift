import Foundation
import Testing
@testable import KeepsAPI

struct EditingTests {
    @Test func comparisonSnapshotDownloadsCurrentStandardIndependentlyOfNegative() async throws {
        let id = UUID()
        let fixture = EditingFixture { request in
            if request.url?.path == "/api/derivatives/\(id)" {
                #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(URLQueryItem(name: "role", value: "standard")) == true)
                return (200, "{\"downloadURL\":\"https://\(request.url!.host!)/current-standard\",\"version\":\"published-version\",\"width\":100,\"height\":100}")
            }
            #expect(request.url?.path == "/current-standard")
            return (200, "current displayed photo")
        }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        try await fixture.client.downloadCurrentStandard(assetID: id, to: destination)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "current displayed photo")
    }

    @Test func darktableRecipeRoundtripsWithoutExposureField() throws {
        let recipe = KeepsEditRecipe(recipeJSON: "{\"exposureEV\":0.5}", xmp: "<rdf:Description darktable:xmp_version=\"5\"/>")
        let commit = KeepsEditCommit(requestID: UUID().uuidString, expectedRevision: 2,
            negativeContentHash: "source", algorithmVersion: "ai-v1", rendererVersion: "darktable-5.6.2", outputs: [], recipe: recipe)
        let data = try JSONEncoder().encode(commit)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["exposureEV"] == nil)
        #expect(try JSONDecoder().decode(KeepsEditCommit.self, from: data).recipe == recipe)
        let state = KeepsEditState(negativeContentHash: "source", revision: 3, hasEdit: true, sourceAvailable: true, recipe: recipe)
        #expect(try JSONDecoder().decode(KeepsEditState.self, from: JSONEncoder().encode(state)).recipe == recipe)
    }
    @Test func commitPreservesRevisionSourceAndCompleteOutputSet() async throws {
        let assetID = UUID()
        let requestID = UUID().uuidString.lowercased()
        let outputs = ["standard", "thumbnail", "browse"].map {
            KeepsEditOutput(role: $0, objectRef: KeepsEditObjectRef(bucket: "media", key: "edits/\(requestID)/\($0).heic"), contentHash: "hash-\($0)", width: 512, height: 384, sizeBytes: 128)
        }
        let fixture = EditingFixture { request in
            #expect(request.httpMethod == "PUT")
            #expect(request.url?.path == "/api/libraries/library/assets/\(assetID)/edit")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-credential")
            let body = try JSONSerialization.jsonObject(with: request.editingBody) as! [String: Any]
            #expect(body["requestID"] as? String == requestID)
            #expect(body["expectedRevision"] as? Int == 7)
            #expect(body["negativeContentHash"] as? String == "source-hash")
            #expect(body["exposureEV"] as? Double == 0.75)
            let sentOutputs = try #require(body["outputs"] as? [[String: Any]])
            #expect(sentOutputs.compactMap { $0["objectRef"] as? [String: String] } == outputs.map { ["bucket": $0.objectRef.bucket, "key": $0.objectRef.key] })
            #expect(sentOutputs.compactMap { $0["role"] as? String } == outputs.map(\.role))
            return (200, """
            {"negativeContentHash":"source-hash","revision":8,"hasEdit":true,"exposureEV":0.75,"sourceAvailable":true,"lastRequestID":"\(requestID)"}
            """)
        }
        let state = try await fixture.client.commitEdit(assetID: assetID, edit: KeepsEditCommit(
            requestID: requestID, expectedRevision: 7, negativeContentHash: "source-hash", exposureEV: 0.75,
            algorithmVersion: "auto-v1", rendererVersion: "core-image-v1", outputs: outputs))
        #expect(state.revision == 8)
        #expect(state.lastRequestID == requestID)
        #expect(state.negativeContentHash == "source-hash")
        #expect(state.hasEdit)
    }

    @Test func uploadPreparationDecodesServerObjectReferences() async throws {
        let assetID = UUID()
        let requestID = UUID()
        let fixture = EditingFixture { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/api/libraries/library/assets/\(assetID)/edit/uploads")
            let body = try JSONSerialization.jsonObject(with: request.editingBody) as! [String: String]
            #expect(body["requestID"] == requestID.uuidString.lowercased())
            return (200, """
            {"requestID":"\(requestID.uuidString.lowercased())","objects":[{"role":"standard","objectRef":{"bucket":"media","key":"edits/standard.heic"},"uploadURL":"https://nas.invalid/upload/standard"}]}
            """)
        }
        let session = try await fixture.client.prepareEditUploads(assetID: assetID, requestID: requestID)
        let target = try #require(session.objects.first)
        #expect(session.requestID == requestID.uuidString.lowercased())
        #expect(target.objectRef.bucket == "media")
        #expect(target.objectRef.key == "edits/standard.heic")
    }

    @Test func negativeAndResetRetriesPreserveIdempotencyIdentity() async throws {
        let assetID = UUID()
        let requestID = UUID()
        let fixture = EditingFixture { request in
            let body = try JSONSerialization.jsonObject(with: request.editingBody) as! [String: Any]
            #expect(body["requestID"] as? String == requestID.uuidString.lowercased())
            #expect(body["expectedRevision"] as? Int == 12)
            if request.httpMethod == "PUT" {
                #expect(request.url?.path == "/api/libraries/library/assets/\(assetID)/negative-version")
                #expect(body["contentHash"] as? String == "new-negative")
            } else {
                #expect(request.httpMethod == "DELETE")
                #expect(request.url?.path == "/api/libraries/library/assets/\(assetID)/edit")
            }
            return (200, """
            {"negativeContentHash":"new-negative","revision":13,"hasEdit":false,"sourceAvailable":true,"lastRequestID":"\(requestID.uuidString.lowercased())"}
            """)
        }
        for _ in 0..<2 {
            let selected = try await fixture.client.setNegativeVersion(assetID: assetID, contentHash: "new-negative", expectedRevision: 12, requestID: requestID)
            #expect(selected.lastRequestID == requestID.uuidString.lowercased())
            let reset = try await fixture.client.resetEdit(assetID: assetID, expectedRevision: 12, requestID: requestID)
            #expect(reset.revision == 13)
        }
    }

    @Test func revisionConflictPreservesServerEvidence() async throws {
        let evidence = "{\"error\":\"negative changed\",\"currentRevision\":14}"
        let fixture = EditingFixture { _ in (409, evidence) }
        do {
            _ = try await fixture.client.resetEdit(assetID: UUID(), expectedRevision: 12, requestID: UUID())
            Issue.record("expected revision conflict")
        } catch let KeepsAPIError.http(status, body) {
            #expect(status == 409)
            #expect(body == evidence)
        }
    }

    @Test func uploadRejectsNonHTTPAndEmbeddedCredentialsBeforeTransport() async throws {
        let fixture = EditingFixture { _ in
            Issue.record("invalid upload URL must never reach transport")
            return (200, "")
        }
        let urls = ["file:///tmp/image.heic", "ftp://\(fixture.host)/image", "https://user:password@\(fixture.host)/image", "https://user@\(fixture.host)/image"]
        for url in urls {
            do {
                try await fixture.client.uploadEditImage(
                    target: KeepsEditUploadTarget(role: "standard", objectRef: KeepsEditObjectRef(bucket: "media", key: "image"), uploadURL: URL(string: url)!),
                    file: URL(fileURLWithPath: "/nonexistent-editing-test-image"))
                Issue.record("expected invalid upload URL rejection")
            } catch KeepsAPIError.invalidResponse {
                // Rejection precedes opening the local file or attaching credentials to a request.
            }
        }
    }

    @Test func signedPublicAliasUploadDoesNotForwardAPICredentials() async throws {
        let fixture = EditingFixture { _ in
            Issue.record("signed upload should use the public alias")
            return (200, "")
        }
        let publicHost = UUID().uuidString.lowercased() + ".invalid"
        let signedURL = URL(string: "http://\(publicHost):8088/media/image?signature=test-signature&expires=2000000000")!
        let payload = Data("rendered image fixture".utf8)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".heic")
        try payload.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        EditingProtocol.register(host: publicHost) { request in
            #expect(request.url == signedURL)
            #expect(request.httpMethod == "PUT")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "image/heic")
            let body = try request.editingBody
            #expect(body == payload)
            return (200, "")
        }
        defer { EditingProtocol.remove(host: publicHost) }
        try await fixture.client.uploadEditImage(
            target: KeepsEditUploadTarget(role: "standard", objectRef: KeepsEditObjectRef(bucket: "media", key: "image"), uploadURL: signedURL),
            file: file)
    }

    @Test func sourceMetadataRemainsOptionalForEarlierEditResponses() throws {
        let state = try JSONDecoder().decode(KeepsEditState.self, from: Data("""
        {"revision":0,"hasEdit":false,"sourceAvailable":false}
        """.utf8))
        #expect(state.negativeContentHash == nil)
        #expect(state.sourceFileHash == nil)
        #expect(state.sourceSizeBytes == nil)
        #expect(state.lastRequestID == nil)
    }
}

private final class EditingFixture {
    let client: KeepsClient
    let host = UUID().uuidString.lowercased() + ".invalid"
    init(handler: @escaping (URLRequest) throws -> (Int, String)) {
        EditingProtocol.register(host: host, handler: handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EditingProtocol.self]
        client = KeepsClient(configuration: KeepsConfiguration(baseURL: URL(string: "https://\(host)/api")!, libraryID: "library", accessCredential: "test-credential"), session: URLSession(configuration: configuration))
    }
    deinit { EditingProtocol.remove(host: host) }
}

private final class EditingProtocol: URLProtocol {
    nonisolated(unsafe) private static var handlers: [String: (URLRequest) throws -> (Int, String)] = [:]
    private static let lock = NSLock()
    static func register(host: String, handler: @escaping (URLRequest) throws -> (Int, String)) {
        lock.lock(); defer { lock.unlock() }; handlers[host] = handler
    }
    static func remove(host: String) {
        lock.lock(); defer { lock.unlock() }; handlers.removeValue(forKey: host)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let handler = Self.handlers[request.url!.host!]; Self.lock.unlock()
        do {
            guard let handler else { throw URLError(.unsupportedURL) }
            let (status, body) = try handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private extension URLRequest {
    var editingBody: Data {
        get throws {
            if let httpBody { return httpBody }
            guard let stream = httpBodyStream else { return Data() }
            stream.open(); defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
                if count == 0 { break }
                data.append(buffer, count: count)
            }
            return data
        }
    }
}
