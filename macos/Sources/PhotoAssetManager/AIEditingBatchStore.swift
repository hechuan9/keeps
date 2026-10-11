import Combine
import CryptoKit
import Foundation
import KeepsAPI

struct AIEditingBatch: Codable {
    struct Candidate: Codable, Identifiable {
        let id: UUID
        var result: AIGradeResult
        let instruction: String
        let parentID: UUID?
        var preferences: String = ""
        var preferenceRevision: Int64 = 0
        var batchInstruction: String = ""
    }
    struct Item: Codable, Identifiable {
        enum Phase: String, Codable { case preparing, downloading, grading, uploading, discarding, done, review }
        let id: UUID
        let assetID: UUID
        let name: String
        var phase: Phase = .preparing
        var source: KeepsEditState?
        var result: AIGradeResult?
        var failure: String?
        var failureDetails: String?
        var phaseSeconds: [String: Double]?
        var candidates: [Candidate]?
        var selectedCandidateID: UUID?
        var originalPreview: URL?
        var pendingInstruction: String?
        var pendingCandidateID: UUID?
        var confirmedAt: String?
        var preferences: String?
        var preferenceRevision: Int64?
        var batchInstruction: String?
        var isBackgroundDecision: Bool { phase == .uploading || phase == .discarding }
        var isVisibleInWorkspace: Bool { phase != .done && (!isBackgroundDecision || failure != nil) }
        var terminal: Bool { phase == .done || phase == .review }
    }
    let id: UUID
    let baseURL: String
    let libraryID: String
    var confirmed = false
    var cancelled = false
    var items: [Item]
    var preferences: String?
    var preferenceRevision: Int64?
    var instruction: String?
}

@MainActor final class AIEditingBatchStore: ObservableObject {
    let editor: AIEditingSettingsStore
    @Published private(set) var batch: AIEditingBatch?
    @Published private(set) var status = "准备 AI 调色"
    @Published private(set) var errorMessage: String?
    @Published private(set) var errorDetails: String?
    @Published private(set) var diagnosticDirectory: URL?
    @Published private(set) var isRunning = false
    var isBlocking: Bool { false }
    @Published private(set) var preferenceSuggestions: [AIEditingPreferenceSuggestion] = []
    @Published var preferencesText = ""
    @Published var batchInstruction = "" {
        didSet {
            guard !isRestoringState, batch != nil else { return }
            batch!.instruction = batchInstruction
            do { try persist() } catch { recordFailure(error) }
        }
    }
    private var database: AIEditingDatabase?
    private var isRestoringState = false
    private var preferencesRevision: Int64 = 0
    var isAwaitingUpload: Bool { batch?.items.first(where: { !$0.terminal })?.phase == .uploading }
    var pendingResultURL: URL? { isAwaitingUpload ? batch?.items.first(where: { !$0.terminal })?.result?.fullSize : nil }
    var isAwaitingConfirmation: Bool { batch != nil && batch?.confirmed == false && batch?.cancelled == false }
    var workspaceItems: [AIEditingBatch.Item] { batch?.items.filter(\.isVisibleInWorkspace) ?? [] }
    var backgroundDecisionCount: Int { batch?.items.filter { $0.isBackgroundDecision && $0.failure == nil }.count ?? 0 }
    var failedDecisionCount: Int { batch?.items.filter { $0.isBackgroundDecision && $0.failure != nil }.count ?? 0 }
    var totalCount: Int { batch?.items.count ?? 0 }
    var completedCount: Int { batch?.items.filter(\.terminal).count ?? 0 }
    var isFinished: Bool { batch != nil && !isRunning && (batch!.cancelled || batch!.items.allSatisfy(\.terminal)) }
    private let root: URL
    private weak var library: LibraryStore?
    private var worker: Task<Void, Never>?
    private var comparisonWorkers: [UUID: Task<Void, Never>] = [:]
    private var itemWorkers: [UUID: Task<Void, Never>] = [:]
    struct Activity: Identifiable {
        let id: UUID
        let name: String
        var title = "等待处理"
        var progress = 0.0
        var ceiling = 0.0
        var elapsedSeconds = 0
    }
    @Published private(set) var activities: [UUID: Activity] = [:]
    @Published private(set) var elapsedSeconds = 0
    var activeItems: [Activity] { batch?.items.compactMap { activities[$0.id] } ?? [] }
    var activeCount: Int { activities.count }
    var failedItems: [AIEditingBatch.Item] { batch?.items.filter { $0.failure != nil } ?? [] }
    var waitingCount: Int { max(0, totalCount - completedCount - activeCount - failedItems.count) }
    var overallProgress: Double {
        min(1, (Double(completedCount) + activities.values.reduce(0) { $0 + $1.progress }) / Double(max(1, totalCount)))
    }
    private var progressTicker: Task<Void, Never>?
    private var gates: [String: Set<UUID>] = [:]
    private var waitingQueues: [String: AIEditingPriorityQueue] = [:]
    private var limits = AIEditingLimits()
    private var aiResumeAfter = Date.distantPast
    private var storageError: Error?
    var retryInterval: Duration = .seconds(5)

