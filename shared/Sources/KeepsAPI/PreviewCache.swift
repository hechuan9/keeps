import Foundation
import CryptoKit
import ImageIO
import OSLog

public actor PreviewCache {
    public static let shared = PreviewCache(role: .preview)
    public static let thumbnails = PreviewCache(diskLimit: Int.max, role: .thumbnail)
    public static let browsing = PreviewCache(diskLimit: Int.max, role: .browse)
    public static let standards = PreviewCache(role: .standard)
    public static func cache(for role: KeepsMediaRole) -> PreviewCache {
        switch role { case .browse: browsing; case .thumbnail: thumbnails; case .standard: standards; case .preview: shared }
    }
    private let role: KeepsMediaRole
    private let migrateLegacy: Bool
    public static let diskLimit = 5 * 1024 * 1024 * 1024
    private let directory: URL
    private let limit: Int
    private let session: URLSession
    private let images = NSCache<NSString, CGImage>()
    private struct Entry { var size: Int; var accessed: Date }
    private var entries: [String: Entry] = [:]
    private var prepared = false
    private var indexed = false
    private var pending: [String: Task<(Data, String), Error>] = [:]

    public init(directory: URL? = nil,
                diskLimit: Int = PreviewCache.diskLimit, session: URLSession? = nil, role: KeepsMediaRole = .preview) {
        self.directory = directory ?? URL.cachesDirectory.appendingPathComponent("KeepsMediaV2/" + role.rawValue, isDirectory: true)
        self.role = role
        self.migrateLegacy = directory == nil
        self.limit = diskLimit
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil
            self.session = URLSession(configuration: config)
        }
        #if os(iOS)
        images.totalCostLimit = (role == .standard ? 32 : role == .thumbnail ? 24 : 8) * 1024 * 1024
        #else
        images.totalCostLimit = (role == .standard ? 128 : role == .thumbnail ? 96 : 32) * 1024 * 1024
        #endif
    }

    public nonisolated static func key(assetID: UUID, preview: KeepsPreview, configuration: KeepsConfiguration, role: KeepsMediaRole = .preview) -> String {
        // Length-delimited encoding prevents ambiguous namespace boundaries.
        let parts = [configuration.baseURL.absoluteString, configuration.libraryID, assetID.uuidString, role.rawValue, preview.version]
        let encoded = parts.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(encoded.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func image(assetID: UUID, preview: KeepsPreview, configuration: KeepsConfiguration, maxPixelSize: Int, allowDownload: Bool = true) async throws -> CGImage {
        try Task.checkCancellation()
        let key = Self.key(assetID: assetID, preview: preview, configuration: configuration, role: role)
        let pixels = max(1, maxPixelSize)
        let memoryKey = "\(key):\(pixels)" as NSString
        if let image = images.object(forKey: memoryKey) {
            if role != .thumbnail && role != .browse { try touch(key) }
            return image
        }
        let (data, actualKey) = try await bytes(key: key, assetID: assetID, preview: preview, configuration: configuration, allowDownload: allowDownload)
        try Task.checkCancellation()
        let image = try Self.decode(data, pixels: pixels)
        images.setObject(image, forKey: "\(actualKey):\(pixels)" as NSString, cost: image.bytesPerRow * image.height)
        return image
    }

    /// Cache writes validate images before atomic persistence; inventory only needs file metadata.
    public func cachedKeys() throws -> Set<String> {
        try prepare()
        var keys: Set<String> = []
        for file in try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
            let key = file.lastPathComponent
            guard key.count == 64, key.allSatisfy({ $0.isHexDigit }) else { continue }
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values.isRegularFile == true, (values.fileSize ?? 0) > 0 { keys.insert(key) }
        }
        return keys
    }

    public func containsCachedKey(_ key: String) throws -> Bool {
        let file = directory.appendingPathComponent(key)
        do {
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            return values.isRegularFile == true && (values.fileSize ?? 0) > 0
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return false
        }
    }

    public func cachedFileURL(forKey key: String) throws -> URL? {
        try Self.validateCacheKey(key)
        try prepare()
        let file = directory.appendingPathComponent(key)
        do {
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
                  Self.isImage(try Data(contentsOf: file)) else { return nil }
            return file
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
    }

    public func importCachedFile(from source: URL, key: String) throws {
        try Self.validateCacheKey(key)
        if try cachedFileURL(forKey: key) != nil { return }
        let data = try Data(contentsOf: source)
        try importCachedData(data, key: key)
    }

    func importCachedData(_ data: Data, key: String) throws {
        try Self.validateCacheKey(key)
        if try cachedFileURL(forKey: key) != nil { return }
        guard Self.isImage(data) else { throw URLError(.cannotDecodeContentData) }
        try store(data, key: key)
        guard try cachedFileURL(forKey: key) != nil else { throw CocoaError(.fileWriteOutOfSpace) }
    }

    private static func validateCacheKey(_ key: String) throws {
        guard key.utf8.count == 64, key.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
    }

    public var isDownloading: Bool { !pending.isEmpty }

    public func prefetch(assetID: UUID, preview: KeepsPreview, configuration: KeepsConfiguration, skipWhenBusy: Bool = true) async throws -> Bool {
        try Task.checkCancellation()
        try prepare()
        let free = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
        guard free > 2 * 1024 * 1024 * 1024 else { return false }
        guard !skipWhenBusy || pending.isEmpty else { return false }
        let key = Self.key(assetID: assetID, preview: preview, configuration: configuration, role: role)
        let (_, actualKey) = try await bytes(key: key, assetID: assetID, preview: preview, configuration: configuration)
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent(actualKey).path)
    }

    private func bytes(key: String, assetID: UUID, preview: KeepsPreview, configuration: KeepsConfiguration, allowDownload: Bool = true) async throws -> (Data, String) {
        try Task.checkCancellation()
        try prepare()
        let file = directory.appendingPathComponent(key)
        do {
            try Task.checkCancellation()
            let data = try Data(contentsOf: file)
            try Task.checkCancellation()
            guard Self.isImage(data) else {
                try FileManager.default.removeItem(at: file)
                entries[key] = nil
                guard allowDownload else { throw URLError(.fileDoesNotExist) }
                return try await download(key: key, assetID: assetID, preview: preview, configuration: configuration)
            }
            entries[key] = Entry(size: data.count, accessed: Date())
            if role != .thumbnail && role != .browse { try touch(key) }
            return (data, key)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            entries[key] = nil
        }
        guard allowDownload else { throw URLError(.fileDoesNotExist) }
        return try await download(key: key, assetID: assetID, preview: preview, configuration: configuration)
    }

    private func download(key: String, assetID: UUID, preview: KeepsPreview, configuration: KeepsConfiguration) async throws -> (Data, String) {
        try Task.checkCancellation()
        if let task = pending[key] { return try await task.value }
        let session = self.session
        let task = Task<(Data, String), Error> {
            var descriptor = preview
            var (data, response) = try await session.data(from: descriptor.downloadURL)
            if Self.isExpired(data: data, response: response) {
                descriptor = try await KeepsClient(configuration: configuration, session: session).refreshPreviewDescriptor(assetID: assetID, role: self.role)
                (data, response) = try await session.data(from: descriptor.downloadURL)
            }
            guard let http = response as? HTTPURLResponse else { throw KeepsAPIError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else {
                throw KeepsAPIError.http(http.statusCode, String(decoding: data, as: UTF8.self))
            }
            guard Self.isImage(data) else { throw URLError(.cannotDecodeContentData) }
            let actualKey = Self.key(assetID: assetID, preview: descriptor, configuration: configuration, role: self.role)
            try self.store(data, key: actualKey)
            return (data, actualKey)
        }
        pending[key] = task
        defer { pending[key] = nil }
        return try await task.value
    }

    static func isExpired(data: Data, response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse, http.statusCode == 403,
              let body = try? JSONDecoder().decode(Failure.self, from: data) else { return false }
        return ["preview_token_expired", "derivative_token_expired"].contains(body.detail.code)
    }
    private struct Failure: Decodable { var detail: Detail; struct Detail: Decodable { var code: String } }
    private static func isImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 0 && CGImageSourceGetStatus(source) == .statusComplete
    }
    static func decode(_ data: Data, pixels: Int) throws -> CGImage {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw URLError(.cannotDecodeContentData) }
        return image
    }

    private static let migrationLock = NSLock()
    static func migrateLegacyCache(in root: URL) throws {
        migrationLock.lock()
        defer { migrationLock.unlock() }
        let marker = root.appendingPathComponent("KeepsMediaV2/.legacy-removed")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        let legacy = root.appendingPathComponent("KeepsPreviews", isDirectory: true)
        if FileManager.default.fileExists(atPath: legacy.path) { try FileManager.default.removeItem(at: legacy) }
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: marker, options: .atomic)
    }

    private func prepare() throws {
        guard !prepared || !FileManager.default.fileExists(atPath: directory.path) else { return }
        if migrateLegacy {
            try Self.migrateLegacyCache(in: URL.cachesDirectory)
        }
        entries.removeAll()
        indexed = false
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        prepared = true
    }
    private func indexForEviction() throws {
        guard !indexed else { return }
        // Cache hits use their stable filename; only eviction needs the whole directory.
        entries.removeAll()
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]) {
            let name = file.lastPathComponent
            guard name.count == 64, name.allSatisfy({ $0.isHexDigit }) else { continue }
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            entries[name] = Entry(size: values.fileSize ?? 0, accessed: values.contentModificationDate ?? .distantPast)
        }
        indexed = true
    }
    private func touch(_ key: String) throws {
        guard var entry = entries[key] else { return }
        entry.accessed = Date()
        do { try FileManager.default.setAttributes([.modificationDate: entry.accessed], ofItemAtPath: directory.appendingPathComponent(key).path) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            entries[key] = nil
            return
        }
        entries[key] = entry
    }
    func store(_ data: Data, key: String, write: @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) throws {
        try prepare()
        guard data.count <= limit else { return }
        try trim()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do { try write(data, directory.appendingPathComponent(key)) }
        catch let error as CocoaError where error.code == .fileWriteOutOfSpace {
            // Disk persistence is optional; a full device must still display downloaded previews.
            Logger(subsystem: "local.keeps", category: "preview-cache").error("Preview cache write failed: \(String(reflecting: error), privacy: .public)")
            return
        }
        entries[key] = Entry(size: data.count, accessed: Date())
        try trim()
    }
    private func trim() throws {
        let available = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        let lowSpace = available.map { $0 < 1024 * 1024 * 1024 } ?? false
        guard limit != Int.max || lowSpace else { return }
        try indexForEviction()
        var total = entries.values.reduce(0) { $0 + $1.size }
        guard total > limit || lowSpace else { return }
        let target = lowSpace ? max(0, total - 256 * 1024 * 1024) : limit / 5 * 4
        for (key, entry) in entries.sorted(by: { $0.value.accessed < $1.value.accessed }) {
            guard total > target else { break }
            do { try FileManager.default.removeItem(at: directory.appendingPathComponent(key)) }
            catch let error as CocoaError where error.code == .fileNoSuchFile { }
            entries[key] = nil
            total -= entry.size
        }
    }
}
