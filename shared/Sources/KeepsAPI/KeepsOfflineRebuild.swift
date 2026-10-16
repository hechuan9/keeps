import Foundation
import CryptoKit
import OSLog

public struct KeepsOfflineManifest: Codable, Sendable {
    public var formatVersion: Int
    public var libraryID: String
    public var revision: Int64
    public var mode: String? = nil
    public var generation: String? = nil
    public var fromRevision: Int64? = nil
    public var assetCount: Int
    public var thumbnailCount: Int
    public var missingThumbnailCount: Int
    public var browseThumbnailCount: Int? = nil
    public var missingBrowseThumbnailCount: Int? = nil
}

public actor KeepsOfflineRebuild {
    public static let shared = KeepsOfflineRebuild()
    public struct Progress: Sendable {
        public enum Phase: Sendable { case building, downloading, verifying, importing }
        public var step: String = ""
        public var phase: Phase
        public var completed: Int64
        public var total: Int64
        public var message: String
    }
    private struct Job: Codable {
        var id: UUID
        var state: String
        var phase: String
        var completed: Int64
        var total: Int64
        var revision: Int64?
        var byteCount: Int64?
        var sha256: String?
        var error: String?
    }
    private let session: URLSession
    private let cache: PreviewCache
    private let browsingCache: PreviewCache
    public init(session: URLSession = KeepsClient.apiSession, cache: PreviewCache = .thumbnails, browsingCache: PreviewCache = .browsing) {
        self.session = session; self.cache = cache; self.browsingCache = browsingCache
    }
    public func run(configuration: KeepsConfiguration, databaseRoot: URL? = nil, includeThumbnails: Bool = true, forceRebuild: Bool = false,
                    progress: @escaping @Sendable (Progress) async -> Void = { _ in }) async throws -> KeepsOfflineManifest {
        let identity = Data((configuration.baseURL.absoluteString + "\n" + configuration.libraryID + "\n" + (configuration.accessCredential ?? "")).utf8)
        let key = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        let base = databaseRoot ?? URL.applicationSupportDirectory.appendingPathComponent("Keeps")
        let root = base.appendingPathComponent("OfflineRebuild/" + key)
        for include in [true, false] {
            let legacyIdentity = Data((configuration.baseURL.absoluteString + "\n" + configuration.libraryID + "\n" + String(include)).utf8)
            let legacyKey = SHA256.hash(data: legacyIdentity).map { String(format: "%02x", $0) }.joined()
            let legacy = base.appendingPathComponent("OfflineRebuild/" + legacyKey)
            if legacy != root, FileManager.default.fileExists(atPath: legacy.path) { try FileManager.default.removeItem(at: legacy) }
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: databaseRoot)
        let replica = try database.replicaID()
        let generation = try database.generation
        let since = try forceRebuild || generation == nil || database.syncCheckpoint != nil ? nil : database.revision
        let parameters = Parameters(includeThumbnails: includeThumbnails, replicaID: replica,
                                    generation: since == nil ? nil : generation, sinceRevision: since)
        let parametersFile = root.appendingPathComponent("request.json")
        if FileManager.default.fileExists(atPath: parametersFile.path),
           try JSONDecoder().decode(Parameters.self, from: Data(contentsOf: parametersFile)) != parameters {
            try FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        try JSONEncoder().encode(parameters).write(to: parametersFile, options: .atomic)
        let jobFile = root.appendingPathComponent("job.json")
        let archive = root.appendingPathComponent("bundle.tar")
        var job: Job
        if FileManager.default.fileExists(atPath: jobFile.path) {
            job = try JSONDecoder().decode(Job.self, from: Data(contentsOf: jobFile))
        } else {
            job = try await fetch(configuration, method: "POST", suffix: [], parameters: parameters)
            try JSONEncoder().encode(job).write(to: jobFile, options: .atomic)
        }
        while job.state != "ready" {
            try Task.checkCancellation()
            guard job.state != "failed" else { try FileManager.default.removeItem(at: root); throw failure(job.error ?? "NAS 离线包生成失败") }
            await progress(Progress(step: job.phase, phase: .building, completed: job.completed, total: max(1, job.total), message: job.phase))
            try await Task.sleep(for: .seconds(1))
            do { job = try await fetch(configuration, method: "GET", suffix: [job.id.uuidString]) }
            catch KeepsAPIError.http(let status, let body) {
                if status == 404 || status == 410 { try FileManager.default.removeItem(at: root) }
                throw KeepsAPIError.http(status, body)
            }
        }
        guard let size = job.byteCount, size > 0, let digest = job.sha256, digest.count == 64 else { throw failure("离线包缺少长度或校验值") }
        let existing = (try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard existing <= size else { throw failure("离线包断点长度错误") }
        if existing < size {
            var request = try request(configuration, method: "GET", suffix: [job.id.uuidString, "download"])
            if existing > 0 { request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }
            request.setValue("\"\(digest)\"", forHTTPHeaderField: "If-Match")
            let download = OfflineFileDownload(file: archive, offset: existing, total: size, digest: digest, progress: progress)
            do { try await download.run(request, configuration: session.configuration) }
            catch KeepsAPIError.http(let status, let body) {
                if status == 404 || status == 410 { try FileManager.default.removeItem(at: root) }
                throw KeepsAPIError.http(status, body)
            }
        }
        let input = try FileHandle(forReadingFrom: archive)
        defer { try? input.close() }
        var hash = SHA256()
        var verified: Int64 = 0
        var lastVerification = Date.distantPast
        while let data = try autoreleasepool(invoking: { try input.read(upToCount: 1024 * 1024) }), !data.isEmpty {
            try Task.checkCancellation(); hash.update(data: data); verified += Int64(data.count)
            if Date().timeIntervalSince(lastVerification) >= 1 || verified == size {
                lastVerification = Date()
                await progress(Progress(phase: .verifying, completed: verified, total: size, message: "校验离线包"))
            }
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == digest.lowercased() else {
            try FileManager.default.removeItem(at: archive)
            throw failure("离线包 SHA256 校验失败，请重试传输")
        }
        let manifest = try await unpack(archive, root: root, configuration: configuration, databaseRoot: databaseRoot, progress: progress)
        try FileManager.default.removeItem(at: root)
        try await acknowledge(configuration: configuration, databaseRoot: databaseRoot)
        return manifest
    }
    private struct Parameters: Codable, Equatable {
        var includeThumbnails: Bool
        var replicaID: String
        var generation: String?
        var sinceRevision: Int64?
    }

    public func acknowledge(configuration: KeepsConfiguration, databaseRoot: URL? = nil) async throws {
        let database = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: databaseRoot)
        guard let generation = try database.generation, let revision = try database.revision else { return }
        var url = configuration.baseURL
        for part in ["libraries", configuration.libraryID, "replicas", try database.replicaID(), "ack"] { url.appendPathComponent(part) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["generation": generation, "revision": revision])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = configuration.accessCredential { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw KeepsAPIError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw KeepsAPIError.http(response.statusCode, String(decoding: data, as: UTF8.self)) }
    }

    private func request(_ configuration: KeepsConfiguration, method: String, suffix: [String], parameters: Parameters? = nil) throws -> URLRequest {
        var url = configuration.baseURL
        for part in ["libraries", configuration.libraryID, "offline-rebuild"] + suffix { url.appendPathComponent(part) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if method == "POST" { request.httpBody = try JSONEncoder().encode(parameters); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token = configuration.accessCredential { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }
    private func fetch(_ configuration: KeepsConfiguration, method: String, suffix: [String], parameters: Parameters? = nil) async throws -> Job {
        let (data, response) = try await session.data(for: request(configuration, method: method, suffix: suffix, parameters: parameters))
        guard let response = response as? HTTPURLResponse else { throw KeepsAPIError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw KeepsAPIError.http(response.statusCode, String(decoding: data, as: UTF8.self)) }
        return try JSONDecoder().decode(Job.self, from: data)
    }
    private func failure(_ message: String) -> KeepsLibraryDatabase.DatabaseError { .init(message: message) }

    func unpack(_ archive: URL, root: URL, configuration: KeepsConfiguration, databaseRoot: URL?,
                        progress: @escaping @Sendable (Progress) async -> Void) async throws -> KeepsOfflineManifest {
        let reader = try OfflineTarReader(archive)
        guard let first = try reader.next(), first.name == "manifest.json", first.size <= 1_048_576 else { throw failure("离线包缺少 manifest") }
        let manifest = try JSONDecoder().decode(KeepsOfflineManifest.self, from: reader.data(first.size))
        guard (1...2).contains(manifest.formatVersion), manifest.libraryID == configuration.libraryID,
              manifest.assetCount >= 0, manifest.thumbnailCount >= 0, manifest.missingThumbnailCount >= 0,
              manifest.thumbnailCount + manifest.missingThumbnailCount == manifest.assetCount else { throw failure("离线包清单不匹配") }
        if manifest.formatVersion == 2 {
            guard let generation = manifest.generation, UUID(uuidString: generation) != nil,
                  manifest.mode == "snapshot" || manifest.mode == "delta",
                  (manifest.mode == "delta") == (manifest.fromRevision != nil),
                  manifest.mode != "delta" || (manifest.thumbnailCount == 0 && (manifest.browseThumbnailCount ?? 0) == 0) else {
                throw failure("离线包同步版本不完整")
            }
        }
        if let count = manifest.browseThumbnailCount, let missing = manifest.missingBrowseThumbnailCount {
            guard count >= 0, missing >= 0, count <= manifest.assetCount,
                  missing == manifest.assetCount - count else { throw failure("离线包快速浏览图清单不匹配") }
        } else if manifest.browseThumbnailCount != nil || manifest.missingBrowseThumbnailCount != nil {
            throw failure("离线包快速浏览图清单不完整")
        }
        guard let second = try reader.next(), second.name == "catalog.sqlite" else { throw failure("离线包缺少数据库") }
        let catalog = root.appendingPathComponent("staged.sqlite")
        let archiveBytes = Int64(try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        try await reader.copy(second.size, to: catalog) { bytes in
            await progress(Progress(phase: .importing, completed: bytes, total: archiveBytes + 1, message: "导入离线数据库"))
        }
        try Task.checkCancellation()
        let snapshot = try KeepsLibraryDatabase.SnapshotReader(url: catalog)
        var count = 0
        var browseCount = 0
        var last = Date.distantPast
        while let entry = try reader.next() {
            try Task.checkCancellation()
            let name = entry.name
            let browsing = name.hasPrefix("browse-thumbnails/")
            let directory = browsing ? "browse-thumbnails/" : "thumbnails/"
            guard name.hasPrefix(directory), name.hasSuffix(".image"), entry.size <= 64 * 1024 * 1024,
                  let id = UUID(uuidString: String(name.dropFirst(directory.count).dropLast(6))),
                  name == "\(directory)\(id.uuidString).image",
                  let asset = try snapshot.asset(id: id),
                  let preview = browsing ? asset.browseThumbnail : asset.thumbnail else { throw failure("离线包缩略图与数据库不匹配") }
            let targetCache = browsing ? browsingCache : cache
            // Each bounded image goes directly from the archive to its final cache file.
            let image = try reader.data(entry.size)
            do {
                try await targetCache.importCachedData(image, key: PreviewCache.key(assetID: id, preview: preview, configuration: configuration, role: browsing ? .browse : .thumbnail))
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                Logger(subsystem: "local.keeps", category: "offline-rebuild").error("Optional thumbnail \(id) import failed: \(String(reflecting: error), privacy: .public)")
            }
            if browsing { browseCount += 1 } else { count += 1 }
            if Date().timeIntervalSince(last) >= 1 {
                last = Date()
                await progress(Progress(phase: .importing, completed: try reader.position, total: archiveBytes + 1, message: "导入离线图库"))
            }
        }
        snapshot.close()
        guard count == manifest.thumbnailCount, browseCount == (manifest.browseThumbnailCount ?? 0) else { throw failure("离线包缩略图数量错误") }
        try Task.checkCancellation()
        let database = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: databaseRoot)
        if manifest.mode == "delta", let generation = manifest.generation, let fromRevision = manifest.fromRevision {
            try database.applyDelta(from: catalog, generation: generation, fromRevision: fromRevision,
                                    revision: manifest.revision, assetCount: manifest.assetCount)
        } else {
            let stagedGeneration = try { try KeepsLibraryDatabase(snapshotURL: catalog).generation }()
            guard manifest.formatVersion == 1 || stagedGeneration == manifest.generation else { throw failure("离线包图库世代不匹配") }
            try database.replaceSnapshot(from: catalog, revision: manifest.revision, assetCount: manifest.assetCount, consumingSource: true)
        }
        await progress(Progress(phase: .importing, completed: archiveBytes + 1, total: archiveBytes + 1, message: "离线图库已准备好"))
        return manifest
    }
}

private final class OfflineFileDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let file: URL
    private let offset: Int64
    private let total: Int64
    private let digest: String
    private let progress: @Sendable (KeepsOfflineRebuild.Progress) async -> Void
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false
    private var continuation: CheckedContinuation<Void, Error>?
    private var handle: FileHandle?
    private var received: Int64
    private var last = Date.distantPast
    private var failure: Error?
    private var progressTask: Task<Void, Never>?
    init(file: URL, offset: Int64, total: Int64, digest: String, progress: @escaping @Sendable (KeepsOfflineRebuild.Progress) async -> Void) {
        self.file = file; self.offset = offset; self.total = total; self.digest = digest; self.progress = progress; received = offset
    }
    func run(_ request: URLRequest, configuration: URLSessionConfiguration) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock(); defer { lock.unlock() }
                self.continuation = continuation
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.dataTask(with: request)
                self.task = task
                if cancelled { task.cancel() }
                task.resume()
            }
        } onCancel: {
            self.lock.lock(); self.cancelled = true; self.task?.cancel(); self.lock.unlock()
        }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let response = response as? HTTPURLResponse else { throw KeepsAPIError.invalidResponse }
            guard response.statusCode == 200 || response.statusCode == 206 else {
                throw KeepsAPIError.http(response.statusCode, "离线包下载失败")
            }
            guard response.statusCode == (offset == 0 ? 200 : 206),
                  response.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) == digest,
                  response.expectedContentLength == total - offset else { throw URLError(.badServerResponse) }
            if offset > 0 {
                guard response.value(forHTTPHeaderField: "Content-Range") == "bytes \(offset)-\(total - 1)/\(total)" else { throw URLError(.badServerResponse) }
            } else { try Data().write(to: file) }
            handle = try FileHandle(forWritingTo: file)
            try handle?.seekToEnd()
            completionHandler(.allow)
        } catch { failure = error; completionHandler(.cancel) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            guard received + Int64(data.count) <= total else { throw URLError(.dataLengthExceedsMaximum) }
            try handle?.write(contentsOf: data)
            received += Int64(data.count)
            if Date().timeIntervalSince(last) >= 1 || received == total {
                last = Date()
                let value = KeepsOfflineRebuild.Progress(phase: .downloading, completed: received, total: total, message: "下载离线包")
                let previous = progressTask
                progressTask = Task { await previous?.value; await progress(value) }
            }
        } catch { failure = error; dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        do { try handle?.synchronize(); try handle?.close() } catch { failure = failure ?? error }
        session.finishTasksAndInvalidate()
        let completion = continuation
        continuation = nil
        let completionError = failure ?? error ?? (received != total ? URLError(.networkConnectionLost) : nil)
        let pendingProgress = progressTask
        Task {
            await pendingProgress?.value
            if let completionError { completion?.resume(throwing: completionError) }
            else { completion?.resume() }
        }
    }
}