    init(root: URL? = nil, editor: AIEditingSettingsStore = AIEditingSettingsStore()) {
        self.editor = editor
        self.root = root ?? editor.root.appendingPathComponent("batches", isDirectory: true)
        do {
            let database = try AIEditingDatabase(root: self.root)
            self.database = database
            if let saved = try database.load() {
                batch = saved.batch
                preferencesText = saved.preferences.text
                preferencesRevision = saved.preferences.revision
            } else {
                try importLegacyState()
            }
            restoreLegacyResults()
            batchInstruction = batch?.instruction ?? ""
            try database.save(batch: batch, preferences: savedPreferences)
            preferenceSuggestions = try database.preferenceSuggestions()
        } catch { storageError = error; recordFailure(error) }
    }

    private var savedPreferences: AIEditingPreferences {
        AIEditingPreferences(text: preferencesText, revision: preferencesRevision)
    }

    private func importLegacyState() throws {
        let manifest = root.appendingPathComponent("batch.json")
        if FileManager.default.fileExists(atPath: manifest.path) {
            batch = try JSONDecoder().decode(AIEditingBatch?.self, from: Data(contentsOf: manifest))
        }
        let preferencesFile = root.appendingPathComponent("preferences.json")
        if FileManager.default.fileExists(atPath: preferencesFile.path) {
            let saved = try JSONDecoder().decode(AIEditingPreferences.self, from: Data(contentsOf: preferencesFile))
            preferencesText = saved.text
            preferencesRevision = saved.revision
        } else {
            preferencesText = batch?.preferences ?? ""
            preferencesRevision = batch?.preferenceRevision ?? 0
        }
    }

    private func restoreLegacyResults() {
        guard let saved = batch else { return }
        batch!.items = saved.items.map { original in
            var item = original
            if item.preferences == nil && item.phase != .preparing {
                item.preferences = saved.preferences ?? ""
                item.preferenceRevision = saved.preferenceRevision ?? 0
                item.batchInstruction = saved.instruction ?? ""
            }
            restoreUnconfirmedUpload(&item)
            if let preview = item.originalPreview, preview.lastPathComponent != "before.heic" {
                item.originalPreview = nil
            }
            restoreReviewRecipes(&item)
            return item
        }
    }

    private func restoreUnconfirmedUpload(_ item: inout AIEditingBatch.Item) {
        guard item.phase == .uploading, item.confirmedAt == nil else { return }
        item.phase = .review
        guard var result = item.result else { return }
        let job = root.appendingPathComponent(item.id.uuidString.lowercased()).appendingPathComponent("ai")
        if FileManager.default.fileExists(atPath: job.appendingPathComponent("result.json").path) {
            do { result = try AIEditingSettingsStore.gradeResult(in: job) }
            catch {
                item.failure = "旧草稿的对比预览不可用，请继续调色生成新版本。"
                item.failureDetails = String(reflecting: error)
            }
        }
        result.preview = result.preview ?? result.fullSize
        item.originalPreview = result.originalPreview
        item.result = result
        let candidate = AIEditingBatch.Candidate(id: UUID(), result: result, instruction: "", parentID: nil)
        item.candidates = [candidate]
        item.selectedCandidateID = result.isSelectable ? candidate.id : nil
    }

    private func restoreReviewRecipes(_ item: inout AIEditingBatch.Item) {
        for index in (item.candidates ?? []).indices {
            let result = item.candidates![index].result
            guard result.status == "needs_review", result.recipeJSON == nil, let preview = result.preview else { continue }
            do {
                let restored = try AIEditingSettingsStore.gradeResult(in: preview.deletingLastPathComponent().deletingLastPathComponent())
                item.candidates![index].result = restored
                if item.selectedCandidateID == item.candidates![index].id { item.result = restored }
            } catch {
                item.failure = AIEditingFailure.userMessage(error)
                item.failureDetails = String(reflecting: error)
            }
        }
    }

    func prepare(library: LibraryStore) {
        guard !library.isOperationBlocking, !library.isMutating, !library.isSelectingAll,
              !library.isCheckingConnection, !library.isUpdatingHiddenDirectory, !library.isImportingPhotos,
              library.directoryToCreate == nil, library.directoryToRename == nil, library.directoryToTrash == nil,
              !library.selectedIDs.isEmpty, let configuration = library.configuration else { return }
        let previous = batch
        do {
            if let storageError { throw storageError }
            if let batch, batch.baseURL != configuration.baseURL.absoluteString || batch.libraryID != configuration.libraryID {
                guard !isRunning, batch.items.allSatisfy({ $0.phase == .done }) else {
                    throw AIEditingFailure("本机工作台还有另一资料库的照片，请先完成后再切换资料库。")
                }
                self.batch = nil
            }
            let names = Dictionary(uniqueKeysWithValues: library.assets.map { ($0.id, $0.originalFilename) })
            if batch == nil {
                batch = AIEditingBatch(id: UUID(), baseURL: configuration.baseURL.absoluteString, libraryID: configuration.libraryID, items: [])
            }
            let existing = Set(batch!.items.filter { $0.phase != .done }.map(\.assetID))
            let pending = library.selectedIDs.subtracting(existing)
            let visible = library.assets.map(\.id).filter { pending.contains($0) }
            let added = visible + pending.subtracting(visible).sorted { $0.uuidString < $1.uuidString }
            batch!.items += added.map { .init(id: UUID(), assetID: $0, name: names[$0] ?? $0.uuidString) }
            self.library = library
            try persist()
            errorMessage = nil; errorDetails = nil; diagnosticDirectory = nil
            status = added.isEmpty ? "已打开本机调色工作台" : "已追加 \(added.count) 张照片"
        } catch { batch = previous; recordFailure(error) }
    }

