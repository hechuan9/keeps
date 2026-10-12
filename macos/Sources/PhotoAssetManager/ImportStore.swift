import CryptoKit
import Foundation
import KeepsAPI
import SwiftUI

@MainActor
final class ImportStore: ObservableObject {
    let client: KeepsClient
    @Published var preserveStructure = false
    @Published var deduplicate = false
    @Published private(set) var skippedFiles = 0
    @Published private(set) var source: URL?
    @Published private(set) var isBusy = false { didSet { onActivity?(isBusy) } }
    @Published private(set) var message = "选择来源文件夹和 NAS 目标文件夹。"
    @Published private(set) var errorMessage: String?
    @Published private(set) var completedFiles = 0
    @Published private(set) var fileCount = 0
    @Published private(set) var sentBytes: Int64 = 0
    @Published private(set) var totalBytes: Int64 = 0
    @Published private(set) var job: KeepsJob?
    @Published private(set) var manifest: KeepsImportManifest?
    @Published private(set) var isFinishing = false
    @Published private(set) var publishedFiles = 0
    private var sources: [ImportSourceFile] = []
    private var operation: Task<Void, Never>?
    private var activeFileID: UUID?

    @Published private(set) var indexTotal = 0
    @Published private(set) var indexedFiles = 0
    @Published private(set) var thumbnailTotal = 0
    @Published private(set) var thumbnailCompleted = 0
    var onCompletion: (() -> Void)?
    var onActivity: ((Bool) -> Void)?
    private var workerID = UUID().uuidString
    private var bookmark: Data?
    private var mediaTasks: [KeepsWorkerTask] = []
    private var activeMediaTasks: Set<String> = []
    private var claimingMedia = false
    private struct Checkpoint: Codable {
        var manifest: KeepsImportManifest
        var sources: [ImportSourceFile]
        var bookmark: Data
        var isFinishing: Bool
        var workerID: String
        var mediaTask: KeepsWorkerTask?
        var mediaTasks: [KeepsWorkerTask]?
    }
    private let checkpointURL: URL

    init(client: KeepsClient, persistenceDirectory: URL? = nil) {
        self.client = client
        let key = SHA256.hash(data: Data((client.configuration.baseURL.absoluteString + "|" + client.configuration.libraryID).utf8)).map { String(format: "%02x", $0) }.joined()
        checkpointURL = (persistenceDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Keeps/ImportTasks")).appendingPathComponent(key + ".json")
        do {
            if FileManager.default.fileExists(atPath: checkpointURL.path) {
                let saved = try JSONDecoder().decode(Checkpoint.self, from: Data(contentsOf: checkpointURL))
                manifest = saved.manifest; sources = saved.sources; bookmark = saved.bookmark
                isFinishing = saved.isFinishing; workerID = saved.workerID; mediaTasks = saved.mediaTasks ?? saved.mediaTask.map { [$0] } ?? []
                preserveStructure = saved.manifest.preserveStructure; deduplicate = saved.manifest.deduplicate
                fileCount = saved.sources.count; totalBytes = saved.sources.reduce(0) { $0 + $1.size }
                if let first = saved.sources.first {
                    var root = first.url
                    for _ in first.sourcePath.split(separator: "/") { root.deleteLastPathComponent() }
                    source = root
                }
                var stale = false
                if !saved.isFinishing {
                    source = try URL(resolvingBookmarkData: saved.bookmark, options: [.withSecurityScope], bookmarkDataIsStale: &stale)
                }
                message = "发现未完成的导入，点击继续导入可恢复同一批次。"
            }
        } catch { report(error); message = "导入恢复失败，请重新授权原来源文件夹后继续同一批次。" }
    }

    private func persist() throws {
        guard let manifest, let bookmark else { throw KeepsAPIError.invalidResponse }
        try FileManager.default.createDirectory(at: checkpointURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Checkpoint(manifest: manifest, sources: sources, bookmark: bookmark, isFinishing: isFinishing, workerID: workerID, mediaTask: nil, mediaTasks: mediaTasks)).write(to: checkpointURL, options: .atomic)
    }

    func selectSource(_ url: URL) {
        guard !isBusy else { return }
        if let oldSource = source, manifest != nil, url.standardizedFileURL != oldSource.standardizedFileURL {
            report(NSError(domain: "KeepsImport", code: 6, userInfo: [NSLocalizedDescriptionKey: "请选择同一导入来源文件夹：" + oldSource.path]))
            return
        }
        source = url
        errorMessage = nil
        if manifest != nil {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                try persist()
            } catch { report(error) }
        }
    }

