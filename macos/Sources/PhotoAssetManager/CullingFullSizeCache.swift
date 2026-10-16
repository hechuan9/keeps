import AppKit
import CoreImage
import CryptoKit
import KeepsAPI

/// Full sources stay on disk; only the visible image is decoded at native resolution.
actor CullingFullSizeCache {
    static let shared = CullingFullSizeCache()
    private let root: URL
    private var pending: [String: Task<URL, Error>] = [:]
    private var files: [String: URL] = [:]
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let context = CIContext(options: [.cacheIntermediates: false])

    init(directory: URL = URL.cachesDirectory.appendingPathComponent("KeepsCullingSources")) { root = directory }

    nonisolated static func namespace(_ configuration: KeepsConfiguration) -> String {
        digest([configuration.baseURL.absoluteString, configuration.libraryID, configuration.accessCredential ?? ""])
    }
    private nonisolated static func digest(_ values: [String]) -> String {
        SHA256.hash(data: Data(values.map { "\($0.utf8.count):\($0)" }.joined().utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func file(asset: KeepsAsset, configuration: KeepsConfiguration) async throws -> URL {
        try Task.checkCancellation()
        let key = Self.digest([Self.namespace(configuration), asset.id.uuidString, asset.standard?.version ?? "original"])
        if let file = files[key], FileManager.default.fileExists(atPath: file.path) { return file }
        if let task = pending[key] { return try await task.value }
        let task = Task { try await self.fetch(asset: asset, configuration: configuration) }
        pending[key] = task
        defer { pending[key] = nil }
        let file = try await task.value
        files[key] = file
        return file
    }

    private func acquire() async {
        if active < 2 { active += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { active -= 1 } else { waiters.removeFirst().resume() }
    }

    private func fetch(asset: KeepsAsset, configuration: KeepsConfiguration) async throws -> URL {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        let directory = root.appendingPathComponent(Self.namespace(configuration), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let standard = asset.standard {
            let cache = PreviewCache(directory: directory.appendingPathComponent("standards"), role: .standard)
            _ = try await cache.prefetch(assetID: asset.id, preview: standard, configuration: configuration, skipWhenBusy: false)
            let key = PreviewCache.key(assetID: asset.id, preview: standard, configuration: configuration, role: .standard)
            if let file = try await cache.cachedFileURL(forKey: key) {
                try Task.checkCancellation()
                return file
            }
            throw AIEditingFailure("无法缓存全尺寸成片，请检查磁盘空间后重新载入。")
        }
        let client = KeepsClient(configuration: configuration)
        let versions = try await client.versions(assetID: asset.id)
        let version = try await CullingExposureView.exposureSource(in: versions)
        guard let path = version.paths.first(where: \.available) else { throw AIEditingFailure("原片路径不可用。") }
        let ext = URL(fileURLWithPath: path.path).pathExtension.lowercased()
        let target = directory.appendingPathComponent(Self.digest([asset.id.uuidString, version.contentHash])).appendingPathExtension(ext)
        if FileManager.default.fileExists(atPath: target.path) { return target }
        let temporary = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        defer {
            if FileManager.default.fileExists(atPath: temporary.path) {
                do { try FileManager.default.removeItem(at: temporary) }
                catch { NSLog("Culling cache cleanup failed: %@", String(reflecting: error)) }
            }
        }
        try await client.downloadVersion(assetID: asset.id, contentHash: version.contentHash, to: temporary)
        let actual = try await AIEditingImages.inspect(temporary, image: false)
        guard actual.hash == version.contentHash else { throw AIEditingFailure("原片内容已变化，请重新载入。") }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temporary, to: target)
        return target
    }

    func image(asset: KeepsAsset, configuration: KeepsConfiguration, maxPixelSize: Int?) async throws -> CGImage {
        let url = try await file(asset: asset, configuration: configuration)
        try Task.checkCancellation()
        return try decode(url: url, maxPixelSize: maxPixelSize)
    }

    func decode(url: URL, maxPixelSize: Int?) throws -> CGImage {
        try Task.checkCancellation()
        let rawExtensions: Set<String> = ["arw", "3fr", "dng", "cr2", "cr3", "nef", "nrw", "orf", "raf", "rw2", "pef", "srw"]
        let input: CIImage
        if rawExtensions.contains(url.pathExtension.lowercased()) {
            guard let raw = CIRAWFilter(imageURL: url) else { throw ExposureRenderError.unreadableSource(url) }
            if let maxPixelSize { raw.scaleFactor = Float(min(1, CGFloat(maxPixelSize) / max(raw.nativeSize.width, raw.nativeSize.height))) }
            guard let output = raw.outputImage else { throw ExposureRenderError.unreadableSource(url) }
            input = output
        } else {
            guard let output = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { throw ExposureRenderError.unreadableSource(url) }
            input = output
        }
        guard !input.extent.isInfinite, !input.extent.isNull, input.extent.width > 0, input.extent.height > 0 else { throw ExposureRenderError.invalidImage }
        let scale = maxPixelSize.map { min(1, CGFloat($0) / max(input.extent.width, input.extent.height)) } ?? 1
        let output = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let image = context.createCGImage(output, from: output.extent) else { throw ExposureRenderError.invalidImage }
        try Task.checkCancellation()
        return image
    }

    func prefetch(assets: [KeepsAsset], configuration: KeepsConfiguration) async {
        for start in stride(from: 0, to: assets.count, by: 2) {
            guard !Task.isCancelled else { return }
            await withTaskGroup(of: Void.self) { group in
                for asset in assets[start..<min(start + 2, assets.count)] {
                    group.addTask {
                        do { _ = try await self.file(asset: asset, configuration: configuration) }
                        catch { if !Task.isCancelled { NSLog("Culling full source failed for %@: %@", asset.id.uuidString, String(reflecting: error)) } }
                    }
                }
            }
        }
    }

    func cancel() { for task in pending.values { task.cancel() } }
}
