import Foundation

public enum KeepsAPIError: Error, LocalizedError, Sendable {
    case invalidConfiguration
    case invalidResponse
    case http(Int, String)
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "请填写有效的 NAS HTTP/HTTPS 地址和资料库名称。"
        case .invalidResponse: "NAS 返回了非 HTTP 响应。"
        case let .http(status, body): "NAS HTTP \(status)：\(body)"
        }
    }
}

public final class KeepsClient: Sendable {
    // Keep interactive API requests out of the shared preview-download session.
    public static let apiSession = URLSession(configuration: .default)
    public let configuration: KeepsConfiguration
    private let session: URLSession
    public init(configuration: KeepsConfiguration, session: URLSession = KeepsClient.apiSession) {
        self.configuration = configuration
        self.session = session
    }
    private var library: [String] { ["libraries", configuration.libraryID] }

    public func revision(path: String? = nil, includeChildren: Bool = false) async throws -> KeepsCatalogRevision {
        var query: [URLQueryItem] = []
        if let path { query.append(URLQueryItem(name: "path", value: path)) }
        if includeChildren { query.append(URLQueryItem(name: "includeChildren", value: "true")) }
        return try await request("GET", library + ["revision"], query: query)
    }
    public func assets(query: KeepsAssetQuery = KeepsAssetQuery()) async throws -> KeepsAssetPage {
        try await request("GET", library + ["assets"], query: query.queryItems)
    }
    public func asset(id: UUID) async throws -> KeepsAsset {
        try await request("GET", library + ["assets", id.uuidString])
    }
    public func versions(assetID: UUID) async throws -> [KeepsAssetVersion] {
        try await versionDetails(assetID: assetID).items
    }
    public func versionDetails(assetID: UUID) async throws -> KeepsAssetVersions {
        try await request("GET", library + ["assets", assetID.uuidString, "versions"])
    }
    public func downloadVersion(assetID: UUID, contentHash: String, to destination: URL) async throws {
        var request = try makeRequest("GET", library + ["assets", assetID.uuidString, "versions", contentHash, "download"])
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 3600
        let (temporary, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse else { throw KeepsAPIError.invalidResponse }
        guard 200..<300 ~= http.statusCode else { throw KeepsAPIError.http(http.statusCode, "原片下载失败。") }
        let pending = destination.deletingLastPathComponent().appendingPathComponent(".download-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: pending) }
        try FileManager.default.copyItem(at: temporary, to: pending)
        // A completed cache entry is immutable; never overwrite an existing destination.
        try FileManager.default.moveItem(at: pending, to: destination)
    }
    public func setDefaultVersion(assetID: UUID, contentHash: String) async throws -> [KeepsAssetVersion] {
        let response: KeepsAssetVersions = try await request("PUT", library + ["assets", assetID.uuidString, "default-version"], body: JSONEncoder().encode(["contentHash": contentHash]))
        return response.items
    }
    public func confirmOriginalEdit(assetID: UUID, requestID: UUID, expectedRevision: Int64, metadata: String) async throws -> KeepsEditState {
        struct Decision: Encodable { let requestID: String; let expectedRevision: Int64; let metadata: String }
        return try await request("POST", library + ["assets", assetID.uuidString, "edit", "decisions"], body: JSONEncoder().encode(Decision(requestID: requestID.uuidString.lowercased(), expectedRevision: expectedRevision, metadata: metadata)))
    }
    public func editState(assetID: UUID) async throws -> KeepsEditState {
        try await request("GET", library + ["assets", assetID.uuidString, "edit"])
    }
    public func setNegativeVersion(assetID: UUID, contentHash: String, expectedRevision: Int64, requestID: UUID) async throws -> KeepsEditState {
        struct Change: Encodable { let contentHash: String; let expectedRevision: Int64; let requestID: String }
        return try await request("PUT", library + ["assets", assetID.uuidString, "negative-version"],
                                 body: JSONEncoder().encode(Change(contentHash: contentHash, expectedRevision: expectedRevision, requestID: requestID.uuidString.lowercased())))
    }
    public func resetEdit(assetID: UUID, expectedRevision: Int64, requestID: UUID) async throws -> KeepsEditState {
        struct Reset: Encodable { let expectedRevision: Int64; let requestID: String }
        return try await request("DELETE", library + ["assets", assetID.uuidString, "edit"],
                                 body: JSONEncoder().encode(Reset(expectedRevision: expectedRevision, requestID: requestID.uuidString.lowercased())))
    }
    public func prepareEditUploads(assetID: UUID, requestID: UUID) async throws -> KeepsEditUploadSession {
        try await request("POST", library + ["assets", assetID.uuidString, "edit", "uploads"],
                          body: JSONEncoder().encode(["requestID": requestID.uuidString.lowercased()]))
    }
    public func commitEdit(assetID: UUID, edit: KeepsEditCommit) async throws -> KeepsEditState {
        try await request("PUT", library + ["assets", assetID.uuidString, "edit"], body: JSONEncoder().encode(edit))
    }
    public func downloadCurrentStandard(assetID: UUID, to destination: URL) async throws {
        let descriptor = try await refreshPreviewDescriptor(assetID: assetID, role: .standard)
        let (data, response) = try await session.data(from: descriptor.downloadURL)
        let checked = try checkedData(data, response)
        try Task.checkCancellation()
        try checked.write(to: destination, options: .atomic)
    }
    public func downloadNegative(assetID: UUID, contentHash: String, to destination: URL) async throws {
        var request = try makeRequest("GET", library + ["assets", assetID.uuidString, "edit", "source"],
                                      query: [URLQueryItem(name: "contentHash", value: contentHash)])
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60
        let (temporary, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse else { throw KeepsAPIError.invalidResponse }
        guard 200..<300 ~= http.statusCode else {
            let errorBody = try Data(contentsOf: temporary)
            throw KeepsAPIError.http(http.statusCode, String(data: errorBody, encoding: .utf8) ?? "响应体无法解码")
        }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The destination is a private task download, never a user photo location.
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }
    public func uploadEditImage(target: KeepsEditUploadTarget, file: URL) async throws {
        guard ["http", "https"].contains(target.uploadURL.scheme?.lowercased() ?? ""),
              target.uploadURL.host != nil, target.uploadURL.user == nil, target.uploadURL.password == nil else {
            throw KeepsAPIError.invalidResponse
        }
        var request = URLRequest(url: target.uploadURL)
        request.httpMethod = "PUT"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 60
        request.setValue("image/heic", forHTTPHeaderField: "Content-Type")
        // Signed media URLs may use the NAS public address; they never need the API credential.
        let (data, response) = try await session.upload(for: request, fromFile: file)
        _ = try checkedData(data, response)
    }
    public func updateAsset(id: UUID, patch: KeepsAssetPatch) async throws -> KeepsAsset {
        try await request("PATCH", library + ["assets", id.uuidString], body: JSONEncoder().encode(patch))
    }
    public func trashAsset(id: UUID) async throws -> KeepsAsset {
        try await request("POST", library + ["assets", id.uuidString, "trash"])
    }
    public func restoreAsset(id: UUID) async throws -> KeepsAsset {
        try await request("POST", library + ["assets", id.uuidString, "restore"])
    }
    public func counts(showHidden: Bool = false) async throws -> KeepsCounts {
        try await request("GET", library + ["counts"], query: [URLQueryItem(name: "showHidden", value: String(showHidden))])
    }
    public func hiddenDirectories() async throws -> KeepsHiddenDirectories {
        try await request("GET", library + ["hidden-directories"])
    }
    public func setDirectoryHidden(path: String, hidden: Bool) async throws -> KeepsHiddenDirectories {
        struct Change: Encodable { var path: String; var hidden: Bool }
        return try await request("PUT", library + ["hidden-directories"], body: JSONEncoder().encode(Change(path: path, hidden: hidden)))
    }
    public func directories() async throws -> [KeepsDirectory] {
        let response: Directories = try await request("GET", library + ["directories"])
        return response.directories
    }
    public func folders() async throws -> KeepsFoldersResponse { try await request("GET", library + ["folders"]) }
    public func navigation(path: String? = nil) async throws -> KeepsNavigation {
        try await request("GET", library + ["navigation"], query: path.map { [URLQueryItem(name: "path", value: $0)] } ?? [])
    }
    public func createDirectory(parentPath: String, name: String) async throws -> String {
        struct CreatedDirectory: Decodable { var path: String }
        let response: CreatedDirectory = try await request("POST", library + ["directories"], body: JSONEncoder().encode(["parentPath": parentPath, "name": name]))
        return response.path
    }
    public func startPhotoMove(assetIDs: [UUID], sourcePath: String?, parentPath: String, requestID: UUID) async throws -> KeepsPhotoMoveTask {
        struct Move: Encodable { let requestID: String; let assetIDs: [String]; let sourcePath: String?; let parentPath: String }
        let body = Move(requestID: requestID.uuidString.lowercased(), assetIDs: assetIDs.map { $0.uuidString.lowercased() }, sourcePath: sourcePath, parentPath: parentPath)
        return try await request("POST", library + ["assets", "move-tasks"], body: JSONEncoder().encode(body))
    }
    public func photoMoveTask(id: UUID) async throws -> KeepsPhotoMoveTask {
        try await request("GET", library + ["assets", "move-tasks", id.uuidString.lowercased()])
    }
    public func startDirectoryMove(path: String, parentPath: String, requestID: UUID, name: String? = nil) async throws -> KeepsDirectoryMoveTask {
        var body = ["path": path, "parentPath": parentPath, "requestID": requestID.uuidString.lowercased()]
        body["name"] = name
        return try await request("POST", library + ["directories", "move-tasks"], body: JSONEncoder().encode(body))
    }
    public func directoryMoveTask(id: UUID) async throws -> KeepsDirectoryMoveTask {
        try await request("GET", library + ["directories", "move-tasks", id.uuidString.lowercased()])
    }
    public func moveDirectory(path: String, parentPath: String, requestID: UUID = UUID()) async throws -> String {
        struct MovedDirectory: Decodable { var path: String }
        let response: MovedDirectory = try await request("POST", library + ["directories", "move"], body: JSONEncoder().encode(["path": path, "parentPath": parentPath, "requestID": requestID.uuidString.lowercased()]))
        return response.path
    }
    public func previewRejectedTrash() async throws -> KeepsRejectedTrashTask {
        try await request("POST", library + ["rejected-trash", "preview"])
    }
    public func submitRejectedTrash(id: UUID, confirmationCount: Int) async throws -> KeepsRejectedTrashTask {
        try await request("POST", library + ["rejected-trash", id.uuidString.lowercased()], body: JSONEncoder().encode(["confirmationCount": confirmationCount]))
    }
    public func rejectedTrashTask(id: UUID) async throws -> KeepsRejectedTrashTask {
        try await request("GET", library + ["rejected-trash", id.uuidString.lowercased()])
    }

    public func trashDirectory(path: String, confirmationName: String, requestID: UUID) async throws -> KeepsDirectoryTrashTask {
        try await request("POST", library + ["directories", "trash"], body: JSONEncoder().encode(["path": path, "confirmationName": confirmationName, "requestID": requestID.uuidString.lowercased()]))
    }
    public func directoryTrashTask(id: UUID) async throws -> KeepsDirectoryTrashTask {
        try await request("GET", library + ["directories", "trash", id.uuidString.lowercased()])
    }
    public func addFolder(path: String) async throws -> KeepsFolder {
        try await request("POST", library + ["folders"], body: JSONEncoder().encode(["path": path]))
    }
    public func removeFolder(id: String) async throws {
        _ = try await send("DELETE", library + ["folders", id])
    }
    public func scanFolder(id: String) async throws -> KeepsJob {
        try await request("POST", library + ["folders", id, "scan"])
    }
    public func refreshDirectoryMetadata(path: String) async throws -> KeepsJob {
        try await request("POST", library + ["directories", "refresh"], body: JSONEncoder().encode(["path": path]))
    }
    public func taskStatus() async throws -> KeepsTaskStatus {
        try await request("GET", library + ["task-status"])
    }
    public func jobs() async throws -> KeepsJobsResponse { try await request("GET", library + ["jobs"]) }
    public func retryJob(id: String) async throws -> KeepsJob {
        try await request("POST", library + ["jobs", id, "retry"])
    }
    public func prepareImport(_ manifest: KeepsImportManifest) async throws -> KeepsImportBatch {
        var request = try makeRequest("POST", library + ["imports"], body: JSONEncoder().encode(manifest))
        if manifest.deduplicate { request.timeoutInterval = 3600 }
        let (data, response) = try await session.data(for: request)
        return try JSONDecoder().decode(KeepsImportBatch.self, from: checkedData(data, response))
    }
    public func uploadImportFile(batchID: UUID, fileID: UUID, source: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        var request = try makeRequest("PUT", library + ["imports", batchID.uuidString, "files", fileID.uuidString])
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 3600
        let (data, response) = try await session.upload(for: request, fromFile: source, delegate: KeepsUploadProgress(progress))
        _ = try checkedData(data, response)
    }
    public func finishImport(id: UUID) async throws -> KeepsImportFinish {
        try await request("POST", library + ["imports", id.uuidString, "finish"], query: [URLQueryItem(name: "async", value: "true")])
    }
    public func importFinishStatus(id: UUID) async throws -> KeepsImportFinish {
        try await request("GET", library + ["imports", id.uuidString, "finish"])
    }
    public func heartbeatImport(id: UUID, workerID: String) async throws {
        _ = try await send("POST", library + ["imports", id.uuidString, "heartbeat"], body: JSONEncoder().encode(["workerID": workerID]))
    }
    public func claimImportMedia(id: UUID, workerID: String) async throws -> KeepsWorkerClaim {
        try await request("POST", library + ["worker", "claim"], body: JSONEncoder().encode(["workerID": workerID, "importID": id.uuidString]))
    }
    public func heartbeatWorker(taskID: String) async throws {
        _ = try await send("POST", library + ["worker", "tasks", taskID, "heartbeat"])
    }
    public func downloadWorkerSource(taskID: String, to destination: URL) async throws {
        var request = try makeRequest("GET", library + ["worker", "tasks", taskID, "source"])
        request.timeoutInterval = 3600
        let (temporary, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse else { throw KeepsAPIError.invalidResponse }
        if !(200..<300).contains(http.statusCode) {
            let handle = try FileHandle(forReadingFrom: temporary)
            defer { try? handle.close() }
            _ = try checkedData(handle.read(upToCount: 65_536) ?? Data(), response)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
    public func uploadWorkerMedia(taskID: String, role: String, source: URL) async throws {
        var request = try makeRequest("PUT", library + ["worker", "tasks", taskID, role])
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 3600
        let (data, response) = try await session.upload(for: request, fromFile: source)
        _ = try checkedData(data, response)
    }
    public func completeWorker(taskID: String) async throws {
        _ = try await send("POST", library + ["worker", "tasks", taskID, "complete"])
    }
    public func failWorker(taskID: String, error: String) async throws {
        _ = try await send("POST", library + ["worker", "tasks", taskID, "fail"], body: JSONEncoder().encode(["error": error]))
    }
    public func refreshPreview(assetID: UUID) async throws -> URL {
        try await refreshPreviewDescriptor(assetID: assetID).downloadURL
    }
    public func refreshPreviewDescriptor(assetID: UUID, role: KeepsMediaRole = .preview) async throws -> KeepsPreview {
        let response: KeepsPreview = try await request("GET", ["derivatives", assetID.uuidString], query: [URLQueryItem(name: "role", value: role.rawValue), URLQueryItem(name: "libraryID", value: configuration.libraryID)])
        return response
    }
    private struct Directories: Decodable { var directories: [KeepsDirectory] }
    private func request<T: Decodable>(_ method: String, _ segments: [String], query: [URLQueryItem] = [], body: Data? = nil) async throws -> T {
        try JSONDecoder().decode(T.self, from: await send(method, segments, query: query, body: body))
    }
    private func send(_ method: String, _ segments: [String], query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        let request = try makeRequest(method, segments, query: query, body: body)
        let (data, response) = try await session.data(for: request)
        return try checkedData(data, response)
    }
    private func makeRequest(_ method: String, _ segments: [String], query: [URLQueryItem] = [], body: Data? = nil) throws -> URLRequest {
        guard ["http", "https"].contains(configuration.baseURL.scheme?.lowercased() ?? ""),
              configuration.baseURL.host != nil, !configuration.libraryID.isEmpty,
              var url = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false) else { throw KeepsAPIError.invalidConfiguration }
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))
        let suffix = segments.map { $0.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "/")
        let prefix = url.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        url.percentEncodedPath = "/" + ([prefix, suffix].filter { !$0.isEmpty }.joined(separator: "/"))
        url.queryItems = query.isEmpty ? nil : query
        guard let endpoint = url.url else { throw KeepsAPIError.invalidConfiguration }
        var request = URLRequest(url: endpoint)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let credential = configuration.accessCredential, !credential.isEmpty { request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization") }
        return request
    }
    private func checkedData(_ data: Data, _ response: URLResponse) throws -> Data {
        guard let http = response as? HTTPURLResponse else { throw KeepsAPIError.invalidResponse }
        guard 200..<300 ~= http.statusCode else { throw KeepsAPIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "响应体无法解码") }
        return data
    }
}