    func report(_ error: Error) {
        let file = manifest?.files.first { $0.id == activeFileID }?.relativePath
        errorMessage = (file.map { "文件：\($0)\n" } ?? "") + String(reflecting: error) + "\n" + error.localizedDescription
    }

    func start(targetPath: String) {
        guard !isBusy, job == nil, (source != nil || manifest != nil), !targetPath.isEmpty else { return }
        isBusy = true
        errorMessage = nil
        operation = Task {
            let access = source?.startAccessingSecurityScopedResource() ?? false
            defer {
                if access { source?.stopAccessingSecurityScopedResource() }
                activeFileID = nil
                isBusy = false
                operation = nil
            }
            do {
                if manifest == nil {
                    guard let source else { throw KeepsAPIError.invalidResponse }
                    bookmark = try source.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                    try await inventory(source: source, targetPath: targetPath)
                    try persist()
                }
                let heartbeat = Task {
                    while !Task.isCancelled {
                        do {
                            try await Task.sleep(for: .seconds(60))
                            if let id = self.manifest?.id { try await self.client.heartbeatImport(id: id, workerID: self.workerID) }
                        } catch is CancellationError { return }
                        catch { self.report(error) }
                    }
                }
                defer { heartbeat.cancel() }
                try Task.checkCancellation()
                while true {
                    do {
                        if isFinishing, let manifest { try await runMediaPipeline(id: manifest.id) }
                        else { try await upload() }
                        break
                    } catch KeepsAPIError.http(let status, let body) where status == 429 || status >= 500 {
                        report(KeepsAPIError.http(status, body))
                        message = "服务器暂时不可用，正在恢复同一导入批次…"
                        try await Task.sleep(for: .seconds(3))
                    } catch let error as URLError where [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet].contains(error.code) {
                        report(error)
                        message = "连接中断，正在恢复同一导入批次…"
                        try await Task.sleep(for: .seconds(3))
                    }
                }
            } catch is CancellationError {
                message = isFinishing ? "Mac 处理已暂停，NAS 继续后台导入。点击继续导入可恢复处理。" : "导入已暂停，可以继续。已上传的文件保留在 NAS。"
            } catch let error as URLError where error.code == .cancelled {
                message = isFinishing ? "Mac 处理已暂停，NAS 继续后台导入。点击继续导入可恢复处理。" : "导入已暂停，可以继续。已上传的文件保留在 NAS。"
            } catch {
                report(error)
                message = "导入未完成。可重试此批次，已上传的文件不会重复上传。"
            }
        }
    }

    func pause() { operation?.cancel() }

    func reset() {
        guard !isBusy, job != nil else { return }
        do { if FileManager.default.fileExists(atPath: checkpointURL.path) { try FileManager.default.removeItem(at: checkpointURL) } }
        catch { report(error); return }
        manifest = nil
        isFinishing = false
        publishedFiles = 0
        sources = []
        mediaTasks = []
        completedFiles = 0
        skippedFiles = 0
        fileCount = 0
        sentBytes = 0
        totalBytes = 0
        job = nil
        errorMessage = nil
        message = "可以重新选择来源和目标。之前上传的文件保留在 NAS，新导入将使用新批次。"
    }

