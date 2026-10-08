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
    @Published private(set) var isBusy = false
    @Published private(set) var message = "选择来源文件夹和 NAS 目标文件夹。"
    @Published private(set) var errorMessage: String?
    @Published private(set) var completedFiles = 0
    @Published private(set) var fileCount = 0
    @Published private(set) var sentBytes: Int64 = 0
    @Published private(set) var totalBytes: Int64 = 0
    @Published private(set) var job: KeepsJob?
    @Published private(set) var manifest: KeepsImportManifest?
    private var sources: [ImportSourceFile] = []
    private var operation: Task<Void, Never>?
    private var activeFileID: UUID?

    init(client: KeepsClient) { self.client = client }

    func selectSource(_ url: URL) {
        guard !isBusy, manifest == nil else { return }
        source = url
        errorMessage = nil
    }

    func report(_ error: Error) {
        let file = manifest?.files.first { $0.id == activeFileID }?.relativePath
        errorMessage = (file.map { "文件：\($0)\n" } ?? "") + String(reflecting: error) + "\n" + error.localizedDescription
    }

    func start(targetPath: String) {
        guard !isBusy, job == nil, let source, !targetPath.isEmpty else { return }
        isBusy = true
        errorMessage = nil
        operation = Task {
            let access = source.startAccessingSecurityScopedResource()
            defer {
                if access { source.stopAccessingSecurityScopedResource() }
                activeFileID = nil
                isBusy = false
                operation = nil
            }
            do {
                if manifest == nil { try await inventory(source: source, targetPath: targetPath) }
                try Task.checkCancellation()
                try await upload()
            } catch is CancellationError {
                message = "导入已暂停，可以继续。已上传的文件保留在 NAS。"
            } catch let error as URLError where error.code == .cancelled {
                message = "导入已暂停，可以继续。已上传的文件保留在 NAS。"
            } catch {
                report(error)
                message = "导入未完成。可重试此批次，已上传的文件不会重复上传。"
            }
        }
    }

    func pause() { operation?.cancel() }

    func reset() {
        guard !isBusy else { return }
        manifest = nil
        sources = []
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
        let calculateHashes = deduplicate
        let preserveStructure = preserveStructure
        message = calculateHashes ? "正在读取文件以检查目标目录中的重复内容…" : "正在递归查找 RAW、JPEG、HEIF 和关联 XMP…"
        let scan = Task.detached(priority: .userInitiated) { try ImportSource.scan(source, calculateHashes: calculateHashes) }
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
            KeepsImportFile(id: UUID(), relativePath: $0.sourcePath, size: $0.size, sha256: $0.sha256)
        }, deduplicate: calculateHashes, preserveStructure: preserveStructure)
    }

    private func validateSource(_ file: ImportSourceFile) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.url.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == file.size,
              attributes[.modificationDate] as? Date == file.modifiedAt else {
            throw NSError(domain: "KeepsImport", code: 2, userInfo: [NSLocalizedDescriptionKey: "来源文件发生变化，请重新选择导入：\(file.sourcePath)"])
        }
    }

    private func upload() async throws {
        guard let manifest else { return }
        for file in sources { try validateSource(file) }
        message = manifest.deduplicate ? "正在检查目标目录中的重复文件并保持配对…" : "正在准备 NAS 目标文件名…"
        let batch = try await client.prepareImport(manifest)
        let sourceByPath = Dictionary(uniqueKeysWithValues: sources.map { ($0.sourcePath, $0) })
        skippedFiles = batch.files.filter { $0.skipped == true }.count
        completedFiles = batch.files.filter(\.uploaded).count
        var completeBytes = batch.files.filter(\.uploaded).reduce(Int64(0)) { $0 + $1.size }
        sentBytes = completeBytes
        for file in batch.files where !file.uploaded {
            try Task.checkCancellation()
            guard let sourceFile = sourceByPath[file.relativePath] else { throw KeepsAPIError.invalidResponse }
            try validateSource(sourceFile)
            message = "上传 \(file.relativePath) → \(file.fileName)"
            activeFileID = file.id
            let base = completeBytes
            try await client.uploadImportFile(batchID: batch.id, fileID: file.id, source: sourceFile.url) { [weak self] bytes in
                Task { @MainActor [weak self] in
                    guard let self, self.activeFileID == file.id else { return }
                    self.sentBytes = base + min(bytes, file.size)
                }
            }
            try validateSource(sourceFile)
            activeFileID = nil
            completeBytes += file.size
            sentBytes = completeBytes
            completedFiles += 1
        }
        try Task.checkCancellation()
        for file in sources { try validateSource(file) }
        message = "上传完成，正在提交 NAS 整理任务…"
        job = try await client.finishImport(id: batch.id)
        message = "已导入 \(fileCount - skippedFiles) 个文件，跳过 \(skippedFiles) 个重复文件。NAS 正在索引并安排缩略图与版本整理，可在“任务追踪”查看。"
    }
}
