import Combine
import CryptoKit
import Foundation
import ImageIO
import KeepsAPI
import UniformTypeIdentifiers

struct AICullingResult: Codable {
    struct Photo: Codable {
        let index: Int
        let recommended: Bool
        let reason: String
    }
    struct Group: Codable {
        let title: String
        let reason: String
        let photos: [Photo]
    }
    let groups: [Group]

    func validate(count: Int) throws {
        let indices = groups.flatMap { $0.photos.map(\.index) }
        guard count > 0, !groups.isEmpty, groups.allSatisfy({ !$0.photos.isEmpty }),
              indices.count == count, Set(indices) == Set(0..<count),
              groups.allSatisfy({ $0.photos.contains(where: \.recommended) }) else {
            throw AIEditingFailure("AI 分组遗漏、重复了照片或没有保留候选，请重新分析。")
        }
    }
}

@MainActor final class AICullingStore: ObservableObject {
    struct Session: Codable {
        var assets: [KeepsAsset]
        var instruction: String
        var offset = 0
        var groups: [AICullingResult.Group] = []
        var groupIndex = 0
        var kept: Set<Int> = []
        var completed = 0
        var pending: [Int: String] = [:]
        var confirming = false
        var sourcePath: String?
        var recursive: Bool?
        var preferences: String?
        var skippedCount: Int?

        var prompt: String {
            "个人长期偏好：\n" + (preferences ?? "") + "\n\n本次目录要求：\n" + instruction
        }
    }
    @Published private(set) var session: Session?
    @Published private(set) var busy = false
    @Published private(set) var paused = true
    @Published private(set) var preferences = "保留不同构图和有意义的瞬间；相似照片优先选自然、主体清楚的。"
    @Published private(set) var status = ""
    @Published private(set) var error: String?
    private(set) var directory: URL?
    private var task: Task<Void, Never>?
    private let storageRoot: URL

    init(root: URL? = nil) {
        storageRoot = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keeps/AICulling", isDirectory: true)
    }
    @Published private(set) var loadFailed = false
    var group: AICullingResult.Group? {
        guard let session, session.groups.indices.contains(session.groupIndex) else { return nil }
        return session.groups[session.groupIndex]
    }
    var finished: Bool { session.map { $0.offset >= $0.assets.count && group == nil } ?? false }
    var hasPending: Bool { session?.confirming == true }
    var readyForAnalysis: Bool {
        session != nil && group == nil && !finished && !busy && !paused && !loadFailed && error == nil
    }

