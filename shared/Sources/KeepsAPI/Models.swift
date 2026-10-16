import Foundation

public struct KeepsConfiguration: Equatable, Sendable {
    public var baseURL: URL
    public var libraryID: String
    public var accessCredential: String?
    public init(baseURL: URL, libraryID: String, accessCredential: String? = nil) {
        self.baseURL = baseURL
        self.libraryID = libraryID
        self.accessCredential = accessCredential
    }
}

public enum KeepsMediaRole: String, Sendable { case thumbnail, browse, standard, preview }

public struct KeepsPreview: Codable, Equatable, Sendable {
    public var downloadURL: URL
    public var width: Int
    public var height: Int
    public var version: String
}

public struct KeepsVideoPlayback: Decodable, Sendable {
    public var playbackURL: URL
    public var expiresAt: TimeInterval
}

public struct KeepsVideoTrimRequest: Codable, Sendable {
    public var id: UUID
    public var contentHash: String
    public var startSeconds: Double
    public var endSeconds: Double

    public init(id: UUID = UUID(), contentHash: String, startSeconds: Double, endSeconds: Double) {
        self.id = id
        self.contentHash = contentHash
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }
}

public struct KeepsVideoTrim: Decodable, Sendable {
    public var id: UUID
    public var assetID: UUID
    public var contentHash: String
    public var startSeconds: Double
    public var endSeconds: Double
    public var status: String
    public var error: String?
    public var newAssetID: UUID?
    public var outputPath: String?
}

public struct KeepsAsset: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var captureTime: String?
    public var cameraMake: String
    public var cameraModel: String
    public var lensModel: String
    public var originalFilename: String
    public var contentFingerprint: String
    public var metadataFingerprint: String
    public var rating: Int
    public var flagState: String
    public var colorLabel: String?
    public var tags: [String]
    public var createdAt: String
    public var updatedAt: String
    public var trashed: Bool
    public var preview: KeepsPreview?
    public var browseThumbnail: KeepsPreview? = nil
    public var thumbnail: KeepsPreview? = nil
    public var standard: KeepsPreview? = nil
    public var negativeContentHash: String? = nil
    public var paths: [String]? = nil
    public var gridPreview: KeepsPreview? { thumbnail ?? preview }
    public var isVideo: Bool { ["mov", "mp4", "m4v", "avi", "mkv", "mts", "m2ts"].contains(URL(fileURLWithPath: originalFilename).pathExtension.lowercased()) }
}

public struct KeepsAssetPage: Codable, Sendable {
    public var items: [KeepsAsset]
    public var total: Int
    public var nextCursor: String?
    public var revision: Int64
    public var isUpdating: Bool

    public init(items: [KeepsAsset], total: Int, nextCursor: String?, revision: Int64, isUpdating: Bool) {
        self.items = items
        self.total = total
        self.nextCursor = nextCursor
        self.revision = revision
        self.isUpdating = isUpdating
    }

    public func isCurrent(at current: KeepsCatalogRevision) -> Bool {
        !isUpdating && !current.isUpdating && revision == current.revision
    }
}

public struct KeepsCatalogRevision: Decodable, Equatable, Sendable {
    public var revision: Int64
    public var isUpdating: Bool
    public var path: String?
    public var children: [KeepsDirectoryRevision]?

    public init(revision: Int64, isUpdating: Bool, path: String? = nil, children: [KeepsDirectoryRevision]? = nil) {
        self.revision = revision
        self.isUpdating = isUpdating
        self.path = path
        self.children = children
    }
}

public struct KeepsDirectoryRevision: Decodable, Equatable, Sendable {
    public var path: String
    public var revision: Int64
    public var isUpdating: Bool
}

public struct KeepsHiddenDirectories: Decodable, Equatable, Sendable {
    public var paths: [String]
}

public struct KeepsCounts: Decodable, Equatable, Sendable {
    public var all: Int
    public var trashed: Int
    public var picked: Int
}

public struct KeepsDirectory: Decodable, Identifiable, Equatable, Sendable {
    public var path: String
    public var count: Int
    public var id: String { path }
}

public struct KeepsNavigationDirectory: Codable, Identifiable, Equatable, Sendable {
    public var path: String
    public var name: String
    public var directPhotoCount: Int?
    public var photoCount: Int
    public var hasChildren: Bool
    public var id: String { path }
    public var photoCountLabel: String {
        if directPhotoCount == photoCount { return String(photoCount) }
        return "\(photoCount)（\(directPhotoCount.map(String.init) ?? "—")）"
    }

    public init(path: String, name: String, photoCount: Int, hasChildren: Bool, directPhotoCount: Int? = nil) {
        self.path = path
        self.name = name
        self.directPhotoCount = directPhotoCount
        self.photoCount = photoCount
        self.hasChildren = hasChildren
    }
}

public struct KeepsDirectoryTrashTask: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var path: String
    public var status: String
    public var phase: String
    public var error: String?
    public var createdAt: Double
    public var updatedAt: Double
    public var finishedAt: Double?
    public var isTerminal: Bool { status == "completed" || status == "failed" }

    public init(id: UUID, path: String, status: String, phase: String, error: String? = nil, createdAt: Double, updatedAt: Double, finishedAt: Double? = nil) {
        self.id = id
        self.path = path
        self.status = status
        self.phase = phase
        self.error = error
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.finishedAt = finishedAt
    }
}

public struct KeepsNavigation: Codable, Sendable {
    public var path: String?
    public var directories: [KeepsNavigationDirectory]
    public init(path: String?, directories: [KeepsNavigationDirectory]) {
        self.path = path
        self.directories = directories
    }
}

