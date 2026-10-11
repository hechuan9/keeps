import Foundation
import ImageIO
import KeepsAPI
import SQLite3
import Testing
@testable import PhotoAssetManager

@MainActor struct AIEditingBatchTests {
    @Test func restartClearsPhotoHistoryAndUsesFreshJob() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldID = UUID()
        let result = AIGradeResult(status: "needs_review", reason: "旧意见")
        let item = AIEditingBatch.Item(id: UUID(), assetID: UUID(), name: "test.arw", phase: .review,
            result: result, failure: "失败", candidates: [.init(id: oldID, result: result, instruction: "旧要求", parentID: nil)],
            selectedCandidateID: oldID, pendingInstruction: "再暖些", pendingCandidateID: oldID)
        let database = try AIEditingDatabase(root: root)
        try database.save(batch: .init(id: UUID(), baseURL: "https://test.invalid", libraryID: "test", items: [item]), preferences: .init(text: "自然", revision: 2))
        let store = AIEditingBatchStore(root: root)
        #expect(store.restartItem(itemID: item.id))
        let restarted = try #require(database.load()?.batch?.items.first)
        #expect(restarted.id == item.id)
        #expect(restarted.phase == .preparing)
        #expect(restarted.result == nil && (restarted.candidates ?? []).isEmpty)
        #expect(restarted.selectedCandidateID == nil && restarted.pendingInstruction == nil)
        #expect(restarted.failure == nil)
        #expect(restarted.pendingCandidateID != nil && restarted.pendingCandidateID != oldID)
        #expect(store.preferencesText == "自然")
    }

    @Test func retryOnlyResumesChosenPhotoAndPreservesPendingRequest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let pendingID = UUID()
        let first = AIEditingBatch.Item(id: UUID(), assetID: UUID(), name: "first.arw", phase: .review,
            failure: "工具无响应", pendingInstruction: "柔和一些", pendingCandidateID: pendingID)
        let second = AIEditingBatch.Item(id: UUID(), assetID: UUID(), name: "second.arw", phase: .grading, failure: "等待重试")
        let database = try AIEditingDatabase(root: root)
        try database.save(batch: .init(id: UUID(), baseURL: "https://test.invalid", libraryID: "test", items: [first, second]), preferences: .init(text: "自然", revision: 1))
        let store = AIEditingBatchStore(root: root)
        store.retryItem(itemID: first.id)
        let items = try #require(database.load()?.batch?.items)
        #expect(items[0].phase == .grading)
        #expect(items[0].failure == nil)
        #expect(items[0].pendingInstruction == "柔和一些")
        #expect(items[0].pendingCandidateID == pendingID)
        #expect(items[1].failure == "等待重试")
    }

    @Test func preferenceCandidatesRequireConfirmationAndSurviveWorkspaceCompletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try AIEditingDatabase(root: root)
        let result = AIGradeResult(status: "selected", reason: "完成", preferenceSuggestions: ["人像保留自然肤色", "避免过强锐化"])
        let candidate = AIEditingBatch.Candidate(id: UUID(), result: result, instruction: "肤色不要偏橙", parentID: nil)
        let item = AIEditingBatch.Item(id: UUID(), assetID: UUID(), name: "portrait.arw", phase: .done,
            candidates: [candidate], preferences: "自然风格", preferenceRevision: 2)
        let manifest = AIEditingBatch(id: UUID(), baseURL: "https://preferences.invalid", libraryID: "test", items: [item])
        try database.save(batch: manifest, preferences: .init(text: "自然风格", revision: 2))
        let store = AIEditingBatchStore(root: root)
        #expect(store.preferenceSuggestions.count == 2)
        #expect(store.preferencesText == "自然风格")
        let first = try #require(store.preferenceSuggestions.first)
        #expect(store.acceptPreferenceSuggestion(id: first.id, text: "人像保留自然肤色层次"))
        #expect(store.preferencesText == "自然风格\n人像保留自然肤色层次")
        #expect(store.batch?.items[0].preferences == "自然风格")
        #expect(store.batch?.items[0].preferenceRevision == 2)
        store.closeCompletedWorkspace()
        let restored = AIEditingBatchStore(root: root)
        #expect(restored.batch?.items.isEmpty == true)
        #expect(restored.preferenceSuggestions.map(\.text) == ["避免过强锐化"])
        #expect(restored.preferencesText == "自然风格\n人像保留自然肤色层次")
        #expect(try database.load()?.preferences.revision == 3)
        #expect(restored.dismissPreferenceSuggestion(id: restored.preferenceSuggestions[0].id))
        #expect(AIEditingBatchStore(root: root).preferenceSuggestions.isEmpty)
    }

    @Test func jsonMigrationIsAtomicAndOnlyRunsOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacy = AIEditingBatch(id: UUID(), baseURL: "https://migration.invalid", libraryID: "test",
            items: [.init(id: UUID(), assetID: UUID(), name: "old.jpg", phase: .review)])
        let manifest = root.appendingPathComponent("batch.json"), preferences = root.appendingPathComponent("preferences.json")
        let original = try JSONEncoder().encode(legacy)
        try original.write(to: manifest)
        try Data("broken".utf8).write(to: preferences)
        let failed = AIEditingBatchStore(root: root)
        #expect(failed.errorMessage != nil)
        #expect(try AIEditingDatabase(root: root).load() == nil)
        try JSONEncoder().encode(AIEditingPreferences(text: "暖色", revision: 4)).write(to: preferences)
        let migrated = AIEditingBatchStore(root: root)
        #expect(migrated.errorMessage == nil)
        #expect(migrated.batch?.id == legacy.id)
        #expect(migrated.batch?.items.first?.id == legacy.items[0].id)
        #expect(migrated.preferencesText == "暖色")
        #expect(await migrated.savePreferences(text: "自然"))
        migrated.dismiss()
        #expect(try Data(contentsOf: manifest) == original)
        try Data("invalid legacy backup".utf8).write(to: manifest)
        try Data("invalid legacy backup".utf8).write(to: preferences)
        let restored = AIEditingBatchStore(root: root)
        #expect(restored.errorMessage == nil)
        #expect(restored.batch == nil)
        #expect(restored.preferencesText == "自然")
        #expect(try AIEditingDatabase(root: root).load()?.preferences.revision == 5)
    }

    @Test func failedDecisionTransactionRestoresVisiblePhotoAndDoesNotPublish() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try AIEditingDatabase(root: root)
        let item = AIEditingBatch.Item(id: UUID(), assetID: UUID(), name: "ready.jpg", phase: .review)
        let batch = AIEditingBatch(id: UUID(), baseURL: "https://transaction.invalid", libraryID: "test", items: [item])
        try database.save(batch: batch, preferences: .init(text: "", revision: 0))
        let store = AIEditingBatchStore(root: root)
        try sqlite(root: root, sql: "CREATE TRIGGER fail_decision BEFORE UPDATE ON items BEGIN SELECT RAISE(ABORT,'simulated disk write failure'); END;")
        store.choose(itemID: item.id, candidateID: nil)
        #expect(store.errorDetails?.contains("simulated disk write failure") == true)
        #expect(!store.isRunning)
        #expect(store.workspaceItems.count == 1)
        #expect(store.batch?.items.first?.phase == .review)
        #expect(store.batch?.items.first?.confirmedAt == nil)
        #expect(try database.load()?.batch?.items.first?.phase == .review)
    }

    private func sqlite(root: URL, sql: String) throws {
        var connection: OpaquePointer?
        guard sqlite3_open(root.appendingPathComponent("workspace.sqlite").path, &connection) == SQLITE_OK else {
            throw AIEditingFailure("测试数据库无法打开")
        }
        defer { sqlite3_close(connection) }
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
            throw AIEditingFailure(String(cString: sqlite3_errmsg(connection)))
        }
    }

    @Test func freshGradingStartsFromNegativeAndRefinementUsesSelectedRecipe() {
        let recipe = KeepsEditRecipe(recipeJSON: "published recipe", xmp: "published xmp")
        var item = AIEditingBatch.Item(id: UUID(), assetID: UUID(), name: "photo.arw",
            source: .init(negativeContentHash: "negative", revision: 3, hasEdit: true, sourceAvailable: true, recipe: recipe))
        #expect(AIEditingBatchStore.gradingContext(for: item).baseRecipeJSON == nil)
        let candidate = AIEditingBatch.Candidate(id: UUID(), result: .init(status: "selected", reason: "", recipeJSON: "candidate recipe"), instruction: "", parentID: nil)
        item.candidates = [candidate]
        item.selectedCandidateID = candidate.id
        #expect(AIEditingBatchStore.gradingContext(for: item).baseRecipeJSON == "candidate recipe")
        item.selectedCandidateID = nil
        #expect(AIEditingBatchStore.gradingContext(for: item).baseRecipeJSON == nil)
    }

    @Test func priorityHeapUsesCurrentRowOrderInsteadOfArrivalOrder() {
        let top = UUID(), middle = UUID(), bottom = UUID()
        var queue = AIEditingPriorityQueue()
        queue.insert(bottom, position: 2)
        queue.insert(middle, position: 1)
        queue.insert(top, position: 0)
        #expect(queue.pop() == top)
        queue.updateOrder([bottom, middle])
        #expect(queue.pop() == bottom)
        #expect(queue.pop() == middle)
        #expect(queue.pop() == nil)
        queue.insert(bottom, position: 2)
        queue.insert(top, position: 0)
        queue.remove(top)
        #expect(queue.pop() == bottom)
    }

    @Test func upstreamPhotoHasPriorityEvenWhenLowerPhotoIsReadyForAI() {
        let first = AIEditingBatch.Item(id: UUID(), assetID: UUID(), name: "top", phase: .downloading)
        let second = AIEditingBatch.Item(id: UUID(), assetID: UUID(), name: "lower", phase: .grading)
        var items = [first, second]
        #expect(AIEditingBatchStore.hasPriority(first.id, for: "download", items: items))
        #expect(!AIEditingBatchStore.hasPriority(second.id, for: "ai", items: items))
        #expect(AIEditingBatchStore.hasPriority(second.id, for: "ai", items: [second]))
        items[0].phase = .grading
        #expect(AIEditingBatchStore.hasPriority(second.id, for: "ai", items: items, holders: [first.id]))
        items[0].failure = "下载失败"
        #expect(AIEditingBatchStore.hasPriority(second.id, for: "ai", items: items))
        items[0].failure = nil
        items[0].phase = .uploading
        #expect(AIEditingBatchStore.hasPriority(second.id, for: "ai", items: items))
    }

    @Test func legacyNeedsReviewCandidateCanBeSelectedWithoutRegrading() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let job = root.appendingPathComponent("ai"), render = job.appendingPathComponent("render")
        try FileManager.default.createDirectory(at: render, withIntermediateDirectories: true)
        let preview = render.appendingPathComponent("candidate-preview.jpg")
        let before = root.appendingPathComponent("before.heic")
        try Data("candidate".utf8).write(to: preview)
        try Data("current display".utf8).write(to: before)
        try Data("{\"status\":\"needs_review\",\"candidateID\":\"candidate\",\"reason\":\"请人工检查\"}".utf8).write(to: job.appendingPathComponent("result.json"))
        let state: [String: Any] = ["candidates": [["id": "candidate", "recipe": Data("{\"exposureEV\":0.5}".utf8).base64EncodedString()]]]
        try JSONSerialization.data(withJSONObject: state).write(to: render.appendingPathComponent("candidates.json"))
        let candidate = AIEditingBatch.Candidate(id: UUID(), result: .init(status: "needs_review", reason: "请人工检查", preview: preview), instruction: "", parentID: nil)
        let item = AIEditingBatch.Item(id: UUID(), assetID: UUID(), name: "DSC02950.ARW", phase: .review,
            candidates: [candidate], originalPreview: before)
        let manifest = AIEditingBatch(id: UUID(), baseURL: "https://review.invalid", libraryID: "test", items: [item])
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("batch.json"))
        let store = AIEditingBatchStore(root: root)
        #expect(store.batch?.items[0].candidates?[0].result.isSelectable == true)
        store.selectCandidate(itemID: item.id, candidateID: candidate.id)
        #expect(store.batch?.items[0].selectedCandidateID == candidate.id)
        #expect(store.canPublish(store.batch!.items[0]))
        #expect(!store.isRunning)
        #expect(AIEditingBatchStore(root: root).batch?.items[0].result?.recipeJSON == "{\"exposureEV\":0.5}")
    }

    @Test func recoveryWaitsForPendingPhotoRecycling() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let batch = AIEditingBatch(id: UUID(), baseURL: "https://batch.invalid", libraryID: "test",
            items: [.init(id: UUID(), assetID: UUID(), name: "photo.jpg")])
        try JSONEncoder().encode(batch).write(to: root.appendingPathComponent("batch.json"))
        let library = LibraryStore(configuration: .init(baseURL: URL(string: "https://batch.invalid")!, libraryID: "test"),
            loadSavedSettings: false, preferences: UserDefaults(suiteName: UUID().uuidString)!)
        library.rejectedTrash = PendingRejectedTrash(id: UUID(), count: 1, baseURL: "https://batch.invalid", libraryID: "test")
        let restored = AIEditingBatchStore(root: root)
        restored.restore(library: library)
        #expect(!library.isAIEditingBlocking)
        #expect(!restored.isRunning)
        library.rejectedTrash = nil
        restored.restore(library: library)
        #expect(!library.isAIEditingBlocking)
        #expect(restored.isAwaitingConfirmation)
    }

    @Test func confirmationFreezesSelectionAndSurvivesRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = UserDefaults(suiteName: UUID().uuidString)!
        let library = LibraryStore(configuration: .init(baseURL: URL(string: "https://batch.invalid")!, libraryID: "test"), loadSavedSettings: false, preferences: preferences)
        let selected = Set([UUID(), UUID(), UUID()])
        library.selectedIDs = selected
        let batch = AIEditingBatchStore(root: root)
        batch.prepare(library: library)
        #expect(batch.isAwaitingConfirmation)
        #expect(batch.totalCount == 3)
        #expect(!library.isOperationBlocking)
        library.selectedIDs = [UUID()]
        #expect(Set(batch.batch!.items.map(\.assetID)) == selected)
        let restored = AIEditingBatchStore(root: root)
        #expect(restored.totalCount == 3)
        #expect(restored.isAwaitingConfirmation)
        #expect(restored.batch?.items.map(\.id) == batch.batch?.items.map(\.id))
        restored.restore(library: library)
        #expect(!restored.isRunning)
        restored.cancel()
        #expect(restored.isFinished)
        #expect(!library.isOperationBlocking)
        restored.dismiss()
        #expect(!library.isOperationBlocking)
        #expect(AIEditingBatchStore(root: root).batch == nil)
    }

    @Test func appendingSelectionDeduplicatesAndPreservesWorkspaceIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(configuration: .init(baseURL: URL(string: "https://append.invalid")!, libraryID: "test"), loadSavedSettings: false,
            preferences: UserDefaults(suiteName: UUID().uuidString)!)
        let first = UUID(), second = UUID()
        let store = AIEditingBatchStore(root: root)
        library.selectedIDs = [first]
        store.prepare(library: library)
        let identity = store.batch?.id
        let itemIdentity = store.batch?.items.first?.id
        library.selectedIDs = [first, second]
        store.prepare(library: library)
        #expect(store.batch?.id == identity)
        #expect(store.batch?.items.count == 2)
        #expect(store.batch?.items.first?.id == itemIdentity)
        let restored = AIEditingBatchStore(root: root)
        #expect(restored.batch?.id == identity)
        #expect(Set(restored.batch!.items.map(\.assetID)) == [first, second])
    }

    @Test func completingWorkspaceKeepsIdentityAndLocalPreferencesForNextSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let completed = AIEditingBatch(id: UUID(), baseURL: "https://local.invalid", libraryID: "test",
            items: [.init(id: UUID(), assetID: UUID(), name: "done.jpg", phase: .done)])
        try JSONEncoder().encode(completed).write(to: root.appendingPathComponent("batch.json"))
        let store = AIEditingBatchStore(root: root)
        #expect(await store.savePreferences(text: "保留现场氛围"))
        store.closeCompletedWorkspace()
        #expect(store.batch?.id == completed.id)
        #expect(store.batch?.items.isEmpty == true)
        let restored = AIEditingBatchStore(root: root)
        #expect(restored.batch?.id == completed.id)
        #expect(restored.preferencesText == "保留现场氛围")
        let library = LibraryStore(configuration: .init(baseURL: URL(string: completed.baseURL)!, libraryID: "test"), loadSavedSettings: false,
            preferences: UserDefaults(suiteName: UUID().uuidString)!)
        library.selectedIDs = [UUID()]
        restored.prepare(library: library)
        #expect(restored.batch?.id == completed.id)
        #expect(restored.batch?.items.count == 1)
    }

    @Test func selectionCanAppendWhileAnotherPhotoIsProcessing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [WaitingBatchProtocol.self]
        let library = LibraryStore(configuration: .init(baseURL: URL(string: "https://append-running.invalid")!, libraryID: "test"),
            session: URLSession(configuration: config), loadSavedSettings: false,
            preferences: UserDefaults(suiteName: UUID().uuidString)!)
        let store = AIEditingBatchStore(root: root)
        let first = UUID(), second = UUID()
        library.selectedIDs = [first]
        store.prepare(library: library)
        store.start()
        for _ in 0..<200 where store.activeCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(store.isRunning)
        let identity = store.batch?.id
        library.selectedIDs = [first, second]
        store.prepare(library: library)
        #expect(store.batch?.id == identity)
        #expect(store.batch?.items.count == 2)
        for _ in 0..<200 where store.activeCount < 2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(store.activeCount == 2)
        store.cancel()
        for _ in 0..<200 where store.isRunning { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!store.isRunning)
        #expect(AIEditingBatchStore(root: root).batch?.items.count == 2)
    }

    @Test func preferencesStayLocalAndEachPhotoKeepsItsStartSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalSnapshotProtocol.self]
        let library = LibraryStore(configuration: .init(baseURL: URL(string: "https://local.invalid")!, libraryID: "test"),
            session: URLSession(configuration: configuration), loadSavedSettings: false,
            preferences: UserDefaults(suiteName: UUID().uuidString)!)
        let store = AIEditingBatchStore(root: root)
        #expect(await store.savePreferences(text: "自然肤色"))
        library.selectedIDs = [UUID()]
        store.prepare(library: library)
        store.batchInstruction = "保留暖光"
        store.start()
        for _ in 0..<200 where store.isRunning { try await Task.sleep(for: .milliseconds(5)) }
        #expect(store.batch?.items.first?.preferences == "自然肤色")
        #expect(store.batch?.items.first?.batchInstruction == "保留暖光")
        #expect(await store.savePreferences(text: "低饱和"))
        let identity = store.batch?.id
        library.selectedIDs = [UUID()]
        store.prepare(library: library)
        store.batchInstruction = "提亮阴影"
        store.start()
        for _ in 0..<200 where store.isRunning { try await Task.sleep(for: .milliseconds(5)) }
        #expect(store.batch?.id == identity)
        #expect(store.batch?.items.first?.preferences == "自然肤色")
        #expect(store.batch?.items.last?.preferences == "低饱和")
        #expect(store.batch?.items.last?.batchInstruction == "提亮阴影")
        let restored = AIEditingBatchStore(root: root)
        #expect(restored.preferencesText == "低饱和")
        #expect(restored.batch?.items.first?.preferences == "自然肤色")
    }

    @Test func importingOrOtherOperationCannotStartBatch() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(configuration: .init(baseURL: URL(string: "https://batch.invalid")!, libraryID: "test"), loadSavedSettings: false)
        library.selectedIDs = [UUID()]
        let batch = AIEditingBatchStore(root: root)
        library.openImportWindows = [UUID()]
        batch.prepare(library: library)
        #expect(batch.batch == nil)
        library.openImportWindows = []
        library.isAISettingsBusy = true
        batch.prepare(library: library)
        #expect(batch.batch == nil)
    }

    @Test func legacyUnconfirmedUploadReturnsToReviewWithIdentityPreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let item = AIEditingBatch.Item(id: UUID(), assetID: UUID(), name: "public.jpg", phase: .uploading,
            source: .init(negativeContentHash: String(repeating: "a", count: 64), revision: 12, hasEdit: false, sourceAvailable: true),
            result: .init(status: "selected", reason: "verified", fullSize: root.appendingPathComponent("full.jpg"), recipeJSON: "{}", xmp: "<xmp/>"))
        var batch = AIEditingBatch(id: UUID(), baseURL: "https://batch.invalid", libraryID: "test", items: [item])
        batch.confirmed = true
        try JSONEncoder().encode(batch).write(to: root.appendingPathComponent("batch.json"))
        let restored = AIEditingBatchStore(root: root)
        #expect(restored.batch?.items[0].id == item.id)
        #expect(restored.batch?.items[0].phase == .review)
        #expect(restored.batch?.items[0].source?.revision == 12)
        #expect(restored.batch?.items[0].result?.recipeJSON == "{}")
        #expect(!restored.isAwaitingConfirmation)
        #expect(restored.isFinished)
    }

    @Test func createsAllThreeDisplaySizesFromPublicImage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/runtime-sample/sample.jpg")
        let before = try await AIEditingImages.inspect(source, image: true)
        let outputs = try await AIEditingImages.derivatives(from: source, directory: root)
        #expect(Set(outputs.keys) == ["standard", "thumbnail", "browse"])
        for (role, maximum) in [("standard", 1280), ("thumbnail", 512), ("browse", 64)] {
            let info = try await AIEditingImages.inspect(outputs[role]!, image: true)
            #expect(max(info.width, info.height) == maximum)
            #expect(info.size > 0)
            #expect(info.hash.count == 64)
        }
        #expect(try await AIEditingImages.inspect(source, image: false).hash == before.hash)
    }

    @Test func restartAfterLostCommitResponseDoesNotRegradeOrReupload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent("runtime")
        for name in ["codex", "codex-code-mode-host", "keeps-color-mcp", "darktable.app/Contents/MacOS/darktable-cli"] {
            let url = runtime.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 91\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        try Data("test".utf8).write(to: runtime.appendingPathComponent("SKILL.md"))
        let home = root.appendingPathComponent("editor/codex")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let payload = try JSONSerialization.data(withJSONObject: ["email": "test@example.com"]).base64EncodedString()
        try JSONSerialization.data(withJSONObject: ["tokens": ["id_token": "header.\(payload).signature"]]).write(to: home.appendingPathComponent("auth.json"))
        let editor = AIEditingSettingsStore(root: home.deletingLastPathComponent(), runtime: runtime, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        editor.expectedEmail = "test@example.com"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CommittedBatchProtocol.self]
        let library = LibraryStore(configuration: .init(baseURL: URL(string: "https://committed.invalid")!, libraryID: "test"), session: URLSession(configuration: configuration), loadSavedSettings: false)
        let id = UUID()
        let item = AIEditingBatch.Item(id: id, assetID: id, name: "sample.jpg", phase: .uploading,
            source: .init(negativeContentHash: String(repeating: "a", count: 64), revision: 1, hasEdit: false,
                          sourceFilename: "sample.jpg", sourceAvailable: true), confirmedAt: "2026-10-08T12:00:00Z")
        var manifest = AIEditingBatch(id: UUID(), baseURL: "https://committed.invalid", libraryID: "test", items: [item])
        manifest.confirmed = true
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("batch.json"))
        let restored = AIEditingBatchStore(root: root, editor: editor)
        restored.restore(library: library)
        for _ in 0..<200 where restored.isRunning { try await Task.sleep(for: .milliseconds(5)) }
        #expect(restored.errorMessage == nil)
        #expect(restored.isFinished)
        #expect(restored.completedCount == 1)
        #expect(restored.batch?.items[0].phase == .done)
        #expect(!library.isOperationBlocking)

        let rejectedJob = root.appendingPathComponent("rejected")
        try FileManager.default.createDirectory(at: rejectedJob, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: rejectedJob.appendingPathComponent("result.json"))
        let source = root.appendingPathComponent("sample.jpg")
        try Data([0xff, 0xd8, 0xff, 0xd9]).write(to: source)
        do {
            _ = try await editor.gradePhoto(source, job: rejectedJob)
            Issue.record("The deliberately failing fixture executable must be invoked on retry")
        } catch { #expect(error.localizedDescription.contains("Codex 版本")) }
        #expect(!FileManager.default.fileExists(atPath: rejectedJob.appendingPathComponent("result.json").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: rejectedJob.path).contains { $0.hasPrefix("rejected-result-") })
    }

    @Test func savedResultCanResumeWithoutAIAccountAndProgressStopsOnCancel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let full = root.appendingPathComponent("completed.jpg")
        try Data("preserved result".utf8).write(to: full)
        let item = AIEditingBatch.Item(id: UUID(), assetID: UUID(), name: "public.jpg", phase: .uploading,
            source: .init(negativeContentHash: String(repeating: "a", count: 64), revision: 1, hasEdit: false, sourceFilename: "public.jpg", sourceAvailable: true),
            result: .init(status: "selected", reason: "done", fullSize: full, recipeJSON: "{}", xmp: "xmp"), confirmedAt: "2026-10-08T12:00:00Z")
        var state = AIEditingBatch(id: UUID(), baseURL: "https://waiting.invalid", libraryID: "test", items: [item])
        state.confirmed = true
        try JSONEncoder().encode(state).write(to: root.appendingPathComponent("batch.json"))
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [WaitingBatchProtocol.self]
        let library = LibraryStore(configuration: .init(baseURL: URL(string: state.baseURL)!, libraryID: "test"), session: URLSession(configuration: config), loadSavedSettings: false, preferences: UserDefaults(suiteName: UUID().uuidString)!)
        let editor = AIEditingSettingsStore(root: root.appendingPathComponent("no-account"), runtime: root, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let store = AIEditingBatchStore(root: root, editor: editor)
        store.restore(library: library)
        let deadline = Date().addingTimeInterval(3)
        while !store.activeItems.contains(where: { $0.ceiling > $0.progress }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.isRunning && store.isAwaitingUpload)
        #expect(store.errorMessage == nil)
        #expect(store.pendingResultURL == full)
        let first = store.overallProgress
        store.tickProgress(); store.tickProgress()
        #expect(store.overallProgress == first)
        #expect(store.overallProgress < 1)
        store.cancel()
        for _ in 0..<100 where store.isRunning { try await Task.sleep(for: .milliseconds(5)) }
        let paused = store.overallProgress
        store.tickProgress()
        #expect(store.overallProgress == paused)
        #expect(store.batch?.items.first?.phase == .uploading)
        #expect(try Data(contentsOf: full) == Data("preserved result".utf8))
        store.retry()
        let resumeDeadline = Date().addingTimeInterval(3)
        while store.activeCount == 0, store.isRunning, Date() < resumeDeadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(store.isRunning)
        #expect(store.batch?.cancelled == false)
        #expect(store.isAwaitingUpload)
        store.cancel()
        for _ in 0..<100 where store.isRunning { try await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func concurrentUploadsRespectLimitAndOneFailureDoesNotBlockOthers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let failedID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let ids = [failedID] + (0..<5).map { _ in UUID() }
        let items = ids.map { id in
            AIEditingBatch.Item(id: id, assetID: id, name: "sample.jpg", phase: .uploading,
                source: .init(negativeContentHash: String(repeating: "a", count: 64), revision: 1,
                              hasEdit: false, sourceFilename: "sample.jpg", sourceAvailable: true), confirmedAt: "2026-10-08T12:00:00Z")
        }
        var manifest = AIEditingBatch(id: UUID(), baseURL: "https://parallel.invalid", libraryID: "test", items: items)
        manifest.confirmed = true
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("batch.json"))
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        var limits = AIEditingLimits(); limits.photos = 4; limits.uploads = 2
        limits.save(defaults: defaults)
        let editor = AIEditingSettingsStore(root: root.appendingPathComponent("editor"), runtime: root, defaults: defaults)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ConcurrentBatchProtocol.self]
        let library = LibraryStore(configuration: .init(baseURL: URL(string: manifest.baseURL)!, libraryID: "test"),
            session: URLSession(configuration: config), loadSavedSettings: false, preferences: defaults)
        ConcurrentBatchProtocol.reset()
        let store = AIEditingBatchStore(root: root, editor: editor)
        store.restore(library: library)
        var peakPhotos = 0
        for _ in 0..<400 where store.isRunning {
            peakPhotos = max(peakPhotos, store.activeCount)
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!store.isRunning)
        #expect(store.completedCount == 5)
        #expect(store.failedItems.map(\.id) == [failedID])
        #expect(ConcurrentBatchProtocol.peak == 2)
        #expect(peakPhotos == 4)
        #expect(store.batch?.items.allSatisfy { ($0.phaseSeconds?["uploading"] ?? 0) > 0 } == true)
        let restored = AIEditingBatchStore(root: root, editor: editor)
        #expect(restored.completedCount == 5)
        #expect(restored.failedItems.map(\.id) == [failedID])
    }

    @Test func candidateSelectionPersistsAndNeverPublishesBeforeConfirmation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = AIEditingBatch.Candidate(id: UUID(), result: .init(status: "selected", reason: "保留暖光", recipeJSON: "{}"), instruction: "", parentID: nil)
        let second = AIEditingBatch.Candidate(id: UUID(), result: .init(status: "selected", reason: "提亮人物", recipeJSON: "{}"), instruction: "人物亮一点", parentID: first.id)
        let item = AIEditingBatch.Item(id: UUID(), assetID: UUID(), name: "sample.jpg", phase: .review,
            result: second.result, candidates: [first, second], selectedCandidateID: second.id)
        var manifest = AIEditingBatch(id: UUID(), baseURL: "https://review.invalid", libraryID: "test", items: [item])
        manifest.confirmed = true
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("batch.json"))
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ReviewBatchProtocol.self]
        let library = LibraryStore(configuration: .init(baseURL: URL(string: manifest.baseURL)!, libraryID: "test"),
            session: URLSession(configuration: config), loadSavedSettings: false, preferences: UserDefaults(suiteName: UUID().uuidString)!)
        let store = AIEditingBatchStore(root: root)
        store.restore(library: library)
        store.restore(library: library)
        store.selectCandidate(itemID: item.id, candidateID: first.id)
        let restored = AIEditingBatchStore(root: root)
        #expect(restored.batch?.items[0].selectedCandidateID == first.id)
        #expect(restored.batch?.items[0].result?.reason == "保留暖光")
        #expect(restored.batch?.items[0].candidates?.count == 2)
        store.start()
        #expect(!store.isRunning)
        #expect(store.batch?.items[0].confirmedAt == nil)
        #expect(store.batch?.items[0].phase == .review)
        store.selectCandidate(itemID: item.id, candidateID: nil)
        #expect(AIEditingBatchStore(root: root).batch?.items[0].selectedCandidateID == nil)
        #expect(AIEditingBatchStore(root: root).batch?.items[0].result == nil)
        store.restore(library: library)
    }

    @Test func confirmingOriginalRecordsDecisionWithoutImageUpload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let candidate = AIEditingBatch.Candidate(id: UUID(), result: .init(status: "selected", reason: "保留现场氛围", recipeJSON: "{}"), instruction: "", parentID: nil)
        let item = AIEditingBatch.Item(id: UUID(), assetID: UUID(), name: "sample.jpg", phase: .review,
            source: .init(negativeContentHash: String(repeating: "a", count: 64), revision: 1, hasEdit: false, sourceFilename: "sample.jpg", sourceAvailable: true),
            candidates: [candidate])
        var manifest = AIEditingBatch(id: UUID(), baseURL: "https://original.invalid", libraryID: "test", items: [item])
        manifest.confirmed = true
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("batch.json"))
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [OriginalDecisionProtocol.self]
        let library = LibraryStore(configuration: .init(baseURL: URL(string: manifest.baseURL)!, libraryID: "test"),
            session: URLSession(configuration: config), loadSavedSettings: false, preferences: UserDefaults(suiteName: UUID().uuidString)!)
        let store = AIEditingBatchStore(root: root)
        store.restore(library: library)
        store.restore(library: library)
        OriginalDecisionProtocol.reset()
        store.publish(itemID: item.id)
        for _ in 0..<200 where store.isRunning { try await Task.sleep(for: .milliseconds(5)) }
        #expect(store.errorMessage == nil)
        #expect(store.batch?.items[0].phase == .done)
        #expect(OriginalDecisionProtocol.decisions == 1)
        #expect(store.batch?.items[0].confirmedAt != nil)
    }

    @Test func missingComparisonPreventsPublicationAndFailedBatchCanBeArchived() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let candidate = AIEditingBatch.Candidate(id: UUID(), result: .init(status: "selected", reason: "试调",
            fullSize: root.appendingPathComponent("missing.jpg")), instruction: "", parentID: nil)
        var item = AIEditingBatch.Item(id: UUID(), assetID: UUID(), name: "temporary.jpg", phase: .review)
        item.candidates = [candidate]; item.selectedCandidateID = candidate.id
        var batch = AIEditingBatch(id: UUID(), baseURL: "https://sample.invalid", libraryID: "test", items: [item])
        batch.confirmed = true
        try JSONEncoder().encode(batch).write(to: root.appendingPathComponent("batch.json"))
        let store = AIEditingBatchStore(root: root)
        #expect(!store.canPublish(item))
        store.archiveAndDismiss()
        #expect(store.batch == nil)
        let archive = root.appendingPathComponent("recovery-" + batch.id.uuidString + ".json")
        let recovered = try JSONDecoder().decode(AIEditingBatch.self, from: Data(contentsOf: archive))
        #expect(recovered.items[0].selectedCandidateID == candidate.id)
    }

    @Test func decisionsFinishWhileAnotherPhotoIsStillPreparing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let waitingID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let source = KeepsEditState(negativeContentHash: String(repeating: "a", count: 64), revision: 1,
            hasEdit: false, sourceFilename: "sample.jpg", sourceAvailable: true)
        let publish = AIEditingBatch.Item(id: UUID(), assetID: UUID(), name: "publish.jpg", phase: .review, source: source)
        let reject = AIEditingBatch.Item(id: UUID(), assetID: UUID(), name: "reject.jpg", phase: .review)
        var manifest = AIEditingBatch(id: UUID(), baseURL: "https://independent.invalid", libraryID: "test", items: [
            .init(id: waitingID, assetID: waitingID, name: "waiting.jpg"), publish, reject])
        manifest.confirmed = true
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("batch.json"))
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        var limits = AIEditingLimits(); limits.photos = 1
        limits.save(defaults: defaults)
        let editor = AIEditingSettingsStore(root: root.appendingPathComponent("editor"), runtime: root, defaults: defaults)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [IndependentDecisionProtocol.self]
        let library = LibraryStore(configuration: .init(baseURL: URL(string: manifest.baseURL)!, libraryID: "test"),
            session: URLSession(configuration: config), loadSavedSettings: false, preferences: defaults)
        let store = AIEditingBatchStore(root: root, editor: editor)
        store.restore(library: library)
        for _ in 0..<200 where store.activeCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(store.isRunning)
        #expect(store.canInteract(publish))
        store.choose(itemID: publish.id, candidateID: nil)
        #expect(!store.workspaceItems.contains { $0.id == publish.id })
        #expect(store.backgroundDecisionCount == 1)
        store.reject(itemID: publish.id)
        store.reject(itemID: reject.id)
        #expect(!store.workspaceItems.contains { $0.id == reject.id })
        #expect(store.backgroundDecisionCount == 2)
        store.publish(itemID: reject.id)
        for _ in 0..<200 where store.batch?.items.filter({ $0.phase == .done }).count != 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.isRunning)
        #expect(store.batch?.items[0].phase == .preparing)
        #expect(store.batch?.items[1].phase == .done)
        #expect(store.batch?.items[2].phase == .done)
        #expect(store.backgroundDecisionCount == 0)
        #expect(store.failedDecisionCount == 0)
        #expect(store.workspaceItems.map(\.id) == [waitingID])
        #expect(store.errorMessage == nil)
        store.cancel()
        for _ in 0..<200 where store.isRunning { try await Task.sleep(for: .milliseconds(5)) }
        let restored = AIEditingBatchStore(root: root, editor: editor)
        #expect(restored.batch?.items.filter { $0.phase == .done }.count == 2)
        #expect(restored.batch?.items[0].phase == .preparing)
    }

    @Test func failedBackgroundDecisionsReturnToWorkspaceAfterRestore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pending = AIEditingBatch.Item(id: UUID(), assetID: UUID(), name: "pending", phase: .uploading, confirmedAt: "confirmed")
        let failed = AIEditingBatch.Item(id: UUID(), assetID: UUID(), name: "failed", phase: .discarding, failure: "network failed", confirmedAt: "confirmed")
        let saved = AIEditingBatch(id: UUID(), baseURL: "https://independent.invalid", libraryID: "test", items: [pending, failed])
        try JSONEncoder().encode(saved).write(to: root.appendingPathComponent("batch.json"))
        let store = AIEditingBatchStore(root: root)
        #expect(store.workspaceItems.map(\.id) == [failed.id])
        #expect(store.backgroundDecisionCount == 1)
        #expect(store.failedDecisionCount == 1)
    }

    @Test func historySummarizesRasterBytesWithoutChangingCurrentRecipe() throws {
        let encoded = Data(repeating: 42, count: 512 * 1024).base64EncodedString()
        let recipe = "{\"adjustments\":[{\"mask\":{\"raster\":{\"pngBase64\":\"\(encoded)\",\"invert\":true}},\"exposureEV\":0.4}]}"
        let summary = try #require(try AIEditingBatchStore.historyRecipe(recipe))
        #expect(summary.utf8.count < 1024)
        #expect(!summary.contains("pngBase64"))
        #expect(summary.contains("pngSHA256"))
        #expect(summary.contains("524288"))
        #expect(summary.contains("0.4"))
        #expect(summary.contains("true"))
        #expect(recipe.contains(encoded))
    }

    @Test func onlyTransientNetworkErrorsRetryAutomatically() {
        #expect(AIEditingBatchStore.isTransient(URLError(.notConnectedToInternet)))
        #expect(AIEditingBatchStore.isTransient(KeepsAPIError.http(503, "offline")))
        #expect(!AIEditingBatchStore.isTransient(KeepsAPIError.http(409, "conflict")))
        #expect(!AIEditingBatchStore.isTransient(KeepsAPIError.http(401, "login")))
        #expect(!AIEditingBatchStore.isTransient(URLError(.cancelled)))
    }
}