    func restore(library: LibraryStore) {
        guard !library.isDirectoryOperationBlocking else { return }
        self.library = library
        guard let client = library.client, batch != nil else { return }
        guard matches(client) else { recordFailure(AIEditingFailure("请切回本机工作台所属的资料库。")); return }
        restoreComparisonPreviews(client: client)
        if batch!.confirmed && !batch!.cancelled && !isFinished { start() }
    }

    private func restoreComparisonPreviews(client: KeepsClient) {
        for item in batch?.items ?? [] where item.phase == .review && item.source != nil && item.originalPreview == nil {
            guard comparisonWorkers[item.id] == nil else { continue }
            comparisonWorkers[item.id] = Task {
                defer { comparisonWorkers[item.id] = nil }
                guard batch?.items.first(where: { $0.id == item.id })?.phase == .review else { return }
                do {
                    let directory = root.appendingPathComponent(item.id.uuidString.lowercased(), isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let preview = directory.appendingPathComponent("before.heic")
                    try await acquire("download", itemID: item.id, limit: limits.downloads)
                    defer { gates["download"]?.remove(item.id) }
                    try await client.downloadCurrentStandard(assetID: item.assetID, to: preview)
                    guard let index = batch?.items.firstIndex(where: { $0.id == item.id }) else { return }
                    batch!.items[index].originalPreview = preview
                    try persist()
                } catch {
                    if !Task.isCancelled, batch?.items.first(where: { $0.id == item.id })?.phase == .review {
                        recordFailure(error, context: item.name + "：载入调整前版本")
                    }
                }
            }
        }
    }

    func start() {
        guard storageError == nil, worker == nil, !editor.isBusy, library?.isDirectoryOperationBlocking != true, batch != nil,
              batch!.items.contains(where: { !$0.terminal }) else { return }
        isRunning = true
        worker = Task {
            do {
                guard let library, let client = library.client, matches(client) else { throw AIEditingFailure("请使用创建此任务时的资料库连接。") }
                if let storageError { throw storageError }
                batch!.confirmed = true; batch!.cancelled = false
                try persist()
                errorMessage = nil; errorDetails = nil; diagnosticDirectory = nil
                limits = editor.limits.bounded
                editor.batchActive = true
                elapsedSeconds = 0
                progressTicker = Task { [weak self = self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(1)) } catch { return }
                        self?.tickProgress()
                    }
                }
                try Task.checkCancellation()
                await run(client: client)
            } catch {
                isRunning = false; worker = nil; editor.batchActive = false
                progressTicker?.cancel(); progressTicker = nil
                recordFailure(error); status = "任务已暂停，请处理后重试"
            }
        }
    }

    @discardableResult func savePreferences(text: String? = nil) async -> Bool {
        do {
            if let storageError { throw storageError }
            let next = AIEditingPreferences(text: text ?? preferencesText, revision: preferencesRevision + 1)
            try writeState(preferences: next)
            preferencesText = next.text; preferencesRevision = next.revision
            status = "审美偏好已保存在这台 Mac，尚未开始的照片将使用新偏好"
            errorMessage = nil; errorDetails = nil
            return true
        } catch { recordFailure(error); return false }
    }

    @discardableResult func acceptPreferenceSuggestion(id: UUID, text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        let current = preferencesText.trimmingCharacters(in: .whitespacesAndNewlines)
        let merged = current.isEmpty ? text : current + "\n" + text
        return resolvePreferenceSuggestion(id: id, preferences: .init(text: merged, revision: preferencesRevision + 1))
    }

    @discardableResult func dismissPreferenceSuggestion(id: UUID) -> Bool {
        resolvePreferenceSuggestion(id: id, preferences: nil)
    }

    private func resolvePreferenceSuggestion(id: UUID, preferences: AIEditingPreferences?) -> Bool {
        do {
            if let storageError { throw storageError }
            guard let database else { throw AIEditingFailure("本机工作台数据库未打开。") }
            try database.resolvePreferenceSuggestion(id: id, preferences: preferences)
            if let preferences {
                preferencesText = preferences.text
                preferencesRevision = preferences.revision
            }
            preferenceSuggestions = try database.preferenceSuggestions()
            errorMessage = nil; errorDetails = nil
            return true
        } catch { recordFailure(error); return false }
    }

    @discardableResult func saveBatchInstruction(text: String) -> Bool {
        guard batch != nil, storageError == nil else { return false }
        batchInstruction = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard storageError == nil else { return false }
        errorMessage = nil; errorDetails = nil
        return true
    }

    func selectCandidate(itemID: UUID, candidateID: UUID?) {
        guard let index = batch?.items.firstIndex(where: { $0.id == itemID }),
              canInteract(batch!.items[index]) else { return }
        if let candidateID, !(batch!.items[index].candidates ?? []).contains(where: { $0.id == candidateID && $0.result.isSelectable }) { return }
        batch!.items[index].failure = nil; batch!.items[index].failureDetails = nil
        batch!.items[index].selectedCandidateID = candidateID
        batch!.items[index].result = batch!.items[index].candidates?.first { $0.id == candidateID }?.result
        do { try persist() } catch { recordFailure(error) }
    }

    @discardableResult func refine(itemID: UUID, instruction: String) -> Bool {
        let instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty, let index = batch?.items.firstIndex(where: { $0.id == itemID }),
              canInteract(batch!.items[index]) else { return false }
        batch!.items[index].pendingInstruction = instruction
        batch!.items[index].pendingCandidateID = UUID()
        batch!.items[index].phase = .grading
        batch!.items[index].failure = nil
        batch!.cancelled = false
        do { try persist(); start(); return true } catch { recordFailure(error); return false }
    }

    func canInteract(_ item: AIEditingBatch.Item) -> Bool {
        item.phase == .review && activities[item.id] == nil && itemWorkers[item.id] == nil
    }

    func canPublish(_ item: AIEditingBatch.Item) -> Bool {
        guard canInteract(item) else { return false }
        guard let selected = item.selectedCandidateID else { return true }
        guard let candidate = item.candidates?.first(where: { $0.id == selected }), candidate.result.isSelectable,
              let before = item.originalPreview,
              let after = candidate.result.preview ?? candidate.result.fullSize else { return false }
        return FileManager.default.isReadableFile(atPath: before.path) && FileManager.default.isReadableFile(atPath: after.path)
    }

    func publish(itemID: UUID) {
        do { try confirm(itemID: itemID); start() } catch { recordFailure(error) }
    }

    func choose(itemID: UUID, candidateID: UUID?) {
        guard let index = batch?.items.firstIndex(where: { $0.id == itemID }), canInteract(batch!.items[index]) else { return }
        if let candidateID, !(batch!.items[index].candidates ?? []).contains(where: { $0.id == candidateID && $0.result.isSelectable }) { return }
        let previous = batch
        batch!.items[index].selectedCandidateID = candidateID
        batch!.items[index].result = batch!.items[index].candidates?.first { $0.id == candidateID }?.result
        do { try confirm(itemID: itemID); start() }
        catch { batch = previous; recordFailure(error) }
    }

    func canRestart(_ item: AIEditingBatch.Item) -> Bool {
        item.phase != .done && !item.isBackgroundDecision && itemWorkers[item.id] == nil && activities[item.id] == nil
    }

    @discardableResult func restartItem(itemID: UUID) -> Bool {
        guard let index = batch?.items.firstIndex(where: { $0.id == itemID }),
              canRestart(batch!.items[index]) else { return false }
        let previous = batch
        let item = batch!.items[index]
        batch!.items[index] = .init(id: item.id, assetID: item.assetID, name: item.name,
            originalPreview: item.originalPreview, pendingCandidateID: UUID())
        batch!.cancelled = false
        do { try persist(); start(); return true }
        catch { batch = previous; recordFailure(error); return false }
    }

    func retryItem(itemID: UUID) {
        guard let index = batch?.items.firstIndex(where: { $0.id == itemID }),
              batch!.items[index].phase != .done, batch!.items[index].failure != nil,
              itemWorkers[itemID] == nil else { return }
        let previous = batch
        if batch!.items[index].phase == .review {
            batch!.items[index].phase = .grading
            if batch!.items[index].pendingCandidateID == nil { batch!.items[index].pendingCandidateID = UUID() }
        }
        batch!.items[index].failure = nil; batch!.items[index].failureDetails = nil
        batch!.cancelled = false
        do { try persist(); start() }
        catch { batch = previous; recordFailure(error) }
    }

    func reject(itemID: UUID) {
        guard let index = batch?.items.firstIndex(where: { $0.id == itemID }),
              canInteract(batch!.items[index]) else { return }
        let previous = batch
        batch!.items[index].phase = .discarding
        batch!.items[index].confirmedAt = ISO8601DateFormatter().string(from: Date())
        batch!.items[index].failure = nil
        batch!.items[index].failureDetails = nil
        batch!.cancelled = false
        do { try persist(); start() } catch { batch = previous; recordFailure(error) }
    }

    private func confirm(itemID: UUID) throws {
        guard let index = batch?.items.firstIndex(where: { $0.id == itemID }), batch!.items[index].phase == .review else { return }
        guard canPublish(batch!.items[index]) else { throw AIEditingFailure("对比预览不完整，请继续调色生成新版本后确认。") }
        let previous = batch
        batch!.items[index].confirmedAt = ISO8601DateFormatter().string(from: Date())
        batch!.items[index].phase = .uploading
        batch!.items[index].failure = nil
        batch!.cancelled = false
        do { try persist() } catch { batch = previous; throw error }
    }

    func archiveAndDismiss() {
        guard !isRunning, let batch else { return }
        do {
            let copy = root.appendingPathComponent("recovery-" + batch.id.uuidString + ".json")
            try JSONEncoder().encode(batch).write(to: copy, options: .atomic)
            dismiss()
        } catch { recordFailure(error) }
    }

    func closeCompletedWorkspace() {
        guard !isRunning, batch?.items.allSatisfy({ $0.phase == .done }) == true else { return }
        let previous = batch
        batch!.items = []
        do { try persist() } catch { batch = previous; recordFailure(error) }
    }

    private func editMetadata(_ item: AIEditingBatch.Item) throws -> String {
        let candidate = item.candidates?.first { $0.id == item.selectedCandidateID }
        let object: [String: Any] = ["reason": candidate?.result.reason ?? item.candidates?.last?.result.reason ?? "保留调整前版本",
            "instruction": candidate?.instruction ?? "", "preferences": candidate?.preferences ?? item.preferences ?? "",
            "preferenceRevision": candidate?.preferenceRevision ?? item.preferenceRevision ?? 0,
            "batchInstruction": candidate?.batchInstruction ?? item.batchInstruction ?? "",
            "selection": item.selectedCandidateID?.uuidString ?? "original", "confirmedAt": item.confirmedAt ?? "",
            "history": try (item.candidates ?? []).map { ["id": $0.id.uuidString, "reason": $0.result.reason, "instruction": $0.instruction, "parentID": $0.parentID?.uuidString ?? "", "status": $0.result.status, "recipeJSON": try Self.historyRecipe($0.result.recipeJSON) ?? ""] }]
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    static func historyRecipe(_ recipe: String?) throws -> String? {
        guard let recipe else { return nil }
        func summarize(_ value: Any) throws -> Any {
            if var object = value as? [String: Any] {
                if var raster = object["raster"] as? [String: Any], let encoded = raster["pngBase64"] as? String {
                    guard let data = Data(base64Encoded: encoded) else { throw AIEditingFailure("遮板 PNG 数据无效。") }
                    raster.removeValue(forKey: "pngBase64")
                    raster["pngSHA256"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    raster["pngSizeBytes"] = data.count
                    object["raster"] = raster
                }
                return try object.mapValues { try summarize($0) }
            }
            if let array = value as? [Any] { return try array.map { try summarize($0) } }
            return value
        }
        let object = try JSONSerialization.jsonObject(with: Data(recipe.utf8))
        return String(decoding: try JSONSerialization.data(withJSONObject: summarize(object), options: [.sortedKeys]), as: UTF8.self)
    }

    func retry() {
        if let client = library?.client { restoreComparisonPreviews(client: client) }
        if batch?.cancelled == true { batch!.cancelled = false }
        if let items = batch?.items {
            for index in items.indices where items[index].failure != nil && items[index].phase == .review && items[index].pendingCandidateID != nil {
                batch!.items[index].phase = .grading
            }
        }
        if batch != nil {
            for index in batch!.items.indices { batch!.items[index].failure = nil; batch!.items[index].failureDetails = nil }
        }
        do { try persist() } catch { recordFailure(error); return }
        start()
    }

    func stopForExit() {
        worker?.cancel()
        for task in comparisonWorkers.values { task.cancel() }
        editor.stopForExit()
    }

    func cancel() {
        guard batch != nil else { return }
        batch!.cancelled = true
        editor.cancel()
        worker?.cancel()
        status = "正在停止；已提交的调色结果保留"
        do { try persist() } catch { recordFailure(error) }
        if worker == nil { status = "已取消；已提交的结果保留" }
    }

    func dismiss() {
        guard !isRunning else { return }
        let previous = batch
        batch = nil
        do { try persist() }
        catch { batch = previous; recordFailure(error); return }
        library?.isAIEditingBlocking = false
        library?.refresh(force: true)
        library?.refreshNavigation()
    }

    private func recordFailure(_ error: Error, context: String? = nil) {
        errorMessage = [context, AIEditingFailure.userMessage(error)].compactMap { $0 }.joined(separator: "\n")
        errorDetails = AIEditingSettingsStore.redacted(String(reflecting: error))
        diagnosticDirectory = (error as? AIEditingFailure)?.logDirectory ?? root
        do {
            try Data((errorDetails ?? "").utf8).write(to: root.appendingPathComponent("failure.log"), options: .atomic)
        } catch {
            errorDetails = (errorDetails ?? "") + "\n诊断日志无法写入：" + error.localizedDescription
        }
    }

    private func matches(_ client: KeepsClient) -> Bool {
        batch?.baseURL == client.configuration.baseURL.absoluteString && batch?.libraryID == client.configuration.libraryID
    }

    private func persist() throws {
        do { try writeState(preferences: savedPreferences) }
        catch {
            if let database {
                do { try restoreCommittedState(from: database) }
                catch { recordFailure(error, context: "无法恢复本机已保存状态") }
            }
            throw error
        }
    }

    private func writeState(preferences: AIEditingPreferences) throws {
        if let storageError { throw storageError }
        guard let database else { throw AIEditingFailure("本机工作台数据库未打开。") }
        do {
            try database.save(batch: batch, preferences: preferences)
            preferenceSuggestions = try database.preferenceSuggestions()
        }
        catch { stopForStorageFailure(error); throw error }
    }

    private func restoreCommittedState(from database: AIEditingDatabase) throws {
        guard let saved = try database.load() else { return }
        isRestoringState = true
        defer { isRestoringState = false }
        batch = saved.batch
        preferencesText = saved.preferences.text
        preferencesRevision = saved.preferences.revision
        batchInstruction = batch?.instruction ?? ""
        preferenceSuggestions = try database.preferenceSuggestions()
    }

    private func stopForStorageFailure(_ error: Error) {
        storageError = error
        worker?.cancel()
        for task in itemWorkers.values { task.cancel() }
        for task in comparisonWorkers.values { task.cancel() }
    }

    private func save(_ item: AIEditingBatch.Item, index: Int) throws {
        if let storageError { throw storageError }
        guard let database else { throw AIEditingFailure("本机工作台数据库未打开。") }
        do {
            try database.save(item: item, position: index)
            preferenceSuggestions = try database.preferenceSuggestions()
        }
        catch { stopForStorageFailure(error); throw error }
        batch!.items[index] = item
    }

    private func run(client: KeepsClient) async {
        defer {
            progressTicker?.cancel(); progressTicker = nil
            activities = [:]
            isRunning = false; worker = nil
            editor.batchActive = false
            if batch?.cancelled == true { status = "已取消；已提交的结果保留" }
            else if !Task.isCancelled, batch?.items.contains(where: { !$0.terminal && $0.failure == nil }) == true { start() }
        }
        while !Task.isCancelled, batch?.cancelled == false {
            let pending = batch!.items.filter { !$0.terminal && $0.failure == nil && itemWorkers[$0.id] == nil }
            var admission = AIEditingPriorityQueue()
            for item in pending { admission.insert(item.id, position: position(of: item.id)) }
            while let id = admission.pop() {
                guard let item = pending.first(where: { $0.id == id }) else { continue }
                let decision = item.phase == .uploading || item.phase == .discarding
                let running = batch!.items.filter { itemWorkers[$0.id] != nil }
                let laneCount = running.filter { ($0.phase == .uploading || $0.phase == .discarding) == decision }.count
                guard laneCount < max(1, limits.photos) else { continue }
                itemWorkers[item.id] = Task {
                    await self.process(id: item.id, client: client)
                    self.itemWorkers[item.id] = nil
                }
            }
            if itemWorkers.isEmpty { break }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
        }
        let remaining = Array(itemWorkers.values)
        for task in remaining { task.cancel() }
        for task in remaining { await task.value }
        library?.refresh(force: true)
        if batch?.cancelled == false {
            status = failedItems.isEmpty
                ? "已处理 \(completedCount) 张；\(batch!.items.filter { $0.phase == .review }.count) 张需要检查"
                : "已完成 \(completedCount) 张，\(failedItems.count) 张待重试；已调好的结果保留在本机"
        }
    }

    private func process(id: UUID, client: KeepsClient) async {
        guard let index = batch?.items.firstIndex(where: { $0.id == id }) else { return }
        activities[id] = Activity(id: id, name: batch!.items[index].name)
        defer { activities[id] = nil }
        var aiRetries = 0
        while !Task.isCancelled, batch?.cancelled == false {
            var item = batch!.items[index]
            guard !item.terminal else { return }
            let phase = item.phase.rawValue
            let started = Date()
            do {
                try await advance(&item, client: client)
                item.phaseSeconds = item.phaseSeconds ?? [:]
                item.phaseSeconds![phase, default: 0] += Date().timeIntervalSince(started)
                try save(item, index: index)
                if item.phase == .done {
                    library?.refresh(force: true)
                    library?.refreshNavigation()
                }
            } catch {
                item.phaseSeconds = item.phaseSeconds ?? [:]
                item.phaseSeconds![phase, default: 0] += Date().timeIntervalSince(started)
                if Task.isCancelled || batch?.cancelled == true {
                    do { try save(item, index: index) } catch { recordFailure(error) }
                    return
                }
                if Self.isTransient(error) {
                    if item.phase == .grading {
                        aiRetries += 1
                        aiResumeAfter = max(aiResumeAfter, Date().addingTimeInterval(min(120, 30 * pow(2, Double(min(aiRetries - 1, 2))))))
                    }
                    stage(id, item.phase == .grading ? "AI 暂时不可用，等待后重试" : "连接暂时不可用，等待重连", activities[id]?.progress ?? 0, activities[id]?.progress ?? 0)
                    do { try save(item, index: index); try await Task.sleep(for: retryInterval) }
                    catch { if !Task.isCancelled { recordFailure(error) }; return }
                } else {
                    if item.phase == .grading, !(item.candidates ?? []).isEmpty {
                        item.phase = .review
                        item.result = item.candidates?.first { $0.id == item.selectedCandidateID }?.result
                    }
                    item.failure = AIEditingFailure.userMessage(error)
                    item.failureDetails = AIEditingSettingsStore.redacted(String(reflecting: error))
                    do { try save(item, index: index) } catch { recordFailure(error); return }
                    recordFailure(error, context: item.name + "：" + (activities[id]?.title ?? ""))
                    return
                }
            }
        }
    }

    private func stage(_ id: UUID, _ title: String, _ floor: Double, _ ceiling: Double) {
        guard var activity = activities[id] else { return }
        activity.title = title
        activity.progress = max(activity.progress, floor)
        activity.ceiling = max(activity.progress, ceiling)
        activities[id] = activity
        status = "正在处理 \(activeCount) 张，等待 \(waitingCount) 张，待重试 \(failedItems.count) 张"
    }

    func tickProgress() {
        guard isRunning else { return }
        elapsedSeconds += 1
        for id in Array(activities.keys) {
            activities[id]!.elapsedSeconds += 1

        }
    }

    static func hasPriority(_ id: UUID, for name: String, items: [AIEditingBatch.Item], holders: Set<UUID> = []) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        let phases: Set<AIEditingBatch.Item.Phase>
        switch name {
        case "download": phases = [.preparing, .downloading]
        case "ai": phases = [.preparing, .downloading, .grading]
        default: phases = [.uploading, .discarding]
        }
        return !items[..<index].contains {
            $0.failure == nil && phases.contains($0.phase) && !holders.contains($0.id)
        }
    }

    private func position(of itemID: UUID) -> Int {
        batch?.items.firstIndex(where: { $0.id == itemID }) ?? Int.max
    }

    private func acquire(_ name: String, itemID: UUID, limit: Int) async throws {
        waitingQueues[name, default: .init()].insert(itemID, position: position(of: itemID))
        defer { waitingQueues[name]?.remove(itemID) }
        while true {
            try Task.checkCancellation()
            waitingQueues[name]?.updateOrder(batch?.items.map(\.id) ?? [])
            // Preserve upstream ordering within admitted photos, without blocking on unstarted rows.
            if waitingQueues[name]?.first == itemID,
               gates[name, default: []].count < max(1, limit),
               Self.hasPriority(itemID, for: name, items: batch?.items.filter { itemWorkers[$0.id] != nil } ?? [],
                                holders: gates[name, default: []]),
               name != "ai" || Date() >= aiResumeAfter {
                gates[name, default: []].insert(itemID)
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    static func gradingContext(for item: AIEditingBatch.Item) -> AIGradeContext {
        let selected = item.candidates?.first { $0.id == item.selectedCandidateID }
        return AIGradeContext(preferences: item.preferences ?? "", batchInstruction: item.batchInstruction ?? "",
            instruction: item.pendingInstruction ?? "", baseRecipeJSON: selected?.result.recipeJSON,
            history: (item.candidates ?? []).map(\.instruction))
    }

    private func advance(_ item: inout AIEditingBatch.Item, client: KeepsClient) async throws {
        let directory = root.appendingPathComponent(item.id.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if item.phase == .preparing {
            try await acquire("download", itemID: item.id, limit: limits.downloads)
            defer { gates["download"]?.remove(item.id) }
            stage(item.id, "读取底片（\(completedCount + 1)/\(totalCount)）", 0.01, 0.04)
            if item.preferences == nil {
                item.preferences = preferencesText
                item.preferenceRevision = preferencesRevision
                item.batchInstruction = batchInstruction
            }
            let state = try await client.editState(assetID: item.assetID)
            if state.lastRequestID == item.id.uuidString.lowercased() { item.phase = .done; return }
            guard state.sourceAvailable, state.negativeContentHash != nil, state.sourceFilename != nil else {
                throw AIEditingFailure("底片不可用，请先在信息面板检查底片版本。")
            }
            item.source = state
            item.phase = .downloading
            return
        }
        if item.phase == .discarding {
            try await acquire("upload", itemID: item.id, limit: limits.uploads)
            defer { gates["upload"]?.remove(item.id) }
            stage(item.id, "标记为弃用", 0.9, 0.95)
            _ = try await client.updateAsset(id: item.assetID, patch: KeepsAssetPatch(flagState: "rejected"))
            item.phase = .done
            return
        }
        guard let sourceState = item.source, let hash = sourceState.negativeContentHash,
              let filename = sourceState.sourceFilename else { throw AIEditingFailure("任务缺少底片信息。") }
        let source = directory.appendingPathComponent("source").appendingPathExtension(URL(fileURLWithPath: filename).pathExtension)
        switch item.phase {
        case .downloading:
            stage(item.id, "等待下载", 0.04, 0.04)
            try await acquire("download", itemID: item.id, limit: limits.downloads)
            defer { gates["download"]?.remove(item.id) }
            if item.originalPreview == nil {
                let preview = directory.appendingPathComponent("before.heic")
                try await client.downloadCurrentStandard(assetID: item.assetID, to: preview)
                item.originalPreview = preview
            }
            stage(item.id, "下载底片（\(completedCount + 1)/\(totalCount)）", 0.04, 0.15)
            try await client.downloadNegative(assetID: item.assetID, contentHash: hash, to: source)
            let info = try await AIEditingImages.inspect(source, image: false)
            guard info.hash == (sourceState.sourceFileHash ?? hash) else { throw AIEditingFailure("底片下载校验失败，请重新扫描后再试。") }
            item.phase = .grading
        case .grading:
            if !FileManager.default.fileExists(atPath: source.path) { item.phase = .downloading; return }
            stage(item.id, "等待 AI 会话", 0.15, 0.15)
            try await acquire("ai", itemID: item.id, limit: limits.ai)
            defer { gates["ai"]?.remove(item.id) }
            if item.originalPreview == nil {
                let preview = directory.appendingPathComponent("before.heic")
                try await client.downloadCurrentStandard(assetID: item.assetID, to: preview)
                item.originalPreview = preview
            }
            let itemID = item.id
            stage(item.id, "连接 AI，准备观察照片", 0.15, 0.25)
            let context = Self.gradingContext(for: item)
            let jobName = item.pendingCandidateID.map { "ai-" + $0.uuidString.lowercased() } ?? "ai"
            item.result = try await editor.gradePhoto(source, job: directory.appendingPathComponent(jobName, isDirectory: true), context: context, priority: position(of: item.id), progress: { [weak self] title, floor, ceiling in
                self?.stage(itemID, title, floor, ceiling)
            })
            let candidate = AIEditingBatch.Candidate(id: item.pendingCandidateID ?? UUID(), result: item.result!,
                instruction: item.pendingInstruction ?? "", parentID: item.selectedCandidateID,
                preferences: item.preferences ?? "", preferenceRevision: item.preferenceRevision ?? 0,
                batchInstruction: item.batchInstruction ?? "")
            item.candidates = (item.candidates ?? []) + [candidate]
            if item.result?.isSelectable == true { item.selectedCandidateID = candidate.id }
            item.result = item.candidates?.first { $0.id == item.selectedCandidateID }?.result
            item.pendingInstruction = nil; item.pendingCandidateID = nil
            item.phase = .review
        case .uploading:
            guard item.confirmedAt != nil else { item.phase = .review; return }
            stage(item.id, "调色已完成，等待保存", 0.85, 0.85)
            try await acquire("upload", itemID: item.id, limit: limits.uploads)
            defer { gates["upload"]?.remove(item.id) }
            stage(item.id, "调色已完成，准备保存到 NAS", 0.85, 0.88)
            let state = try await client.editState(assetID: item.assetID)
            if state.lastRequestID == item.id.uuidString.lowercased() { item.phase = .done; return }
            guard state.revision == sourceState.revision else { throw AIEditingFailure("照片已被其它客户端修改，本机调色结果已保留，未覆盖 NAS 照片。请先核对图库中的最新版本。") }
            if item.selectedCandidateID == nil {
                _ = try await client.confirmOriginalEdit(assetID: item.assetID, requestID: item.id,
                    expectedRevision: sourceState.revision, metadata: try editMetadata(item))
                item.phase = .done
                return
            }
            if let result = item.result, result.isSelectable, result.fullSize == nil || result.xmp == nil {
                item.result = try await editor.completeReviewResult(result, source: source, priority: position(of: item.id))
            }
            guard let result = item.result, let full = result.fullSize, let recipe = result.recipeJSON, let xmp = result.xmp else {
                throw AIEditingFailure("完整调色结果或配方缺失。")
            }
            guard FileManager.default.fileExists(atPath: full.path) else {
                item.phase = .review
                throw AIEditingFailure("本机完整调色图已丢失；配方和意见仍在。请继续调色重新生成一版，再确认发布。")
            }
            stage(item.id, "生成展示图和缩略图", 0.87, 0.90)
            let files = try await editor.withRenderSlot(priority: position(of: item.id)) {
                try await AIEditingImages.derivatives(from: full, directory: directory)
            }
            let upload = try await client.prepareEditUploads(assetID: item.assetID, requestID: item.id)
            guard Set(upload.objects.map(\.role)) == Set(files.keys), upload.objects.count == 3 else { throw KeepsAPIError.invalidResponse }
            var outputs: [KeepsEditOutput] = []
            for (index, target) in upload.objects.enumerated() {
                let names = ["standard": "全尺寸展示图", "thumbnail": "缩略图", "browse": "浏览预览"]
                stage(item.id, "保存到 NAS：\(names[target.role] ?? target.role)（\(index + 1)/3）", 0.90 + Double(index) * 0.025, 0.925 + Double(index) * 0.025)
                try Task.checkCancellation()
                let file = files[target.role]!
                let info = try await AIEditingImages.inspect(file, image: true)
                try await client.uploadEditImage(target: target, file: file)
                outputs.append(.init(role: target.role, objectRef: target.objectRef, contentHash: info.hash,
                    width: info.width, height: info.height, sizeBytes: info.size))
            }
            try Task.checkCancellation()
            stage(item.id, "NAS 正在校验并保存调色结果", 0.98, 0.995)
            _ = try await client.commitEdit(assetID: item.assetID, edit: .init(requestID: item.id.uuidString.lowercased(),
                expectedRevision: sourceState.revision, negativeContentHash: hash,
                algorithmVersion: "keeps-ai-v1", rendererVersion: "darktable-5.6.2", outputs: outputs,
                recipe: .init(recipeJSON: recipe, xmp: xmp, metadata: try editMetadata(item))))
            item.phase = .done
        case .preparing, .discarding, .done, .review: break
        }
    }

    static func isTransient(_ error: Error) -> Bool {
        if let failure = error as? AIEditingFailure { return failure.retryable }
        if let error = error as? URLError { return error.code != .cancelled }
        if case KeepsAPIError.http(let code, _) = error { return code >= 500 || code == 408 || code == 429 }
        return false
    }
}