    private func inventory(source: URL, targetPath: String) async throws {
        let deduplicate = deduplicate
        let preserveStructure = preserveStructure
        message = "正在递归查找 RAW、JPEG、HEIF 和关联 XMP…"
        let scan = Task.detached(priority: .userInitiated) { try ImportSource.scan(source) }
        let files = try await withTaskCancellationHandler {
            try await scan.value
        } onCancel: {
            scan.cancel()
        }
        guard !files.isEmpty else {
            throw NSError(domain: "KeepsImport", code: 1, userInfo: [NSLocalizedDescriptionKey: "来源文件夹中没有 RAW、JPEG 或 HEIF 照片。"])
        }
        sources = files
        fileCount = files.count
        totalBytes = files.reduce(0) { $0 + $1.size }
        manifest = KeepsImportManifest(id: UUID(), targetPath: targetPath, files: files.map {
            KeepsImportFile(id: UUID(), relativePath: $0.sourcePath, size: $0.size)
        }, deduplicate: deduplicate, preserveStructure: preserveStructure, workerID: workerID)
    }

    private func validateSource(_ file: ImportSourceFile) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.url.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == file.size,
              attributes[.modificationDate] as? Date == file.modifiedAt else {
            throw NSError(domain: "KeepsImport", code: 2, userInfo: [NSLocalizedDescriptionKey: "来源文件发生变化，请重新选择导入：\(file.sourcePath)"])
        }
    }

    private func prepare(_ manifest: KeepsImportManifest) async throws -> KeepsImportBatch {
        for attempt in 0..<3 {
            do {
                let batch = try await client.prepareImport(manifest)
                errorMessage = nil
                return batch
            } catch let error as URLError where error.code == .timedOut || error.code == .networkConnectionLost {
                guard attempt < 2 else { throw error }
                report(error)
                message = "连接暂时中断，正在恢复同一导入批次…"
                try await Task.sleep(for: .seconds(1))
            }
        }
        throw KeepsAPIError.invalidResponse
    }

    private func upload() async throws {
        guard let manifest else { return }
        message = "正在准备 NAS 导入批次…"
        let batch = try await prepare(manifest)
        let sourceByPath = Dictionary(uniqueKeysWithValues: sources.map { ($0.sourcePath, $0) })
        skippedFiles = batch.files.filter { $0.skipped == true }.count
        completedFiles = batch.files.filter(\.uploaded).count
        let completeBytes = batch.files.filter(\.uploaded).reduce(Int64(0)) { $0 + $1.size }
        sentBytes = completeBytes
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.uploadFiles(batch, sourceByPath: sourceByPath, completeBytes: completeBytes)
            }
            group.addTask {
                try await self.runMediaPipeline(id: batch.id)
            }
            defer { group.cancelAll() }
            while let _ = try await group.next() {}
        }
    }

    private func uploadFiles(_ batch: KeepsImportBatch, sourceByPath: [String: ImportSourceFile], completeBytes: Int64) async throws {
        var completeBytes = completeBytes
        let groups = Dictionary(grouping: batch.files) { ImportSource.groupKey($0.relativePath) }
        var processed: Set<String> = []
        for first in batch.files {
            let key = ImportSource.groupKey(first.relativePath)
            guard processed.insert(key).inserted, var files = groups[key], files.contains(where: { !$0.uploaded }) else { continue }
            if manifest?.deduplicate == true, !files.contains(where: { $0.uploaded }), !files.allSatisfy({ $0.matched == true }) {
                let matched = try await match(files, batchID: batch.id, sourceByPath: sourceByPath)
                files = matched.files
                skippedFiles += files.filter { $0.skipped == true }.count
                completedFiles += files.filter(\.uploaded).count
                completeBytes += files.filter(\.uploaded).reduce(0) { $0 + $1.size }
                sentBytes = completeBytes
            }
            for file in files where !file.uploaded {
                guard let sourceFile = sourceByPath[file.relativePath] else { throw KeepsAPIError.invalidResponse }
                try await uploadFile(file, batchID: batch.id, source: sourceFile, completeBytes: completeBytes)
                completeBytes += file.size
                sentBytes = completeBytes
                completedFiles += 1
            }
        }
        try Task.checkCancellation()
        message = "上传完成，正在提交 NAS 整理任务…"
        isFinishing = true
        try persist()
    }

    private func uploadFile(_ file: KeepsImportBatch.File, batchID: UUID, source: ImportSourceFile, completeBytes: Int64) async throws {
        try Task.checkCancellation()
        try validateSource(source)
        message = "上传 \(file.relativePath) → \(file.fileName)"
        activeFileID = file.id
        try await client.uploadImportFile(batchID: batchID, fileID: file.id, source: source.url) { [weak self] bytes in
            Task { @MainActor [weak self] in
                guard let self, self.activeFileID == file.id else { return }
                self.sentBytes = completeBytes + min(bytes, file.size)
            }
        }
        activeFileID = nil
    }

    private func match(_ files: [KeepsImportBatch.File], batchID: UUID, sourceByPath: [String: ImportSourceFile]) async throws -> KeepsImportBatch {
        guard let first = files.first else { throw KeepsAPIError.invalidResponse }
        let originals = try files.map { file -> ImportSourceFile in
            guard let source = sourceByPath[file.relativePath] else { throw KeepsAPIError.invalidResponse }
            try validateSource(source)
            return source
        }
        message = "正在匹配 \(first.relativePath) 及关联文件…"
        activeFileID = first.id
        let hashTask = Task.detached(priority: .userInitiated) {
            try zip(files, originals).map { file, source in
                KeepsImportFile(id: file.id, relativePath: file.relativePath, size: file.size, sha256: try ImportSource.hash(source.url).1)
            }
        }
        let hashed = try await withTaskCancellationHandler { try await hashTask.value } onCancel: { hashTask.cancel() }
        for source in originals { try validateSource(source) }
        let matched = try await client.matchImportFiles(batchID: batchID, fileID: first.id, files: hashed)
        for source in originals { try validateSource(source) }
        guard Set(matched.files.map(\.id)) == Set(files.map(\.id)) else { throw KeepsAPIError.invalidResponse }
        activeFileID = nil
        return matched
    }

    private func updateProgress(_ status: KeepsImportFinish) {
        publishedFiles = status.completedFiles
        indexTotal = status.indexTotal ?? fileCount
        indexedFiles = status.indexedFiles ?? 0
        thumbnailTotal = status.thumbnailTotal ?? 0
        thumbnailCompleted = status.thumbnailCompleted ?? 0
    }

    private func runMediaPipeline(id: UUID) async throws {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<2 {
                group.addTask { try await self.consumeMedia(id: id); return false }
            }
            group.addTask { try await self.pollProgress(id: id); return true }
            defer { group.cancelAll() }
            while let finished = try await group.next() {
                if finished { break }
            }
        }
        mediaTasks = []
        try FileManager.default.removeItem(at: checkpointURL)
        onCompletion?()
        message = "导入完成：\(fileCount - skippedFiles) 个文件，跳过 \(skippedFiles) 个重复文件。元数据与缩略图已就绪。"
    }

    private func pollProgress(id: UUID) async throws {
        while !isFinishing {
            try Task.checkCancellation()
            let status = try await client.importFinishStatus(id: id)
            updateProgress(status)
            if status.status == "failed" {
                throw NSError(domain: "KeepsImport", code: 3, userInfo: [NSLocalizedDescriptionKey: status.error ?? "NAS 导入失败，请重试此批次。"])
            }
            if !isFinishing { try await Task.sleep(for: .seconds(1)) }
        }
        try await finish(id: id)
    }

    private func nextMediaTask(id: UUID) async throws -> KeepsWorkerTask? {
        if let pending = mediaTasks.first(where: { !activeMediaTasks.contains($0.taskID) }) {
            activeMediaTasks.insert(pending.taskID)
            return pending
        }
        guard !claimingMedia else { return nil }
        claimingMedia = true
        defer { claimingMedia = false }
        guard let claimed = try await client.claimImportMedia(id: id, workerID: workerID).task else { return nil }
        guard !activeMediaTasks.contains(claimed.taskID) else { return nil }
        if !mediaTasks.contains(where: { $0.taskID == claimed.taskID }) { mediaTasks.append(claimed) }
        try persist()
        activeMediaTasks.insert(claimed.taskID)
        return claimed
    }

    private func consumeMedia(id: UUID) async throws {
        while job == nil {
            try Task.checkCancellation()
            if let task = try await nextMediaTask(id: id) {
                defer { activeMediaTasks.remove(task.taskID) }
                try await processMedia(task)
            } else {
                try await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func completeMediaTask(_ task: KeepsWorkerTask) throws {
        mediaTasks.removeAll { $0.taskID == task.taskID }
        try persist()
    }

    private func processMedia(_ task: KeepsWorkerTask) async throws {
        let heartbeat = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)); try await client.heartbeatWorker(taskID: task.taskID) }
                catch is CancellationError { return }
                catch { self.report(error) }
            }
        }
        defer { heartbeat.cancel() }
        do {
            while true {
                do { try await ImportRenderer.process(task, client: client); try completeMediaTask(task); return }
                catch let error as URLError where [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet].contains(error.code) {
                    report(error)
                    try await Task.sleep(for: .seconds(3))
                } catch KeepsAPIError.http(let status, let body) where status == 429 || status >= 500 {
                    report(KeepsAPIError.http(status, body))
                    try await Task.sleep(for: .seconds(3))
                } catch KeepsAPIError.http(let status, _) where status == 409 {
                    try completeMediaTask(task)
                    return
                }
            }
        }
        catch {
            if !(error is CancellationError), !(error is URLError), !(error is KeepsAPIError) {
                do { try await client.failWorker(taskID: task.taskID, error: String(reflecting: error) + "\n" + error.localizedDescription); try completeMediaTask(task) }
                catch let failure { report(NSError(domain: "KeepsImport", code: 7, userInfo: [NSLocalizedDescriptionKey: String(reflecting: error) + "\n任务失败通知：" + String(reflecting: failure)])) }
            }
            throw error
        }
    }

    private func finish(id: UUID) async throws {
        var submit = true
        while job == nil {
            try Task.checkCancellation()
            do {
                let status = try await (submit ? client.finishImport(id: id) : client.importFinishStatus(id: id))
                submit = false
                updateProgress(status)
                errorMessage = nil
                switch status.status {
                case "finished":
                    guard let completedJob = status.job else { throw KeepsAPIError.invalidResponse }
                    job = completedJob
                case "indexing":
                    message = "正在提取元数据：\(indexedFiles) / \(indexTotal)"
                case "thumbnails":
                    message = "正在生成缩略图：\(thumbnailCompleted) / \(thumbnailTotal)"
                case "failed":
                    throw NSError(domain: "KeepsImport", code: 3, userInfo: [NSLocalizedDescriptionKey: status.error ?? "NAS 导入失败，请重试此批次。"])
                case "uploading":
                    submit = true
                case "publishing":
                    message = "NAS 正在提交文件：\(status.completedFiles) / \(status.totalFiles)。"
                default:
                    throw KeepsAPIError.invalidResponse
                }
            } catch let error as URLError where [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet].contains(error.code) {
                submit = false
                report(error)
                message = "连接暂时中断，正在恢复查询同一导入批次。NAS 已接收的任务会继续运行。"
            }
            if job == nil { try await Task.sleep(for: .seconds(1)) }
        }
    }
}

@MainActor
final class ImportTaskOwner: ObservableObject {
    @Published var store: ImportStore?
    private var stores: [ImportStore] = []

    func configure(_ client: KeepsClient?, activity: ((Bool) -> Void)? = nil, completed: @escaping () -> Void) {
        guard let client else { store = nil; return }
        let current: ImportStore
        if let existing = stores.first(where: { $0.client.configuration == client.configuration }) { current = existing }
        else {
            current = ImportStore(client: client)
            stores.append(current)
        }
        store = current
        current.onCompletion = completed
        if let activity { current.onActivity = activity; activity(current.isBusy) }
        if let manifest = current.manifest, current.job == nil, !current.isBusy, current.errorMessage == nil {
            current.start(targetPath: manifest.targetPath)
        }
    }

    func prepareNewIfCompleted() {
        if store?.job != nil { store?.reset() }
    }
}