private final class OfflineTarReader {
    struct Entry { let name: String; let size: Int }
    private let handle: FileHandle
    private var padding = 0
    private var names: Set<String> = []
    init(_ url: URL) throws { handle = try FileHandle(forReadingFrom: url) }
    deinit { try? handle.close() }
    private func invalid() -> Error { KeepsLibraryDatabase.DatabaseError(message: "离线包 TAR 格式损坏或不受支持") }
    func data(_ count: Int) throws -> Data {
        // Async workers may retain Foundation's autoreleased read buffers for the entire archive.
        try autoreleasepool {
            guard let result = try handle.read(upToCount: count), result.count == count else { throw invalid() }
            return result
        }
    }
    func next() throws -> Entry? {
        if padding > 0 { _ = try data(padding) }; padding = 0
        let header = try data(512)
        if header.allSatisfy({ $0 == 0 }) {
            guard try data(512).allSatisfy({ $0 == 0 }) else { throw invalid() }
            while let tail = try handle.read(upToCount: 4096), !tail.isEmpty { guard tail.allSatisfy({ $0 == 0 }) else { throw invalid() } }
            return nil
        }
        func text(_ range: Range<Int>) -> String { String(decoding: header[range].prefix(while: { $0 != 0 }), as: UTF8.self) }
        let name = text(0..<100)
        let number = text(124..<136).trimmingCharacters(in: .whitespacesAndNewlines)
        let checksum = text(148..<156).trimmingCharacters(in: .whitespacesAndNewlines)
        var sum = 0
        for (index, byte) in header.enumerated() { sum += (148..<156).contains(index) ? 32 : Int(byte) }
        guard text(257..<263) == "ustar", text(345..<500).isEmpty,
              header[156] == 0 || header[156] == 48,
              Int(checksum, radix: 8) == sum, let size = Int(number, radix: 8), size >= 0,
              !name.hasPrefix("/"), !name.split(separator: "/").contains(".."), names.insert(name).inserted else { throw invalid() }
        padding = (512 - size % 512) % 512
        return Entry(name: name, size: size)
    }
    var position: Int64 { get throws { Int64(try handle.offset()) } }
    func copy(_ size: Int, to url: URL, progress: (Int64) async -> Void) async throws {
        try Data().write(to: url)
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        var remaining = size
        var last = Date.distantPast
        while remaining > 0 {
            try Task.checkCancellation()
            let chunk = try data(min(1024 * 1024, remaining))
            try output.write(contentsOf: chunk)
            remaining -= chunk.count
            if Date().timeIntervalSince(last) >= 1 {
                last = Date(); await progress(try position)
            }
        }
    }
}
