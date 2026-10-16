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
    @MainActor public static func handleBackgroundEvents(identifier: String, completionHandler: @escaping () -> Void) -> Bool {
        #if os(iOS)
        guard identifier == OfflineBackgroundDownload.identifier else { return false }
        OfflineBackgroundDownload.shared.accept(.init(completionHandler))
        return true
        #else
        return false
        #endif
    }

    public static func restoreBackgroundDownloads() {
        #if os(iOS)
        _ = OfflineBackgroundDownload.shared
        #endif
    }

    public static func pauseBackgroundDownloads() async {
        #if os(iOS)
        await OfflineBackgroundDownload.shared.pause()
        #endif
    }

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
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path)
        #endif
        let database = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: databaseRoot)
        let replica = try database.replicaID()
        let generation = try database.generation
        let since = try forceRebuild || generation == nil || database.syncCheckpoint != nil ? nil : database.revision
        let parameters = Parameters(includeThumbnails: includeThumbnails, replicaID: replica,
                                    generation: since == nil ? nil : generation, sinceRevision: since)
        let parametersFile = root.appendingPathComponent("request.json")
        if FileManager.default.fileExists(atPath: parametersFile.path),
           try JSONDecoder().decode(Parameters.self, from: Data(contentsOf: parametersFile)) != parameters {
            try await discard(root)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path)
            #endif
        }
        try JSONEncoder().encode(parameters).write(to: parametersFile, options: .atomic)
        let jobFile = root.appendingPathComponent("job.json")
        let archive = root.appendingPathComponent("bundle.tar")
        #if os(iOS)
        if FileManager.default.fileExists(atPath: archive.path) {
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: archive.path)
        }
        #endif
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
                if status == 404 || status == 410 { try await discard(root) }
                throw KeepsAPIError.http(status, body)
            }
        }
        try JSONEncoder().encode(job).write(to: jobFile, options: .atomic)
        guard let size = job.byteCount, size > 0, let digest = job.sha256, digest.count == 64 else { throw failure("离线包缺少长度或校验值") }
        let existing = (try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard existing <= size else { throw failure("离线包断点长度错误") }
        if existing < size {
            var request = try request(configuration, method: "GET", suffix: [job.id.uuidString, "download"])
            if existing > 0 { request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }
            request.setValue("\"\(digest)\"", forHTTPHeaderField: "If-Match")
            do {
                #if os(iOS)
                if databaseRoot == nil {
                    let receipt = try await OfflineBackgroundDownload.shared.download(request, root: root,
                        receipt: .init(offset: existing, total: size, digest: digest), progress: progress)
                    try Task.checkCancellation()
                    try receipt.merge(in: root)
                    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: archive.path)
                } else {
                    try await OfflineFileDownload(file: archive, offset: existing, total: size, digest: digest, progress: progress).run(request, configuration: session.configuration)
                }
                #else
                try await OfflineFileDownload(file: archive, offset: existing, total: size, digest: digest, progress: progress).run(request, configuration: session.configuration)
                #endif
            }
            catch KeepsAPIError.http(let status, let body) {
                if status == 404 || status == 410 { try await discard(root) }
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
            #if os(iOS)
            await OfflineBackgroundDownload.shared.discard(root: root)
            for name in [OfflineDownloadReceipt.filename, "resume.data", "download.part"] {
                let file = root.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            }
            #endif
            try FileManager.default.removeItem(at: archive)
            throw failure("离线包 SHA256 校验失败，请重试传输")
        }
        let manifest = try await unpack(archive, root: root, configuration: configuration, databaseRoot: databaseRoot, progress: progress)
        try FileManager.default.removeItem(at: root)
        try await acknowledge(configuration: configuration, databaseRoot: databaseRoot)
        return manifest
    }
    private func discard(_ root: URL) async throws {
        #if os(iOS)
        await OfflineBackgroundDownload.shared.discard(root: root)
        #endif
        try FileManager.default.removeItem(at: root)
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

/// A completed system download is staged before any append, so interruption cannot duplicate bytes.
struct OfflineDownloadReceipt: Codable, Equatable {
    var offset: Int64
    var total: Int64
    var digest: String
    var token = UUID().uuidString

    static let filename = "background.json"
    func validate(_ response: HTTPURLResponse, downloadedBytes: Int64) throws {
        guard response.statusCode == 200 || response.statusCode == 206 else {
            throw KeepsAPIError.http(response.statusCode, "离线包下载失败")
        }
        guard downloadedBytes == total - offset,
              response.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) == digest else {
            throw URLError(.badServerResponse)
        }
        if response.statusCode == 200 {
            guard offset == 0 else { throw URLError(.badServerResponse) }
        } else {
            let range = response.value(forHTTPHeaderField: "Content-Range") ?? ""
            let prefix = "bytes "
            let suffix = "-\(total - 1)/\(total)"
            guard range.hasPrefix(prefix), range.hasSuffix(suffix),
                  let start = Int64(range.dropFirst(prefix.count).dropLast(suffix.count)),
                  start >= offset, start < total else { throw URLError(.badServerResponse) }
        }
    }

    func merge(in root: URL) throws {
        let archive = root.appendingPathComponent("bundle.tar")
        let part = root.appendingPathComponent("download.part")
        let bytes = Int64(try part.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1)
        guard bytes == total - offset else { throw URLError(.dataLengthExceedsMaximum) }
        if offset == 0 {
            if FileManager.default.fileExists(atPath: archive.path) { try FileManager.default.removeItem(at: archive) }
            try FileManager.default.moveItem(at: part, to: archive)
            return
        }
        let existing = Int64(try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1)
        guard (offset...total).contains(existing) else { throw URLError(.dataLengthExceedsMaximum) }
        let input = try FileHandle(forReadingFrom: part)
        let output = try FileHandle(forWritingTo: archive)
        defer { try? input.close(); try? output.close() }
        try input.seek(toOffset: UInt64(existing - offset))
        try output.seekToEnd()
        while let data = try autoreleasepool(invoking: { try input.read(upToCount: 1024 * 1024) }), !data.isEmpty {
            try Task.checkCancellation()
            try output.write(contentsOf: data)
        }
        try output.synchronize()
        try FileManager.default.removeItem(at: part)
    }
}

