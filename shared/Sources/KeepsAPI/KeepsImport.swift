import Foundation

public struct KeepsImportManifest: Codable, Sendable {
    public var id: UUID
    public var targetPath: String
    public var files: [KeepsImportFile]
    public var deduplicate: Bool
    public var workerID: String?
    public var preserveStructure: Bool
    public init(id: UUID, targetPath: String, files: [KeepsImportFile], deduplicate: Bool = false, preserveStructure: Bool = false, workerID: String? = nil) {
        self.workerID = workerID
        self.id = id
        self.targetPath = targetPath
        self.files = files
        self.deduplicate = deduplicate
        self.preserveStructure = preserveStructure
    }
}

public struct KeepsImportFile: Codable, Sendable {
    public var id: UUID
    public var relativePath: String
    public var size: Int64
    public var sha256: String?
    public init(id: UUID, relativePath: String, size: Int64, sha256: String? = nil) {
        self.id = id
        self.relativePath = relativePath
        self.size = size
        self.sha256 = sha256
    }
}

public struct KeepsImportBatch: Decodable, Sendable {
    public var id: UUID
    public var targetPath: String
    public var files: [File]
    public var finished: Bool

    public struct File: Decodable, Identifiable, Sendable {
        public var id: UUID
        public var relativePath: String
        public var fileName: String
        public var size: Int64
        public var sha256: String?
        public var uploaded: Bool
        public var skipped: Bool?
    }
}

public struct KeepsImportFinish: Decodable, Sendable {
    public var id: UUID
    public var status: String
    public var publicationComplete: Bool?
    public var indexTotal: Int?
    public var indexedFiles: Int?
    public var thumbnailTotal: Int?
    public var thumbnailCompleted: Int?
    public var completedFiles: Int
    public var totalFiles: Int
    public var job: KeepsJob?
    public var error: String?
}

final class KeepsUploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    let progress: @Sendable (Int64) -> Void
    init(_ progress: @escaping @Sendable (Int64) -> Void) { self.progress = progress }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        progress(totalBytesSent)
    }
}

public struct KeepsWorkerClaim: Decodable, Sendable {
    public var task: KeepsWorkerTask?
    public var enabled: Bool?
}
public struct KeepsWorkerTask: Codable, Sendable {
    public var taskID: String
    public var inputHash: String
    public var filename: String
    public var generateBrowse: Bool?
    public var generateStandard: Bool
    public var thumbnailEdge: Int
    public var thumbnailQuality: Int
}