public struct KeepsFolder: Decodable, Identifiable, Equatable, Sendable {
    public var id: String
    public var libraryID: String
    public var path: String
    public var active: Bool
}

public struct KeepsFoldersResponse: Decodable, Sendable {
    public var rootPath: String
    public var folders: [KeepsFolder]
}

public struct KeepsJob: Decodable, Identifiable, Equatable, Sendable {
    public var id: String
    public var folderID: String
    public var libraryID: String
    public var path: String
    public var status: String
    public var error: String?
    public var processed: Int?
    public var skipped: Int?
    public var failed: Int?
    public var currentPath: String?
    public var startedAt: Int64?
    public var finishedAt: Int64?
}

public struct KeepsJobsResponse: Decodable, Sendable {
    public var jobs: [KeepsJob]
}

public struct KeepsTaskStatus: Decodable, Equatable, Sendable {
    public var automatic: KeepsAutomaticTaskStatus
    public var longTask: KeepsLongTaskStatus
}

public struct KeepsAutomaticTaskStatus: Decodable, Equatable, Sendable {
    public var status: String
    public var currentPhoto: String?
    public var remainingPhotos: Int
    public var failedPhotos: Int
    public var error: String?
}

public struct KeepsLongTaskStatus: Decodable, Equatable, Sendable {
    public var jobID: String?
    public var phase: String?
    public var status: String
    public var kind: String?
    public var error: String?
    public var path: String?
    public var currentPhoto: String?
    public var processed: Int?
    public var failed: Int?
}

public struct KeepsAssetQuery: Codable, Hashable, Sendable {
    public var q = ""
    public var minRating = 0
    public var flagState: String?
    public var colorLabel: String?
    public var tag: String?
    public var trashed = false
    public var sort = "capture_desc"
    public var folderID: String?
    public var directory: String?
    public var recursive = true
    public var showHidden = false
    public var cursor: String?
    public var limit = 100
    public init() {}

    var queryItems: [URLQueryItem] {
        var values = ["q": q, "minRating": String(minRating), "trashed": String(trashed), "sort": sort, "recursive": String(recursive), "showHidden": String(showHidden), "limit": String(limit)]
        for (key, value) in [("flagState", flagState), ("colorLabel", colorLabel), ("tag", tag), ("folderID", folderID), ("directory", directory), ("cursor", cursor)] {
            if let value { values[key] = value }
        }
        return values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
    }
}

public struct KeepsAssetPatch: Encodable, Sendable {
    public var rating: Int?
    public var flagState: String?
    public var colorLabel: String?
    public var clearColorLabel: Bool
    public var tags: [String]?
    public init(rating: Int? = nil, flagState: String? = nil, colorLabel: String? = nil, clearColorLabel: Bool = false, tags: [String]? = nil) {
        self.rating = rating; self.flagState = flagState; self.colorLabel = colorLabel
        self.clearColorLabel = clearColorLabel; self.tags = tags
    }
    enum CodingKeys: String, CodingKey { case rating, flagState, colorLabel, tags }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(rating, forKey: .rating)
        try values.encodeIfPresent(flagState, forKey: .flagState)
        if clearColorLabel { try values.encodeNil(forKey: .colorLabel) }
        else { try values.encodeIfPresent(colorLabel, forKey: .colorLabel) }
        try values.encodeIfPresent(tags, forKey: .tags)
    }
}

public struct KeepsAssetVersions: Decodable, Sendable {
    public var items: [KeepsAssetVersion]
    public var negativeContentHash: String?
    public var deprecatedFiles: [DeprecatedFile]?

    public struct DeprecatedFile: Decodable, Sendable {
        public var path: String
        public var retainedPath: String
        public var basis: String
        public var reason: String
    }
}

public struct KeepsAssetVersion: Decodable, Identifiable, Sendable {
    public var versionID: String? = nil
    public var sourceVersionID: String? = nil
    public var evidence: Evidence? = nil
    public struct Evidence: Decodable, Sendable {
        public var generatedFrom: String?
    }
    public var contentHash: String
    public var width: Int
    public var height: Int
    public var priority: Int
    public var isDefault: Bool
    public var userSelected: Bool
    public var isNegative: Bool? = nil
    public var available: Bool
    public var paths: [Location]
    public var id: String { versionID ?? contentHash }
    public var filename: String { paths.first.map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? contentHash }
    public var kind: String {
        switch priority {
        case 3: "编辑成片"
        case 2: "成片"
        default: "RAW"
        }
    }
    public struct Location: Decodable, Sendable {
        public var path: String
        public var available: Bool
    }
}

public struct KeepsDirectoryMoveTask: Decodable, Sendable {
    public var id: UUID
    public var path: String
    public var parentPath: String
    public var destination: String
    public var status: String
    public var phase: String
    public var error: String?
}

public struct KeepsPhotoMoveTask: Decodable, Sendable {
    public var id: UUID
    public var assetIDs: [UUID]
    public var sourcePath: String?
    public var parentPath: String
    public var status: String
    public var phase: String
    public var error: String?
}

public struct KeepsRejectedTrashTask: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var count: Int
    public var status: String
    public var phase: String
    public var completedFiles: Int
    public var totalFiles: Int
    public var error: String?
    public var createdAt: Double
    public var updatedAt: Double
    public var finishedAt: Double?
}

public struct KeepsTrashSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var retentionDays: Int
    public init(enabled: Bool = true, retentionDays: Int = 30) {
        self.enabled = enabled
        self.retentionDays = retentionDays
    }
}
