import Combine
import CryptoKit
import Foundation
import ImageIO
import KeepsAPI

struct ExposureTask: Codable, Identifiable, Sendable {
    enum Operation: String, Codable { case automatic, setNegative, reset }
    enum Phase: String, Codable { case preparing, downloading, rendering, uploading, completed }
    let id: UUID
    let assetID: UUID
    let baseURL: String
    let libraryID: String
    let operation: Operation
    let requestedContentHash: String?
    var phase: Phase = .preparing
    var sourceHash: String?
    var sourceFilename: String?
    var sourceFileHash: String?
    var expectedRevision: Int64?
    var render: ExposureRender?
    var waitingForConnection = false
    var error: String?
    var failed = false
}

@MainActor
final class ExposureTaskStore: ObservableObject {
    @Published private(set) var tasks: [ExposureTask] = []
    @Published private(set) var storageError: String?
    @Published private(set) var completionRevision = 0
    private let root: URL
    private let session: URLSession
    var retryInterval: Duration = .seconds(5)
    private var configuration: KeepsConfiguration?
    private var runner: Task<Void, Never>?
    private var generation = UUID()

    init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Keeps/ExposureTasks", isDirectory: true), session: URLSession = KeepsClient.apiSession) {
        self.root = root
        self.session = session
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let manifest = root.appendingPathComponent("tasks.json")
            if FileManager.default.fileExists(atPath: manifest.path) {
                tasks = try JSONDecoder().decode([ExposureTask].self, from: Data(contentsOf: manifest))
            }
        } catch { storageError = String(reflecting: error) }
    }

    func configure(_ configuration: KeepsConfiguration?) {
        guard self.configuration != configuration else { return }
        self.configuration = configuration
        generation = UUID()
        let token = generation
        let previous = runner
        previous?.cancel()
        runner = Task {
            await previous?.value
            guard token == generation, !Task.isCancelled else { return }
            runner = nil
            start()
        }
    }

    func automaticExposure(assetID: UUID) { enqueue(assetID: assetID, operation: .automatic) }
    func setNegative(assetID: UUID, contentHash: String) { enqueue(assetID: assetID, operation: .setNegative, hash: contentHash) }
    func resetExposure(assetID: UUID) { enqueue(assetID: assetID, operation: .reset) }

    func discard(id: UUID) {
        guard let task = tasks.first(where: { $0.id == id }), task.failed || task.phase == .completed else { return }
        do {
            try cleanFiles(task)
            tasks.removeAll { $0.id == id }
            try persist()
        } catch { storageError = String(reflecting: error) }
    }

    private func cleanFiles(_ task: ExposureTask) throws {
        let directory = root.appendingPathComponent(task.id.uuidString.lowercased())
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    func retry(id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].failed = false
        tasks[index].error = nil
        do { try persist(); start() } catch { storageError = String(reflecting: error) }
    }

    func isPending(assetID: UUID) -> Bool {
        tasks.contains { matches($0) && $0.assetID == assetID && $0.phase != .completed }
    }

    private func enqueue(assetID: UUID, operation: ExposureTask.Operation, hash: String? = nil) {
        guard storageError == nil, let configuration, !isPending(assetID: assetID) else { return }
        tasks.append(ExposureTask(id: UUID(), assetID: assetID, baseURL: configuration.baseURL.absoluteString,
                                  libraryID: configuration.libraryID, operation: operation, requestedContentHash: hash))
        do { try persist(); start() } catch { storageError = String(reflecting: error) }
    }

    private func matches(_ task: ExposureTask) -> Bool {
        task.baseURL == configuration?.baseURL.absoluteString && task.libraryID == configuration?.libraryID
    }

    private func persist() throws {
        try JSONEncoder().encode(tasks).write(to: root.appendingPathComponent("tasks.json"), options: .atomic)
    }

    private func save(_ task: ExposureTask) throws {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index] = task
        try persist()
    }

    private func start() {
        guard runner == nil, storageError == nil, let configuration else { return }
        let token = generation
        runner = Task {
            let client = KeepsClient(configuration: configuration, session: session)
            while !Task.isCancelled, token == generation,
                  var job = tasks.first(where: { matches($0) && !$0.failed && $0.phase != .completed }) {
                do {
                    job.waitingForConnection = false
                    job.error = nil
                    try await advance(&job, client: client)
                    guard token == generation, !Task.isCancelled else { return }
                    try Task.checkCancellation()
                    try save(job)
                    if job.phase == .completed { completionRevision += 1; try cleanFiles(job) }
                } catch {
                    guard token == generation, !Task.isCancelled else { return }
                    let transient = Self.isTransient(error)
                    job.waitingForConnection = transient
                    job.failed = !transient
                    job.error = String(reflecting: error) + "\n" + (error as NSError).description
                    do { try save(job) }
                    catch { storageError = String(reflecting: error); break }
                    if transient {
                        do { try await Task.sleep(for: retryInterval) } catch { return }
                    }
                }
            }
            if token == generation { runner = nil }
        }
    }

    private struct FileInfo: Sendable {
        let hash: String
        let size: Int64
        let width: Int
        let height: Int
    }

    nonisolated private static func inspectFile(_ url: URL, image: Bool) async throws -> FileInfo {
        let work = Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hash = SHA256()
            var size: Int64 = 0
            while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
                try Task.checkCancellation()
                hash.update(data: data)
                size += Int64(data.count)
            }
            var width = 0
            var height = 0
            if image {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let imageWidth = properties[kCGImagePropertyPixelWidth] as? Int,
                      let imageHeight = properties[kCGImagePropertyPixelHeight] as? Int else { throw ExposureJobError.missingRender }
                width = imageWidth
                height = imageHeight
            }
            return FileInfo(hash: hash.finalize().map { String(format: "%02x", $0) }.joined(),
                            size: size, width: width, height: height)
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    private static func isTransient(_ error: Error) -> Bool {
        if error is URLError { return true }
        if case KeepsAPIError.http(let status, _) = error { return status >= 500 || status == 408 || status == 429 }
        return false
    }

    private func advance(_ job: inout ExposureTask, client: KeepsClient) async throws {
        let directory = root.appendingPathComponent(job.id.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if job.phase == .preparing {
            let state = try await client.editState(assetID: job.assetID)
            if state.lastRequestID == job.id.uuidString.lowercased() { job.phase = .completed; return }
            if job.expectedRevision == nil {
                let hash = job.requestedContentHash ?? state.negativeContentHash
                var filename = state.sourceFilename
                var fileHash = state.sourceFileHash
                if job.operation == .setNegative, let hash {
                    let versions = try await client.versionDetails(assetID: job.assetID)
                    filename = versions.items.first(where: { $0.contentHash == hash })?.filename
                    fileHash = hash
                }
                try Task.checkCancellation()
                job.expectedRevision = state.revision
                job.sourceHash = hash
                job.sourceFilename = filename
                job.sourceFileHash = fileHash
                try Task.checkCancellation()
                try save(job)
            }
            if job.operation == .reset {
                _ = try await client.resetEdit(assetID: job.assetID, expectedRevision: job.expectedRevision!, requestID: job.id)
                job.phase = .completed
                return
            }
            guard let hash = job.sourceHash, job.sourceFilename != nil else {
                throw ExposureJobError.missingNegative
            }
            if job.operation == .setNegative && !state.hasEdit {
                _ = try await client.setNegativeVersion(assetID: job.assetID, contentHash: hash,
                    expectedRevision: job.expectedRevision!, requestID: job.id)
                job.phase = .completed
                return
            }
            job.phase = .downloading
            return
        }
        let filename = job.sourceFilename ?? "source"
        let source = directory.appendingPathComponent("source").appendingPathExtension(URL(fileURLWithPath: filename).pathExtension)
        switch job.phase {
        case .downloading:
            try await client.downloadNegative(assetID: job.assetID, contentHash: job.sourceHash!, to: source)
            if let expectedHash = job.sourceFileHash {
                let actualHash = try await Self.inspectFile(source, image: false).hash
                guard actualHash == expectedHash else { throw ExposureJobError.sourceChanged }
            }
            job.phase = .rendering
        case .rendering:
            job.render = try await ExposureRenderer().render(sourceURL: source, outputDirectory: directory)
            job.phase = .uploading
        case .uploading:
            let state = try await client.editState(assetID: job.assetID)
            if state.lastRequestID == job.id.uuidString.lowercased() { job.phase = .completed; return }
            guard state.revision == job.expectedRevision else { throw ExposureJobError.conflict }
            let session = try await client.prepareEditUploads(assetID: job.assetID, requestID: job.id)
            guard let render = job.render else { throw ExposureJobError.missingRender }
            let files = ["standard": render.standard, "thumbnail": render.thumbnail, "browse": render.browse]
            guard Set(session.objects.map(\.role)) == Set(files.keys), session.objects.count == 3 else {
                throw KeepsAPIError.invalidResponse
            }
            var outputs: [KeepsEditOutput] = []
            for target in session.objects {
                let url = files[target.role]!
                try await AIEditingImages.identify(url, rootID: state.rootID ?? job.assetID.uuidString, versionID: job.id)
                let info = try await Self.inspectFile(url, image: true)
                try Task.checkCancellation()
                try await client.uploadEditImage(target: target, file: url)
                outputs.append(KeepsEditOutput(role: target.role, objectRef: target.objectRef,
                    contentHash: info.hash, width: info.width, height: info.height, sizeBytes: info.size))
            }
            _ = try await client.commitEdit(assetID: job.assetID, edit: KeepsEditCommit(requestID: job.id.uuidString.lowercased(),
                expectedRevision: job.expectedRevision!, negativeContentHash: job.sourceHash!, exposureEV: render.exposureEV,
                algorithmVersion: ExposureRenderer.algorithmVersion, rendererVersion: "coreimage-v1", outputs: outputs))
            job.phase = .completed
        case .preparing, .completed: break
        }
    }
}

enum ExposureJobError: LocalizedError {
    case missingNegative, missingRender, conflict, sourceChanged
    var errorDescription: String? {
        switch self {
        case .sourceChanged: "下载底片与索引内容不同，请重新扫描后再试。"
        case .missingNegative: "底片缺失，请在照片信息中选择底片。"
        case .missingRender: "本地曝光展示图缺失。"
        case .conflict: "照片的底片或调整已改变，请核实后重新操作。"
        }
    }
}
