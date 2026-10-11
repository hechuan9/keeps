import Foundation

public struct KeepsEditRecipe: Codable, Equatable, Sendable {
    public var engine: String
    public var engineVersion: String
    public var recipeJSON: String
    public var metadata: String?
    public var xmp: String
    public init(engine: String = "darktable", engineVersion: String = "5.6.2", recipeJSON: String, xmp: String, metadata: String? = nil) {
        self.metadata = metadata
        self.engine = engine; self.engineVersion = engineVersion; self.recipeJSON = recipeJSON; self.xmp = xmp
    }
}

public struct KeepsEditState: Codable, Equatable, Sendable {
    public var decisionMetadata: String?
    public var negativeContentHash: String?
    public var revision: Int64
    public var hasEdit: Bool
    public var exposureEV: Double?
    public var recipe: KeepsEditRecipe?
    public var sourceFilename: String?
    public var sourceAvailable: Bool
    public var lastRequestID: String?
    public var sourceFileHash: String?
    public var sourceSizeBytes: Int64?

    public init(negativeContentHash: String?, revision: Int64, hasEdit: Bool, exposureEV: Double? = nil,
                sourceFilename: String? = nil, sourceAvailable: Bool, lastRequestID: String? = nil,
                sourceFileHash: String? = nil, sourceSizeBytes: Int64? = nil, recipe: KeepsEditRecipe? = nil, decisionMetadata: String? = nil) {
        self.decisionMetadata = decisionMetadata
        self.negativeContentHash = negativeContentHash
        self.revision = revision
        self.hasEdit = hasEdit
        self.recipe = recipe
        self.exposureEV = exposureEV
        self.sourceFilename = sourceFilename
        self.sourceAvailable = sourceAvailable
        self.lastRequestID = lastRequestID
        self.sourceFileHash = sourceFileHash
        self.sourceSizeBytes = sourceSizeBytes
    }
}

public struct KeepsEditUploadSession: Codable, Sendable {
    public var requestID: String
    public var objects: [KeepsEditUploadTarget]
    public init(requestID: String, objects: [KeepsEditUploadTarget]) {
        self.requestID = requestID; self.objects = objects
    }
}

public struct KeepsEditObjectRef: Codable, Equatable, Sendable {
    public var bucket: String
    public var key: String
    public init(bucket: String, key: String) { self.bucket = bucket; self.key = key }
}

public struct KeepsEditUploadTarget: Codable, Sendable {
    public var role: String
    public var objectRef: KeepsEditObjectRef
    public var uploadURL: URL
    public init(role: String, objectRef: KeepsEditObjectRef, uploadURL: URL) {
        self.role = role; self.objectRef = objectRef; self.uploadURL = uploadURL
    }
}

public struct KeepsEditOutput: Codable, Sendable {
    public var role: String
    public var objectRef: KeepsEditObjectRef
    public var contentHash: String
    public var width: Int
    public var height: Int
    public var sizeBytes: Int64
    public init(role: String, objectRef: KeepsEditObjectRef, contentHash: String, width: Int, height: Int, sizeBytes: Int64) {
        self.role = role; self.objectRef = objectRef; self.contentHash = contentHash
        self.width = width; self.height = height; self.sizeBytes = sizeBytes
    }
}

public struct KeepsEditCommit: Codable, Sendable {
    public var requestID: String
    public var expectedRevision: Int64
    public var negativeContentHash: String
    public var exposureEV: Double?
    public var recipe: KeepsEditRecipe?
    public var algorithmVersion: String
    public var rendererVersion: String
    public var outputs: [KeepsEditOutput]
    public init(requestID: String, expectedRevision: Int64, negativeContentHash: String, exposureEV: Double? = nil,
                algorithmVersion: String, rendererVersion: String, outputs: [KeepsEditOutput], recipe: KeepsEditRecipe? = nil) {
        self.requestID = requestID; self.expectedRevision = expectedRevision
        self.negativeContentHash = negativeContentHash; self.exposureEV = exposureEV
        self.recipe = recipe
        self.algorithmVersion = algorithmVersion; self.rendererVersion = rendererVersion; self.outputs = outputs
    }
}