private final class CommittedBatchProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if respondToWorkspaceRequest(self) { return }
        guard request.httpMethod == "GET", request.url?.lastPathComponent == "edit" else {
            Issue.record("A committed item must not start new grading or upload requests")
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let id = request.url!.deletingLastPathComponent().lastPathComponent.lowercased()
        let state = KeepsEditState(negativeContentHash: String(repeating: "a", count: 64), revision: 2, hasEdit: true, sourceAvailable: true, lastRequestID: id)
        do {
            let data = try JSONEncoder().encode(state)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private final class WaitingBatchProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { _ = respondToWorkspaceRequest(self) }
    override func stopLoading() {}
}

private final class ConcurrentBatchProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var active = 0
    nonisolated(unsafe) private static var maximum = 0
    static var peak: Int { lock.withLock { maximum } }
    static func reset() { lock.withLock { active = 0; maximum = 0 } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if respondToWorkspaceRequest(self) { return }
        Self.lock.withLock { Self.active += 1; Self.maximum = max(Self.maximum, Self.active) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [self] in
            Self.lock.withLock { Self.active -= 1 }
            let id = request.url!.deletingLastPathComponent().lastPathComponent.lowercased()
            let failed = id == "00000000-0000-0000-0000-000000000001"
            let state = KeepsEditState(negativeContentHash: String(repeating: "a", count: 64), revision: 2,
                hasEdit: true, sourceAvailable: true, lastRequestID: id)
            let data = failed ? Data("conflict".utf8) : try! JSONEncoder().encode(state)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: failed ? 409 : 200,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

private func respondToWorkspaceRequest(_ handler: URLProtocol) -> Bool {
    if handler.request.url?.path.contains("/ai-editing/") == true {
        Issue.record("AI workspace and preferences must stay on this Mac")
        handler.client?.urlProtocol(handler, didFailWithError: URLError(.badURL))
        return true
    }
    if handler.request.url?.path.contains("/derivatives/") == true {
        respond(handler, data: Data("{\"downloadURL\":\"https://snapshot.invalid/comparison\",\"width\":10,\"height\":10,\"version\":\"display\"}".utf8))
        return true
    }
    if handler.request.url?.path == "/comparison" {
        respond(handler, data: Data("current displayed photo".utf8))
        return true
    }
    if handler.request.httpMethod == "GET", handler.request.url?.path.contains("/edit") != true {
        handler.client?.urlProtocol(handler, didFailWithError: URLError(.cancelled))
        return true
    }
    return false
}

private func respond(_ handler: URLProtocol, data: Data) {
    handler.client?.urlProtocol(handler, didReceive: HTTPURLResponse(url: handler.request.url!, statusCode: 200,
        httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
    handler.client?.urlProtocol(handler, didLoad: data)
    handler.client?.urlProtocolDidFinishLoading(handler)
}

private final class ReviewBatchProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard !respondToWorkspaceRequest(self) else { return }
        Issue.record("An unconfirmed review must not fetch, upload, or commit photo content")
        client?.urlProtocol(self, didFailWithError: URLError(.badURL))
    }
    override func stopLoading() {}
}

private final class OriginalDecisionProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0
    static var decisions: Int { lock.withLock { count } }
    static func reset() { lock.withLock { count = 0 } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if respondToWorkspaceRequest(self) { return }
        if request.httpMethod == "GET", request.url?.lastPathComponent == "edit" {
            let state = KeepsEditState(negativeContentHash: String(repeating: "a", count: 64), revision: 1, hasEdit: false, sourceAvailable: true)
            respond(self, data: try! JSONEncoder().encode(state))
        } else if request.httpMethod == "POST", request.url?.lastPathComponent == "decisions" {
            Self.lock.withLock { Self.count += 1 }
            let state = KeepsEditState(negativeContentHash: String(repeating: "a", count: 64), revision: 1, hasEdit: false, sourceAvailable: true)
            respond(self, data: try! JSONEncoder().encode(state))
        } else {
            Issue.record("Selecting the original must not generate or upload derivative images")
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
        }
    }
    override func stopLoading() {}
}

private final class IndependentDecisionProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if respondToWorkspaceRequest(self) { return }
        if request.url?.path.lowercased().contains("00000000-0000-0000-0000-000000000010") == true { return }
        if request.httpMethod == "PATCH" {
            let id = request.url!.lastPathComponent
            let json = """
                {"id":"\(id)","cameraMake":"","cameraModel":"","lensModel":"","originalFilename":"sample.jpg","contentFingerprint":"hash","metadataFingerprint":"meta","rating":0,"flagState":"rejected","tags":[],"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","trashed":false}
                """
            respond(self, data: Data(json.utf8))
        } else if request.url?.lastPathComponent == "edit" || request.url?.lastPathComponent == "decisions" {
            let state = KeepsEditState(negativeContentHash: String(repeating: "a", count: 64), revision: 1,
                hasEdit: false, sourceAvailable: true)
            respond(self, data: try! JSONEncoder().encode(state))
        } else {
            Issue.record("Decisions must only update a flag or confirm the selected version")
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
        }
    }
    override func stopLoading() {}
}

private final class LocalSnapshotProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if respondToWorkspaceRequest(self) { return }
        guard request.httpMethod == "GET", request.url?.lastPathComponent == "edit" else {
            Issue.record("Local workspaces must only read photo source information before confirmation")
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let state = KeepsEditState(negativeContentHash: nil, revision: 1, hasEdit: false, sourceAvailable: false)
        respond(self, data: try! JSONEncoder().encode(state))
    }
    override func stopLoading() {}
}
