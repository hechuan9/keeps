import Combine
import Foundation
import KeepsAPI

struct GeometryTask: Codable, Identifiable, Sendable {
    enum Operation: String, Codable { case rotate, crop }
    enum Phase: String, Codable { case preparing, downloading, rendering, uploading, completed }
    let id: UUID
    let assetID: UUID
    let baseURL: String
    let libraryID: String
    let operation: Operation
    var requestedQuarterTurns: Int?
    var requestedCrop: CGRect?
    var requestedRevision: Int64?
    var exposureEV: Double?
    var recipe: KeepsEditRecipe?
    var sourceVersion: String?
    var phase: Phase = .preparing
    var sourceHash: String?
    var expectedRevision: Int64?
    var render: GeometryRender?
    var waitingForConnection = false
    var error: String?
    var failed = false
}

@MainActor
final class GeometryTaskStore: ObservableObject {
    @Published private(set) var tasks: [GeometryTask] = []
    @Published private(set) var storageError: String?
    @Published private(set) var completionRevision = 0
    private let root: URL
    private let session: URLSession
    var retryInterval: Duration = .seconds(5)
    private var configuration: KeepsConfiguration?
    private var runner: Task<Void, Never>?
    private var generation = UUID()

    init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Keeps/GeometryTasks", isDirectory: true), session: URLSession = KeepsClient.apiSession) {
        self.root = root
        self.session = session
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let manifest = root.appendingPathComponent("tasks.json")
            if FileManager.default.fileExists(atPath: manifest.path) {
                tasks = try JSONDecoder().decode([GeometryTask].self, from: Data(contentsOf: manifest))
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

    func rotate(assetID: UUID, quarterTurns: Int) {
        enqueue(assetID: assetID, operation: .rotate, quarterTurns: quarterTurns)
    }
    func crop(assetID: UUID, crop: CGRect, expectedRevision: Int64) {
        enqueue(assetID: assetID, operation: .crop, crop: crop, revision: expectedRevision)
    }

    func discard(id: UUID) {
        guard let task = tasks.first(where: { $0.id == id }), task.failed || task.phase == .completed else { return }
        do {
            try cleanFiles(task)
            tasks.removeAll { $0.id == id }
            try persist()
        } catch { storageError = String(reflecting: error) }
    }

    private func cleanFiles(_ task: GeometryTask) throws {
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

    private func enqueue(assetID: UUID, operation: GeometryTask.Operation, quarterTurns: Int? = nil, crop: CGRect? = nil, revision: Int64? = nil) {
        guard storageError == nil, let configuration, !isPending(assetID: assetID) else { return }
        tasks.append(GeometryTask(id: UUID(), assetID: assetID, baseURL: configuration.baseURL.absoluteString,
                                  libraryID: configuration.libraryID, operation: operation, requestedQuarterTurns: quarterTurns, requestedCrop: crop, requestedRevision: revision))
        do { try persist(); start() } catch { storageError = String(reflecting: error) }
    }

    private func matches(_ task: GeometryTask) -> Bool {
        task.baseURL == configuration?.baseURL.absoluteString && task.libraryID == configuration?.libraryID
    }

    private func persist() throws {
        try JSONEncoder().encode(tasks).write(to: root.appendingPathComponent("tasks.json"), options: .atomic)
    }

    private func save(_ task: GeometryTask) throws {
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

    private static func isTransient(_ error: Error) -> Bool {
        if error is URLError { return true }
        if case KeepsAPIError.http(let status, _) = error { return status >= 500 || status == 408 || status == 429 }
        return false
    }

    private func advance(_ job: inout GeometryTask, client: KeepsClient) async throws {
        let directory = root.appendingPathComponent(job.id.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if job.phase == .preparing {
            let state = try await client.editState(assetID: job.assetID)
            if state.lastRequestID == job.id.uuidString.lowercased() { job.phase = .completed; return }
            if let requested = job.requestedRevision, requested != state.revision { throw GeometryJobError.conflict }
            guard state.sourceAvailable else { throw GeometryJobError.missingNegative }
            guard let hash = state.negativeContentHash else { throw GeometryJobError.missingNegative }
            let asset = try await client.asset(id: job.assetID)
            guard let standard = asset.standard else { throw GeometryJobError.missingRender }
            let confirmed = try await client.editState(assetID: job.assetID)
            guard confirmed.revision == state.revision else { throw GeometryJobError.conflict }
            try Task.checkCancellation()
            job.exposureEV = state.recipe == nil ? (state.exposureEV ?? 0) : nil
            job.recipe = state.recipe
            job.expectedRevision = state.revision
            job.sourceHash = hash
            job.sourceVersion = standard.version
            job.phase = .downloading
            return
        }
        let source = directory.appendingPathComponent("source.heic")
        switch job.phase {
        case .downloading:
            let state = try await client.editState(assetID: job.assetID)
            guard state.revision == job.expectedRevision else { throw GeometryJobError.conflict }
            let asset = try await client.asset(id: job.assetID)
            guard let standard = asset.standard, standard.version == job.sourceVersion else { throw GeometryJobError.sourceChanged }
            let (temporary, response) = try await session.download(from: standard.downloadURL)
            guard let response = response as? HTTPURLResponse else { throw KeepsAPIError.invalidResponse }
            guard (200..<300).contains(response.statusCode) else { throw KeepsAPIError.http(response.statusCode, "下载当前标准图失败") }
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: source.path) { try FileManager.default.removeItem(at: source) }
            try FileManager.default.moveItem(at: temporary, to: source)
            job.phase = .rendering
        case .rendering:
            job.render = try await GeometryRenderer().render(sourceURL: source, outputDirectory: directory,
                quarterTurns: job.requestedQuarterTurns ?? 0, crop: job.requestedCrop)
            job.phase = .uploading
        case .uploading:
            let state = try await client.editState(assetID: job.assetID)
            if state.lastRequestID == job.id.uuidString.lowercased() { job.phase = .completed; return }
            guard state.revision == job.expectedRevision else { throw GeometryJobError.conflict }
            let session = try await client.prepareEditUploads(assetID: job.assetID, requestID: job.id)
            guard let render = job.render else { throw GeometryJobError.missingRender }
            let files = ["standard": render.standard, "thumbnail": render.thumbnail, "browse": render.browse]
            guard Set(session.objects.map(\.role)) == Set(files.keys), session.objects.count == 3 else {
                throw KeepsAPIError.invalidResponse
            }
            var outputs: [KeepsEditOutput] = []
            for target in session.objects {
                let url = files[target.role]!
                let info = try await AIEditingImages.inspect(url, image: true)
                try Task.checkCancellation()
                try await client.uploadEditImage(target: target, file: url)
                outputs.append(KeepsEditOutput(role: target.role, objectRef: target.objectRef,
                    contentHash: info.hash, width: info.width, height: info.height, sizeBytes: info.size))
            }
            _ = try await client.commitEdit(assetID: job.assetID, edit: KeepsEditCommit(requestID: job.id.uuidString.lowercased(),
                expectedRevision: job.expectedRevision!, negativeContentHash: job.sourceHash!, exposureEV: job.exposureEV,
                algorithmVersion: "geometry-v1", rendererVersion: "coreimage-v1", outputs: outputs, recipe: job.recipe))
            job.phase = .completed
        case .preparing, .completed: break
        }
    }
}

enum GeometryJobError: LocalizedError {
    case missingNegative, missingRender, conflict, sourceChanged
    var errorDescription: String? {
        switch self {
        case .sourceChanged: "当前标准图已变化，请重新操作。"
        case .missingNegative: "底片不存在或不可用，无法保存调整，请恢复底片后重试。"
        case .missingRender: "当前标准图或本地调整展示图缺失。"
        case .conflict: "照片的底片或调整已改变，请核实后重新操作。"
        }
    }
}
