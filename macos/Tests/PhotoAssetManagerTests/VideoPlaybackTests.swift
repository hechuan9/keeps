import Foundation
import Testing
import KeepsAPI
import AVFoundation
import AVKit
import SwiftUI
@testable import PhotoAssetManager

@MainActor
struct VideoPlaybackTests {
    @Test func rendersNativePlayerInHostingWindow() throws {
        _ = NSApplication.shared
        let player = AVPlayer()
        let hosting = NSHostingView(rootView: NativeVideoPlayer(player: player))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        func playerView(in view: NSView) -> AVPlayerView? {
            if let view = view as? AVPlayerView { return view }
            return view.subviews.lazy.compactMap { playerView(in: $0) }.first
        }
        let view = try #require(playerView(in: hosting))
        #expect(view.player === player)
        NativeVideoPlayer.dismantleNSView(view, coordinator: ())
        #expect(view.player == nil)
    }

    @Test func deniedPlaybackDoesNotFallBackToDownloadingOriginal() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeniedPlaybackProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = KeepsClient(configuration: KeepsConfiguration(baseURL: URL(string: "https://video.invalid")!, libraryID: "test", accessCredential: "test-token"), session: session)
        let asset = try JSONDecoder().decode(KeepsAsset.self, from: Data(#"{"id":"00000000-0000-0000-0000-000000000001","cameraMake":"","cameraModel":"","lensModel":"","originalFilename":"synthetic.mp4","contentFingerprint":"test","metadataFingerprint":"test","rating":0,"flagState":"unflagged","tags":[],"createdAt":"2026-01-01","updatedAt":"2026-01-01","trashed":false}"#.utf8))
        let store = VideoPlaybackStore()
        defer { store.close() }
        store.open(asset: asset, client: client)
        try await waitUntil { !store.isLoading }
        #expect(store.error?.contains("403") == true)
        #expect(store.player == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["KEEPS_TEST_VIDEO_BASE_URL"] != nil))
    func streamsAndSeeksSyntheticVideoFromLocalServer() async throws {
        let baseURL = try #require(URL(string: ProcessInfo.processInfo.environment["KEEPS_TEST_VIDEO_BASE_URL"] ?? ""))
        #expect(baseURL.host == "127.0.0.1")
        guard baseURL.host == "127.0.0.1" else { return }
        let client = KeepsClient(configuration: KeepsConfiguration(baseURL: baseURL, libraryID: "video-test",
            accessCredential: "synthetic-video-test-credential-0001"))
        let page = try await client.assets()
        let asset = try #require(page.items.first)
        #expect(asset.originalFilename == "synthetic.mp4")
        let store = VideoPlaybackStore()
        defer { store.close() }
        store.open(asset: asset, client: client)
        try await waitUntil { store.error != nil || (!store.isLoading && store.player != nil) }
        #expect(store.error == nil)
        let player = try #require(store.player)
        let item = try #require(player.currentItem)
        #expect((item.asset as? AVURLAsset)?.url.isFileURL == false)
        try await waitUntil { player.currentTime().seconds > 0.1 }
        let target = try await item.asset.load(.duration).seconds * 0.8
        let reached = await player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        #expect(reached)
        try await waitUntil { player.currentTime().seconds > target + 0.1 }
        store.close()
        #expect(store.player == nil)
        #expect(player.currentItem == nil)
        #expect(!store.isLoading)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func version(_ hash: String, path: String, available: Bool = true, isDefault: Bool = false) throws -> KeepsAssetVersion {
        let data = try JSONSerialization.data(withJSONObject: [
            "contentHash": hash, "width": 1920, "height": 1080, "priority": 2,
            "isDefault": isDefault, "userSelected": false, "available": available,
            "paths": [["path": path, "available": available]]
        ])
        return try JSONDecoder().decode(KeepsAssetVersion.self, from: data)
    }

    @Test func selectsDefaultVideoInsteadOfPosterOrUnavailableOriginal() throws {
        let poster = try version("poster", path: "/photos/poster.jpg", isDefault: true)
        let missing = try version("missing", path: "/photos/missing.mov", available: false)
        let first = try version("first", path: "/photos/first.mp4")
        let selected = try version("selected", path: "/photos/selected.MOV", isDefault: true)
        #expect(VideoPlaybackStore.playableVersion([poster, missing, first, selected])?.contentHash == "selected")
        #expect(VideoPlaybackStore.playableVersion([poster, missing, first])?.contentHash == "first")
        #expect(VideoPlaybackStore.playableVersion([poster, missing]) == nil)
    }
}

private final class DeniedPlaybackProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        let isVersions = request.url!.path.hasSuffix("/versions")
        #expect(isVersions || request.url!.path.hasSuffix("/playback"))
        let body = isVersions
            ? #"{"items":[{"contentHash":"test","width":640,"height":360,"priority":2,"isDefault":true,"userSelected":false,"available":true,"paths":[{"path":"/samples/synthetic.mp4","available":true}]}]}"#
            : #"{"detail":"playback denied"}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: isVersions ? 200 : 403, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
