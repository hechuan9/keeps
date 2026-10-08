import Foundation
import Testing
@testable import KeepsAPI

private let assetJSON = """
{"id":"00000000-0000-0000-0000-000000000001","captureTime":"2026-09-26T00:00:00.123Z","cameraMake":"Hasselblad","cameraModel":"X2D","lensModel":"55","originalFilename":"旅行.3FR","contentFingerprint":"hash","metadataFingerprint":"meta","rating":4,"flagState":"picked","colorLabel":null,"tags":["旅行"],"createdAt":"2026-09-26T00:00:00Z","updatedAt":"2026-09-26T00:00:00Z","trashed":false,"preview":{"downloadURL":"https://preview.example/photo.jpg","width":1200,"height":900,"version":"hash"}}
"""

struct KeepsAPITests {
    @Test func trashDirectorySendsStableRequestIDAndReturnsAcceptedTask() async throws {
        let id = UUID()
        let fixture = Fixture { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url!.path == "/api/libraries/library/directories/trash")
            let body = try JSONSerialization.jsonObject(with: request.bodyData) as! [String: String]
            #expect(body == ["path": "/volume2/photo/旅行 & RAW", "confirmationName": "旅行 & RAW", "requestID": id.uuidString.lowercased()])
            return (202, """
            {"id":"\(id)","path":"/volume2/photo/旅行 & RAW","status":"pending","phase":"waiting","error":null,"createdAt":100,"updatedAt":100,"finishedAt":null}
            """)
        }
        let task = try await fixture.client.trashDirectory(path: "/volume2/photo/旅行 & RAW", confirmationName: "旅行 & RAW", requestID: id)
        #expect(task.id == id)
        #expect(task.phase == "waiting")
        #expect(!task.isTerminal)
    }

    @Test func directoryTrashStatusIsReadOnlyAndPreservesTerminalError() async throws {
        let id = UUID()
        let fixture = Fixture { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url!.path == "/api/libraries/library/directories/trash/" + id.uuidString.lowercased())
            return (200, """
            {"id":"\(id)","path":"/volume2/photo/旅行","status":"failed","phase":"failed","error":"Interrupted during native recycle; check NAS recycle bin","createdAt":100,"updatedAt":120,"finishedAt":120}
            """)
        }
        let task = try await fixture.client.directoryTrashTask(id: id)
        #expect(task.isTerminal)
        #expect(task.error == "Interrupted during native recycle; check NAS recycle bin")
        #expect(task.finishedAt == 120)
        let restored = try JSONDecoder().decode(KeepsDirectoryTrashTask.self, from: JSONEncoder().encode(task))
        #expect(restored == task)
    }

    @Test func taskStatusUsesServerPhotoCountsAndAggregatedLongTask() async throws {
        let fixture = Fixture { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url!.path == "/api/libraries/library/task-status")
            return (200, """
            {"automatic":{"status":"running","currentPhoto":"旅行/IMG.3FR","remainingPhotos":17,"failedPhotos":2,"error":"thumbnail failed"},"longTask":{"status":"pending","kind":"reconcile","error":null}}
            """)
        }
        let status = try await fixture.client.taskStatus()
        #expect(status.automatic.currentPhoto == "旅行/IMG.3FR")
        #expect(status.automatic.remainingPhotos == 17)
        #expect(status.automatic.failedPhotos == 2)
        #expect(status.automatic.error == "thumbnail failed")
        #expect(status.longTask.status == "pending")
        #expect(status.longTask.kind == "reconcile")
        #expect(status.longTask.error == nil)
    }

    @Test func idleTaskStatusDecodesNullableFields() throws {
        let status = try JSONDecoder().decode(KeepsTaskStatus.self, from: Data("""
        {"automatic":{"status":"idle","currentPhoto":null,"remainingPhotos":0,"failedPhotos":0,"error":null},"longTask":{"status":"idle","kind":null,"error":null}}
        """.utf8))
        #expect(status.automatic.currentPhoto == nil)
        #expect(status.automatic.remainingPhotos == 0)
        #expect(status.longTask.kind == nil)
    }

    @Test func createDirectoryUsesLibraryAndSeparateParentAndName() async throws {
        let fixture = Fixture { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url!.path == "/api/libraries/library/directories")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-credential")
            let body = try JSONSerialization.jsonObject(with: request.bodyData) as! [String: String]
            #expect(body == ["parentPath": "/volume2/photo", "name": "旅行 & RAW"])
            return (201, "{\"path\":\"/volume2/photo/旅行 & RAW\"}")
        }
        #expect(try await fixture.client.createDirectory(parentPath: "/volume2/photo", name: "旅行 & RAW") == "/volume2/photo/旅行 & RAW")
    }

    @Test func defaultImportOmitsDigestAndDisablesDeduplication() async throws {
        let batchID = UUID()
        let fixture = Fixture { request in
            let body = try JSONSerialization.jsonObject(with: request.bodyData) as! [String: Any]
            #expect(body["deduplicate"] as? Bool == false)
            #expect(body["preserveStructure"] as? Bool == false)
            let files = body["files"] as! [[String: Any]]
            #expect(files.first?["sha256"] == nil)
            return (200, "{\"id\":\"\(batchID)\",\"targetPath\":\"incoming\",\"finished\":false,\"files\":[]}")
        }
        _ = try await fixture.client.prepareImport(KeepsImportManifest(id: batchID, targetPath: "incoming", files: [KeepsImportFile(id: UUID(), relativePath: "IMG.NEF", size: 3)]))
    }

    @Test func importContractPreservesRelativePathsAndServerAllocatedNames() async throws {
        let batchID = UUID()
        let fileID = UUID()
        let digest = String(repeating: "a", count: 64)
        let fixture = Fixture { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-credential")
            #expect(request.httpMethod == "POST")
            if request.url!.path.hasSuffix("/finish") {
                #expect(request.url!.path.contains(batchID.uuidString))
                return (200, """
                {"job":{"id":"job","folderID":"folder","libraryID":"library","path":"/volume2/photo/旅行","status":"pending"}}
                """)
            }
            #expect(request.url!.path == "/api/libraries/library/imports")
            let manifest = try JSONDecoder().decode(KeepsImportManifest.self, from: request.bodyData)
            #expect(manifest.id == batchID)
            #expect(manifest.targetPath == "/volume2/photo/旅行")
            #expect(manifest.files.first?.relativePath == "子目录/IMG.3FR")
            return (200, """
            {"id":"\(batchID.uuidString.lowercased())","targetPath":"/volume2/photo/旅行","finished":false,"files":[{"id":"\(fileID)","relativePath":"子目录/IMG.3FR","fileName":"IMG.1.3FR","size":1024,"sha256":"\(digest)","uploaded":true}]}
            """)
        }
        let manifest = KeepsImportManifest(id: batchID, targetPath: "/volume2/photo/旅行", files: [KeepsImportFile(id: fileID, relativePath: "子目录/IMG.3FR", size: 1024, sha256: digest)])
        let batch = try await fixture.client.prepareImport(manifest)
        #expect(batch.id == batchID)
        #expect(batch.files.first?.fileName == "IMG.1.3FR")
        #expect(batch.files.first?.uploaded == true)
        #expect(try await fixture.client.finishImport(id: batchID).status == "pending")
    }

    @Test func scopedRevisionsPreserveUpdatingAndEncodeDirectory() async throws {
        let path = "/volume2/photo/旅行 & RAW"
        let fixture = Fixture { request in
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            #expect(items == [URLQueryItem(name: "path", value: path), URLQueryItem(name: "includeChildren", value: "true")])
            return (200, """
            {"revision":9223372036854775806,"isUpdating":true,"path":"/volume2/photo/旅行 & RAW","children":[{"path":"/volume2/photo/旅行 & RAW/sub","revision":9223372036854775807,"isUpdating":false}]}
            """)
        }
        let value = try await fixture.client.revision(path: path, includeChildren: true)
        #expect(value.isUpdating)
        #expect(value.path == path)
        #expect(value.children?.first?.revision == Int64.max)
        #expect(value.children?.first?.isUpdating == false)
    }

    @Test func missingCacheStampIsRejectedRatherThanAssumedStable() throws {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(KeepsAssetPage.self, from: Data("{\"items\":[],\"total\":0}".utf8))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(KeepsCatalogRevision.self, from: Data("{\"revision\":1}".utf8))
        }
    }

    @Test func revisionAndVersionSelectionUseLibraryScopedContracts() async throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let fixture = Fixture { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-credential")
            if request.url!.path.hasSuffix("/revision") { return (200, "{\"revision\":9223372036854775806,\"isUpdating\":false}") }
            #expect(request.url!.path.contains("/libraries/library/assets/"))
            if request.httpMethod == "PUT" {
                #expect(request.url!.path.hasSuffix("/default-version"))
                let body = try JSONSerialization.jsonObject(with: request.bodyData) as! [String: String]
                #expect(body == ["contentHash": "hash"])
            } else { #expect(request.url!.path.hasSuffix("/versions")) }
            return (200, """
            {"items":[{"contentHash":"hash","width":6000,"height":4000,"priority":2,"isDefault":true,"userSelected":true,"available":true,"paths":[{"path":"/photo/旅行.jpg","available":true}],"evidence":{}}]}
            """)
        }
        #expect(try await fixture.client.revision().revision == 9223372036854775806)
        let versions = try await fixture.client.versions(assetID: id)
        #expect(versions.first?.filename == "旅行.jpg")
        #expect(versions.first?.available == true)
        let selected = try await fixture.client.setDefaultVersion(assetID: id, contentHash: "hash")
        #expect(selected.first?.isDefault == true)
        #expect(selected.first?.userSelected == true)
    }

    @Test func hiddenDirectoryContractEncodesPathsAndFilterOverride() async throws {
        let fixture = Fixture { request in
            let path = request.url!.path
            if path.hasSuffix("/hidden-directories") {
                if request.httpMethod == "PUT" {
                    let change = try JSONSerialization.jsonObject(with: request.bodyData) as! [String: Any]
                    #expect(change["path"] as? String == "/volume2/photo/私人")
                    #expect(change["hidden"] as? Bool == true)
                } else { #expect(request.httpMethod == "GET") }
                return (200, "{\"paths\":[\"/volume2/photo/私人\"]}")
            }
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            #expect(items?.first { $0.name == "showHidden" }?.value == "true")
            if path.hasSuffix("/counts") { return (200, "{\"all\":1,\"picked\":0,\"trashed\":0}") }
            return (200, "{\"items\":[],\"revision\":1,\"isUpdating\":false,\"total\":0}")
        }
        #expect(try await fixture.client.hiddenDirectories().paths == ["/volume2/photo/私人"])
        #expect(try await fixture.client.setDirectoryHidden(path: "/volume2/photo/私人", hidden: true).paths == ["/volume2/photo/私人"])
        _ = try await fixture.client.counts(showHidden: true)
        var query = KeepsAssetQuery()
        query.showHidden = true
        _ = try await fixture.client.assets(query: query)
    }

    @Test func navigationUsesServerDirectoryPaths() async throws {
        let directory = "/volume2/photo/旅行 & RAW"
        let fixture = Fixture { request in
            #expect(request.url!.path == "/api/libraries/library/navigation")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-credential")
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            if let items {
                #expect(items == [URLQueryItem(name: "path", value: directory)])
                return (200, "{\"path\":\"/volume2/photo/旅行 & RAW\",\"directories\":[]}")
            }
            return (200, "{\"path\":null,\"directories\":[{\"path\":\"/volume2/photo/旅行 & RAW\",\"name\":\"旅行 & RAW\",\"photoCount\":0,\"hasChildren\":false}]}")
        }
        let root = try await fixture.client.navigation()
        #expect(root.path == nil)
        #expect(root.directories.first?.name == "旅行 & RAW")
        #expect(root.directories.first?.hasChildren == false)
        #expect(root.directories.first?.photoCount == 0)
        let empty = try await fixture.client.navigation(path: directory)
        #expect(empty.path == directory)
        #expect(empty.directories.isEmpty)
    }

    @Test func assetRequestsUseServerFilteringAndAuthenticatedWrites() async throws {
        let fixture = Fixture { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-credential")
            let url = try #require(request.url)
            let path = url.path
            if request.httpMethod == "GET", path.hasSuffix("/assets") {
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
                #expect(query.first { $0.name == "q" }?.value == "旅行 & raw")
                #expect(query.first { $0.name == "directory" }?.value == "2026/旅行")
                #expect(query.first { $0.name == "minRating" }?.value == "3")
                #expect(query.first { $0.name == "recursive" }?.value == "false")
                #expect(query.first { $0.name == "cursor" }?.value == "next+page")
                return (200, "{\"items\":[\(assetJSON)],\"revision\":1,\"isUpdating\":false,\"total\":2,\"nextCursor\":\"after-1\"}")
            }
            #expect(path.contains("/api/libraries/library/assets/"))
            if request.httpMethod == "PATCH" {
                let body = try JSONSerialization.jsonObject(with: request.bodyData) as! [String: Any]
                #expect(body["rating"] as? Int == 5)
                #expect(body["colorLabel"] is NSNull)
                #expect(body["tags"] as? [String] == ["新标签"])
            } else if request.httpMethod == "POST" {
                #expect(path.hasSuffix("/trash") || path.hasSuffix("/restore"))
            } else { #expect(request.httpMethod == "GET") }
            return (200, assetJSON)
        }
        var query = KeepsAssetQuery()
        query.q = "旅行 & raw"; query.directory = "2026/旅行"; query.minRating = 3; query.recursive = false; query.cursor = "next+page"
        let page = try await fixture.client.assets(query: query)
        #expect(page.total == 2 && page.nextCursor == "after-1")
        let asset = try #require(page.items.first)
        #expect(asset.originalFilename == "旅行.3FR")
        #expect(asset.preview?.width == 1200)
        #expect(asset.captureTime == "2026-09-26T00:00:00.123Z")
        _ = try await fixture.client.asset(id: asset.id)
        _ = try await fixture.client.updateAsset(id: asset.id, patch: KeepsAssetPatch(rating: 5, clearColorLabel: true, tags: ["新标签"]))
        _ = try await fixture.client.trashAsset(id: asset.id)
        _ = try await fixture.client.restoreAsset(id: asset.id)
    }

    @Test func nasManagementUsesOnlyServerPaths() async throws {
        let folder = "{\"id\":\"folder-1\",\"libraryID\":\"library\",\"path\":\"2026/旅行\",\"active\":true}"
        let job = "{\"id\":\"job-1\",\"folderID\":\"folder-1\",\"libraryID\":\"library\",\"path\":\"2026/旅行\",\"status\":\"failed\",\"error\":\"decode failed\"}"
        let fixture = Fixture { request in
            let path = request.url!.path
            switch (request.httpMethod, path) {
            case ("GET", "/api/libraries/library/folders"): return (200, "{\"rootPath\":\"/photos\",\"folders\":[\(folder)]}")
            case ("POST", "/api/libraries/library/folders"):
                let body = try JSONDecoder().decode([String:String].self, from: request.bodyData)
                #expect(body == ["path":"2026/旅行"])
                return (200, folder)
            case ("DELETE", "/api/libraries/library/folders/folder-1"): return (204, "")
            case ("POST", "/api/libraries/library/folders/folder-1/scan"), ("POST", "/api/libraries/library/jobs/job-1/retry"): return (200, job)
            case ("GET", "/api/libraries/library/jobs"): return (200, "{\"jobs\":[\(job)]}")
            case ("GET", "/api/libraries/library/directories"): return (200, "{\"directories\":[{\"path\":\"2026/旅行\",\"count\":2}]}")
            case ("GET", "/api/libraries/library/counts"): return (200, "{\"all\":2,\"trashed\":1,\"picked\":1}")
            case ("GET", let path) where path.hasPrefix("/api/derivatives/"):
                #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(URLQueryItem(name: "libraryID", value: "library")) == true)
                return (200, "{\"downloadURL\":\"https://preview.example/fresh.jpg\",\"width\":1200,\"height\":900,\"version\":\"hash\"}")
            default: Issue.record("unexpected endpoint: \(path)"); return (404, "missing")
            }
        }
        #expect(try await fixture.client.folders().rootPath == "/photos")
        let added = try await fixture.client.addFolder(path: "2026/旅行")
        #expect(added.active)
        _ = try await fixture.client.scanFolder(id: added.id)
        let jobs = try await fixture.client.jobs()
        #expect(jobs.jobs.first?.error == "decode failed")
        _ = try await fixture.client.retryJob(id: "job-1")
        try await fixture.client.removeFolder(id: added.id)
        #expect(try await fixture.client.directories().first?.count == 2)
        #expect(try await fixture.client.counts().trashed == 1)
        #expect(try await fixture.client.refreshPreview(assetID: UUID()).absoluteString == "https://preview.example/fresh.jpg")
    }

    @Test func nasJobProgressUsesServerCountsAndEpochTimestamps() throws {
        let data = Data("""
        {"jobs":[{"id":"job-1","folderID":"folder-1","libraryID":"library","path":".","status":"running","processed":125000,"skipped":27000,"failed":3,"currentPath":"/photos/旅行/IMG_001.3FR","startedAt":1790424000,"finishedAt":null}]}
        """.utf8)
        let job = try #require(JSONDecoder().decode(KeepsJobsResponse.self, from: data).jobs.first)
        #expect(job.processed == 125000)
        #expect(job.skipped == 27000)
        #expect(job.failed == 3)
        #expect(job.currentPath == "/photos/旅行/IMG_001.3FR")
        #expect(job.startedAt == 1790424000)
        #expect(job.finishedAt == nil)
    }

    @Test func olderJobResponsesDoNotInventProgress() throws {
        let data = Data("""
        {"id":"job-1","folderID":"folder-1","libraryID":"library","path":".","status":"pending"}
        """.utf8)
        let job = try JSONDecoder().decode(KeepsJob.self, from: data)
        #expect(job.processed == nil)
        #expect(job.skipped == nil)
        #expect(job.failed == nil)
        #expect(job.currentPath == nil)
        #expect(job.startedAt == nil)
        #expect(job.finishedAt == nil)
    }

    @Test func omittedAndClearedColorLabelsRemainDistinct() throws {
        let encoder = JSONEncoder()
        let omitted = try JSONSerialization.jsonObject(with: encoder.encode(KeepsAssetPatch(rating: 0))) as! [String: Any]
        #expect(omitted["colorLabel"] == nil)
        let cleared = try JSONSerialization.jsonObject(with: encoder.encode(KeepsAssetPatch(clearColorLabel: true))) as! [String: Any]
        #expect(cleared["colorLabel"] is NSNull)
        #expect(cleared["rating"] == nil)
    }

    @Test func serverErrorsKeepCompleteDetails() async throws {
        let message = String(repeating: "failure ", count: 200)
        let fixture = Fixture { _ in (422, message) }
        do { _ = try await fixture.client.addFolder(path: "../outside"); Issue.record("expected rejection") }
        catch let KeepsAPIError.http(status, body) { #expect(status == 422); #expect(body == message) }
    }

    @Test func invalidConnectionIsRejectedBeforeTransport() async throws {
        let client = KeepsClient(configuration: KeepsConfiguration(baseURL: URL(fileURLWithPath: "/photos"), libraryID: "library"))
        await #expect(throws: KeepsAPIError.self) { _ = try await client.counts() }
    }
}

private final class Fixture {
    let client: KeepsClient
    let host: String
    init(handler: @escaping (URLRequest) throws -> (Int, String)) {
        host = UUID().uuidString.lowercased() + ".invalid"
        StubProtocol.register(host: host, handler: handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        client = KeepsClient(configuration: KeepsConfiguration(baseURL: URL(string: "https://\(host)/api")!, libraryID: "library", accessCredential: "test-credential"), session: URLSession(configuration: configuration))
    }
    deinit { StubProtocol.remove(host: host) }
}
private final class StubProtocol: URLProtocol {
    nonisolated(unsafe) private static var handlers: [String: (URLRequest) throws -> (Int, String)] = [:]
    private static let lock = NSLock()
    static func register(host: String, handler: @escaping (URLRequest) throws -> (Int, String)) { lock.lock(); defer { lock.unlock() }; handlers[host] = handler }
    static func remove(host: String) { lock.lock(); defer { lock.unlock() }; handlers.removeValue(forKey: host) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let handler = Self.handlers[request.url!.host!]; Self.lock.unlock()
        do {
            let (status, body) = try handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private extension URLRequest {
    var bodyData: Data {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var result = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }
}
