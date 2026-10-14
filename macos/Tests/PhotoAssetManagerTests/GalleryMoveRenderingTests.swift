import AppKit
import SwiftUI
import Testing
import KeepsAPI
@testable import PhotoAssetManager

@MainActor struct GalleryMoveRenderingTests {
    @Test func completedMoveKeepsRenderedPreviewsWhileRefreshing() async throws {
        _ = NSApplication.shared
        let host = UUID().uuidString.lowercased() + ".invalid"
        let root = URL.temporaryDirectory.appendingPathComponent(host)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = try #require(UserDefaults(suiteName: host))
        let state = GalleryRenderingState()
        GalleryRenderingProtocol.register(state, host: host)
        let configuration = KeepsConfiguration(baseURL: URL(string: "https://" + host)!, libraryID: "render-test")
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [GalleryRenderingProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let library = LibraryStore(configuration: configuration, session: session, loadSavedSettings: false,
                                   preferences: defaults, persistConfiguration: { _ in })
        var cacheFiles: [URL] = []
        defer {
            session.invalidateAndCancel()
            GalleryRenderingProtocol.unregister(host: host)
            defaults.removePersistentDomain(forName: host)
            for file in cacheFiles { try? FileManager.default.removeItem(at: file) }
            try? FileManager.default.removeItem(at: root)
        }
        library.showLibrary(directory: "/source")
        try await waitUntil { !library.isLoading && library.assets.count == 6 }
        let imageContext = try #require(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
            bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        imageContext.setFillColor(CGColor(red: 0.05, green: 0.95, blue: 0.2, alpha: 1))
        imageContext.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let bitmap = NSBitmapImageRep(cgImage: try #require(imageContext.makeImage()))
        let source = root.appendingPathComponent("sample.png")
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: source)
        for asset in library.assets {
            let preview = try #require(asset.thumbnail)
            let key = PreviewCache.key(assetID: asset.id, preview: preview, configuration: configuration, role: .thumbnail)
            try await PreviewCache.thumbnails.importCachedFile(from: source, key: key)
            cacheFiles.append(try #require(await PreviewCache.thumbnails.cachedFileURL(forKey: key)))
        }
        let view = ContentView().environmentObject(library)
            .environmentObject(AIEditingBatchStore(root: root, editor: AIEditingSettingsStore(root: root, defaults: defaults)))
            .environmentObject(GeometryTaskStore(root: root))
            .environmentObject(ExposureTaskStore(root: root))
            .environmentObject(ImportTaskOwner())
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        try await waitUntil { (try? greenPixels(hosting)) ?? 0 > 2_000 }
        let before = try greenPixels(hosting)
        state.beginRefresh()
        library.completePhotoMove()
        try await waitUntil { state.hasPending }
        for _ in 0..<8 {
            try await Task.sleep(for: .milliseconds(30))
            #expect(try greenPixels(hosting) > before / 2)
        }
        state.release()
        try await waitUntil { !library.isLoading && library.assets.count == 5 }
        #expect(library.query.directory == "/source")
        for _ in 0..<8 {
            #expect(try greenPixels(hosting) > before / 3)
            try await Task.sleep(for: .milliseconds(16))
        }
    }

    private func greenPixels(_ view: NSView) throws -> Int {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = try #require(bitmap.cgImage)
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var count = 0
        for y in stride(from: 0, to: height, by: 4) {
            for x in stride(from: 0, to: width, by: 4) {
                let offset = (y * width + x) * 4
                if pixels[offset + 1] > 178 && pixels[offset] < 77 && pixels[offset + 2] < 102 { count += 1 }
            }
        }
        return count
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw NSError(domain: "GalleryMoveRenderingTests.Timeout", code: 1)
    }
}

private final class GalleryRenderingState: @unchecked Sendable {
    let ids = (0..<6).map { String(UUID().uuidString.dropLast()) + String($0) }
    private let lock = NSLock()
    private var refreshing = false
    private var pending: GalleryRenderingProtocol?
    var hasPending: Bool { lock.withLock { pending != nil } }
    func beginRefresh() { lock.withLock { refreshing = true } }
    func hold(_ request: GalleryRenderingProtocol) -> Bool {
        lock.withLock { if refreshing { pending = request; return true }; return false }
    }
    func release() {
        let request = lock.withLock { let request = pending; pending = nil; refreshing = false; return request }
        request?.assets(Array(ids.dropFirst()))
    }
}

private final class GalleryRenderingProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var states: [String: GalleryRenderingState] = [:]
    static func register(_ state: GalleryRenderingState, host: String) { lock.withLock { states[host] = state } }
    static func unregister(host: String) { _ = lock.withLock { states.removeValue(forKey: host) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let state = Self.lock.withLock({ Self.states[request.url!.host!] }) else { return }
        let path = request.url!.path
        if path.hasSuffix("/assets") { if !state.hold(self) { assets(state.ids) } }
        else if path.hasSuffix("/navigation") { deliver(["directories": ["/source", "/target"].map { ["path": $0, "name": $0, "photoCount": 6, "hasChildren": false] as [String: Any] }]) }
        else if path.hasSuffix("/counts") { deliver(["all": 6, "picked": 0, "trashed": 0]) }
        else if path.hasSuffix("/hidden-directories") { deliver(["paths": []]) }
        else if path.hasSuffix("/revision") { deliver(["revision": 1, "isUpdating": false]) }
        else { deliver([:]) }
    }
    func assets(_ ids: [String]) {
        let items: [[String: Any]] = ids.map { id in [
            "id": id, "cameraMake": "", "cameraModel": "", "lensModel": "", "originalFilename": id + ".jpg",
            "contentFingerprint": id, "metadataFingerprint": id, "rating": 0, "flagState": "none",
            "tags": [], "createdAt": "", "updatedAt": "", "trashed": false,
            "thumbnail": ["downloadURL": request.url!.absoluteString + "/thumbnail", "width": [96, 42, 64][Int(id.suffix(1), radix: 16)! % 3], "height": 64, "version": "test-v1"]
        ] }
        deliver(["items": items, "total": items.count, "revision": 1, "isUpdating": false])
    }
    private func deliver(_ value: [String: Any]) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: value))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