#if os(iOS)
private final class OfflineBackgroundDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = OfflineBackgroundDownload()
    static let identifier = "local.keeps.offline-downloads.v1"
    private let queue = DispatchQueue(label: "local.keeps.offline-downloads")
    private var session: URLSession!
    private var waiters: [String: Waiter] = [:]
    private var active: [String: URLSessionDownloadTask] = [:]
    private var failures: [Int: Error] = [:]
    private var completion: Completion?
    private var finishedEvents = false
    private var discarded: Set<Int> = []
    private let base = URL.applicationSupportDirectory.appendingPathComponent("Keeps/OfflineRebuild")

    @MainActor final class Completion {
        let body: () -> Void
        init(_ body: @escaping () -> Void) { self.body = body }
    }
    private final class Waiter: @unchecked Sendable {
        let progress: @Sendable (KeepsOfflineRebuild.Progress) async -> Void
        private let lock = NSLock()
        private var continuation: CheckedContinuation<OfflineDownloadReceipt, Error>?
        private var cancelled = false
        var lastProgress = Date.distantPast
        init(progress: @escaping @Sendable (KeepsOfflineRebuild.Progress) async -> Void) { self.progress = progress }
        func install(_ continuation: CheckedContinuation<OfflineDownloadReceipt, Error>) {
            lock.lock(); defer { lock.unlock() }
            if cancelled { continuation.resume(throwing: CancellationError()) }
            else { self.continuation = continuation }
        }
        func finish(_ result: Result<OfflineDownloadReceipt, Error>) {
            lock.lock(); let continuation = self.continuation; self.continuation = nil; lock.unlock()
            continuation?.resume(with: result)
        }
        func cancel() {
            lock.lock(); cancelled = true; let continuation = self.continuation; self.continuation = nil; lock.unlock()
            continuation?.resume(throwing: CancellationError())
        }
        var isCancelled: Bool { lock.withLock { cancelled } }
    }

    private override init() {
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        let callbacks = OperationQueue()
        callbacks.maxConcurrentOperationCount = 1
        callbacks.underlyingQueue = queue
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: callbacks)
    }

    func accept(_ completion: Completion) {
        queue.async {
            if self.finishedEvents {
                self.finishedEvents = false
                Task { @MainActor in completion.body() }
            } else { self.completion = completion }
        }
    }

    func download(_ request: URLRequest, root: URL, receipt: OfflineDownloadReceipt,
                  progress: @escaping @Sendable (KeepsOfflineRebuild.Progress) async -> Void) async throws -> OfflineDownloadReceipt {
        let waiter = Waiter(progress: progress)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.install(continuation)
                queue.async {
                    guard !waiter.isCancelled else { return }
                    let key = root.lastPathComponent
                    self.session.getAllTasks { tasks in
                        self.queue.async {
                            guard !waiter.isCancelled else { return }
                            self.waiters.removeValue(forKey: key)?.cancel()
                            self.waiters[key] = waiter
                            do {
                                let saved = try self.receipt(root)
                                if let saved, saved.total == receipt.total, saved.digest == receipt.digest,
                                   FileManager.default.fileExists(atPath: root.appendingPathComponent("download.part").path) {
                                    self.waiters.removeValue(forKey: key)?.finish(.success(saved))
                                    return
                                }
                                let current = saved ?? receipt
                                guard current.total == receipt.total, current.digest == receipt.digest, current.offset == receipt.offset else {
                                    throw KeepsLibraryDatabase.DatabaseError(message: "后台下载状态不匹配，请重试")
                                }
                                let description = key + ":" + current.token
                                let currentTask = self.active[key].flatMap { $0.state == .running || $0.state == .suspended ? $0 : nil }
                                let task = currentTask ?? tasks.compactMap { $0 as? URLSessionDownloadTask }.first { $0.taskDescription == description && ($0.state == .running || $0.state == .suspended) }
                                if let task {
                                    self.active[key] = task
                                    task.resume()
                                    return
                                }
                                try Self.write(try JSONEncoder().encode(current), to: root.appendingPathComponent(OfflineDownloadReceipt.filename))
                                let resume = root.appendingPathComponent("resume.data")
                                let created: URLSessionDownloadTask
                                if FileManager.default.fileExists(atPath: resume.path) {
                                    created = self.session.downloadTask(withResumeData: try Data(contentsOf: resume))
                                    try FileManager.default.removeItem(at: resume)
                                } else { created = self.session.downloadTask(with: request) }
                                created.taskDescription = description
                                created.countOfBytesClientExpectsToReceive = current.total - current.offset
                                self.active[key] = created
                                created.resume()
                            } catch { self.waiters.removeValue(forKey: key)?.finish(.failure(error)) }
                        }
                    }
                }
            }
        } onCancel: { waiter.cancel() }
    }

    func pause() async {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                let group = DispatchGroup()
                for task in tasks.compactMap({ $0 as? URLSessionDownloadTask }) {
                    group.enter()
                    task.cancel { data in
                        self.queue.async {
                            if let (root, _) = try? self.context(task) {
                                let key = root.lastPathComponent
                                if let newer = self.active[key], newer.taskIdentifier != task.taskIdentifier { group.leave(); return }
                                if self.active[key]?.taskIdentifier == task.taskIdentifier {
                                    self.active.removeValue(forKey: key)
                                    self.waiters.removeValue(forKey: key)?.cancel()
                                }
                                do { if let data { try Self.write(data, to: root.appendingPathComponent("resume.data")) } }
                                catch { Logger(subsystem: "local.keeps", category: "offline-rebuild").error("Save download resume data failed: \(String(reflecting: error), privacy: .public)") }
                            }
                            group.leave()
                        }
                    }
                }
                group.notify(queue: self.queue) { continuation.resume() }
            }
        }
    }

    func discard(root: URL) async {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                self.queue.async {
                    let key = root.lastPathComponent
                    for task in tasks where task.taskDescription?.hasPrefix(key + ":") == true {
                        self.discarded.insert(task.taskIdentifier)
                        task.cancel()
                    }
                    self.active.removeValue(forKey: key)
                    self.waiters.removeValue(forKey: key)?.cancel()
                    continuation.resume()
                }
            }
        }
    }

    private func receipt(_ root: URL) throws -> OfflineDownloadReceipt? {
        let file = root.appendingPathComponent(OfflineDownloadReceipt.filename)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(OfflineDownloadReceipt.self, from: Data(contentsOf: file))
    }
    private func context(_ task: URLSessionTask) throws -> (URL, OfflineDownloadReceipt) {
        guard let parts = task.taskDescription?.split(separator: ":"), parts.count == 2 else { throw KeepsLibraryDatabase.DatabaseError(message: "后台下载状态不匹配，请重试") }
        let root = base.appendingPathComponent(String(parts[0]))
        guard let receipt = try receipt(root), receipt.token == parts[1] else { throw KeepsLibraryDatabase.DatabaseError(message: "后台下载状态不匹配，请重试") }
        return (root, receipt)
    }
    private static func write(_ data: Data, to file: URL) throws {
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard !discarded.contains(downloadTask.taskIdentifier) else { return }
        do {
            let (root, receipt) = try context(downloadTask)
            if let newer = active[root.lastPathComponent], newer.taskIdentifier != downloadTask.taskIdentifier { return }
            guard let response = downloadTask.response as? HTTPURLResponse else { throw KeepsAPIError.invalidResponse }
            try receipt.validate(response, downloadedBytes: Int64(try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1))
            let part = root.appendingPathComponent("download.part")
            if FileManager.default.fileExists(atPath: part.path) { try FileManager.default.removeItem(at: part) }
            try FileManager.default.moveItem(at: location, to: part)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: part.path)
        } catch { failures[downloadTask.taskIdentifier] = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard discarded.remove(task.taskIdentifier) == nil else { failures.removeValue(forKey: task.taskIdentifier); return }
        let context: (URL, OfflineDownloadReceipt)
        do { context = try self.context(task) }
        catch {
            failures.removeValue(forKey: task.taskIdentifier)
            if let key = task.taskDescription?.split(separator: ":").first.map(String.init),
               active[key]?.taskIdentifier == task.taskIdentifier {
                active.removeValue(forKey: key)
                waiters.removeValue(forKey: key)?.finish(.failure(error))
            }
            return
        }
        let (root, receipt) = context
        let key = root.lastPathComponent
        if let newer = active[key], newer.taskIdentifier != task.taskIdentifier { failures.removeValue(forKey: task.taskIdentifier); return }
        if active[key]?.taskIdentifier == task.taskIdentifier { active.removeValue(forKey: key) }
        var failure = failures.removeValue(forKey: task.taskIdentifier) ?? error
        if let data = (error as NSError?)?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            do { try Self.write(data, to: root.appendingPathComponent("resume.data")) }
            catch { failure = error }
        }
        let result: Result<OfflineDownloadReceipt, Error>
        if let failure { result = .failure(failure) }
        else { result = .success(receipt) }
        waiters.removeValue(forKey: key)?.finish(result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let (root, receipt) = try? context(downloadTask), let waiter = waiters[root.lastPathComponent], !waiter.isCancelled,
              Date().timeIntervalSince(waiter.lastProgress) >= 1 else { return }
        waiter.lastProgress = Date()
        let progress = KeepsOfflineRebuild.Progress(phase: .downloading, completed: min(receipt.total, receipt.offset + totalBytesWritten), total: receipt.total, message: "下载离线包")
        Task { await waiter.progress(progress) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        if let completion {
            self.completion = nil
            Task { @MainActor in completion.body() }
        } else { finishedEvents = true }
    }
}
#endif