    func configure(_ configuration: KeepsConfiguration) {
        guard !busy else { return }
        let identity = configuration.baseURL.absoluteString + "|" + configuration.libraryID + "|" + (configuration.accessCredential ?? "")
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let root = storageRoot.appendingPathComponent(key, isDirectory: true)
        guard directory != root else { return }
        directory = root
        session = nil; error = nil; loadFailed = false; paused = true
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let preferenceFile = storageRoot.appendingPathComponent("preferences.json")
            if FileManager.default.fileExists(atPath: preferenceFile.path) {
                preferences = try JSONDecoder().decode(String.self, from: Data(contentsOf: preferenceFile))
            }
            let file = root.appendingPathComponent("session.json")
            if FileManager.default.fileExists(atPath: file.path) {
                session = try JSONDecoder().decode(Session.self, from: Data(contentsOf: file))
            }
        } catch { loadFailed = true; report(error) }
    }

    func savePreferences(_ text: String) throws {
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(text).write(to: storageRoot.appendingPathComponent("preferences.json"), options: .atomic)
        preferences = text
    }

    func startDirectory(client: KeepsClient, path: String, recursive: Bool, instruction: String, showHidden: Bool = false) {
        guard !busy, !loadFailed, session == nil else { return }
        let preferenceSnapshot = preferences
        paused = false
        run {
            var query = KeepsAssetQuery()
            query.directory = path
            query.recursive = recursive
            query.showHidden = showHidden
            query.sort = "capture_asc"
            query.limit = 200
            var assets: [KeepsAsset] = []
            var revision: Int64?
            var cursors = Set<String>()
            repeat {
                try Task.checkCancellation()
                self.status = "正在读取目录照片，已读取 \(assets.count) 张"
                let page = try await client.assets(query: query)
                guard !page.isUpdating, revision == nil || revision == page.revision else {
                    throw AIEditingFailure("目录清单读取期间资料库发生变化，请稍后重新开始，以免遗漏照片。")
                }
                revision = page.revision
                assets.append(contentsOf: page.items.filter { !$0.trashed && !$0.isVideo })
                query.cursor = page.nextCursor
                if let cursor = query.cursor, !cursors.insert(cursor).inserted {
                    throw AIEditingFailure("目录分页返回重复游标，无法确认完整清单。")
                }
            } while query.cursor != nil
            try Task.checkCancellation()
            guard !assets.isEmpty else { throw AIEditingFailure("这个目录中没有可筛选的照片。") }
            guard Set(assets.map(\.id)).count == assets.count else {
                throw AIEditingFailure("目录清单包含重复照片，请刷新资料库后重新开始。")
            }
            self.session = Session(assets: assets, instruction: instruction,
                sourcePath: path, recursive: recursive, preferences: preferenceSnapshot, skippedCount: 0)
            try self.save()
        }
    }

    func toggle(_ index: Int) {
        guard !busy, !loadFailed, !hasPending else { return }
        if session?.kept.contains(index) == true { session?.kept.remove(index) }
        else { session?.kept.insert(index) }
        do { try save() } catch { report(error) }
    }

    func analyze(client: KeepsClient, editor: AIEditingSettingsStore) {
        guard !busy, !loadFailed, let session, group == nil, !finished, let directory else { return }
        paused = false
        run {
            try self.save()
            try editor.validateEditingAccount()
            let end = min(session.offset + 24, session.assets.count)
            let assets = Array(session.assets[session.offset..<end])
            let job = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
            var images: [URL] = []
            for (index, asset) in assets.enumerated() {
                try Task.checkCancellation()
                self.status = "准备预览 \(index + 1)/\(assets.count)"
                let source = job.appendingPathComponent("source-\(index)")
                try await client.downloadCurrentStandard(assetID: asset.id, to: source)
                let output = job.appendingPathComponent("photo-\(index).jpg")
                try await Self.makePreview(source: source, output: output)
                try FileManager.default.removeItem(at: source)
                images.append(output)
            }
            self.status = "AI 正在比较照片并分组"
            let data = try await editor.cullPhotos(images, instruction: session.prompt, job: job)
            try Task.checkCancellation()
            let result = try JSONDecoder().decode(AICullingResult.self, from: data)
            try result.validate(count: assets.count)
            self.session?.groups = result.groups.map { group in
                AICullingResult.Group(title: group.title, reason: group.reason, photos: group.photos.map {
                    AICullingResult.Photo(index: $0.index + session.offset, recommended: $0.recommended, reason: $0.reason)
                })
            }
            self.session?.groupIndex = 0
            self.session?.offset = end
            self.selectRecommendations()
            try self.save()
        }
    }

    func confirm(client: KeepsClient, keepAll: Bool = false) {
        guard !busy, !loadFailed, let group, let session else { return }
        paused = false
        run {
            if !self.hasPending {
                self.session?.confirming = true
                self.session?.pending = Dictionary(uniqueKeysWithValues: group.photos.map {
                    ($0.index, keepAll || session.kept.contains($0.index) ? "picked" : "rejected")
                })
            }
            // Persist the explicit decision before the first server mutation so interrupted groups can resume.
            try self.save()
            for index in (self.session?.pending.keys.sorted() ?? []) {
                try Task.checkCancellation()
                guard let flag = self.session?.pending[index] else { continue }
                self.status = "保存标记，剩余 \(self.session?.pending.count ?? 0) 张"
                _ = try await client.updateAsset(id: session.assets[index].id, patch: KeepsAssetPatch(flagState: flag))
                self.session?.pending[index] = nil
                try self.save()
            }
            try self.advance()
        }
    }

    func skip() {
        guard !busy, !loadFailed, !hasPending else { return }
        paused = false
        do { try advance(skipped: true) } catch { report(error) }
    }

    func finish() {
        guard finished, !busy, !loadFailed, let directory else { return }
        do {
            try FileManager.default.removeItem(at: directory.appendingPathComponent("session.json"))
            session = nil; error = nil
        } catch { report(error) }
    }

    func cancel() { paused = true; task?.cancel() }

    private func selectRecommendations() {
        session?.kept = Set(group?.photos.filter(\.recommended).map(\.index) ?? [])
    }
    private func advance(skipped: Bool = false) throws {
        guard let group else { return }
        if skipped { session?.skippedCount = (session?.skippedCount ?? 0) + group.photos.count }
        session?.confirming = false
        session?.completed += group.photos.count
        session?.groupIndex += 1
        selectRecommendations()
        try save()
        error = nil
    }
    private func save() throws {
        guard let directory, let session else { throw AIEditingFailure("筛片工作台尚未初始化。") }
        do {
            try JSONEncoder().encode(session).write(to: directory.appendingPathComponent("session.json"), options: .atomic)
        } catch {
            loadFailed = true
            throw error
        }
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        busy = true; error = nil
        task = Task {
            defer { busy = false; task = nil; status = "" }
            do { try await operation() }
            catch { report(error) }
        }
    }
    private func report(_ failure: Error) {
        error = String(reflecting: failure)
        if let localized = failure as? LocalizedError, let message = localized.errorDescription {
            error = message + "\n" + String(reflecting: failure)
        }
    }
    nonisolated static func makePreview(source: URL, output: URL) async throws {
        let work = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            guard let input = CGImageSourceCreateWithURL(source as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(input, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1600
                  ] as CFDictionary),
                  let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw AIEditingFailure("无法生成 AI 预览。")
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw AIEditingFailure("无法保存 AI 预览。") }
        }
        try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
}
