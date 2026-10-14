import Foundation
import Testing
import KeepsAPI
import AVFoundation
import AVKit
import SwiftUI
@testable import PhotoAssetManager

@MainActor
struct VideoPlaybackTests {
    @Test func resumesPersistedTrimWithoutCreatingAnotherRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CompletedTrimProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = KeepsClient(configuration: KeepsConfiguration(baseURL: URL(string: "https://trim.invalid")!, libraryID: "test"), session: session)
        let asset = try JSONDecoder().decode(KeepsAsset.self, from: Data(#"{"id":"00000000-0000-0000-0000-000000000001","cameraMake":"","cameraModel":"","lensModel":"","originalFilename":"synthetic.mp4","contentFingerprint":"test","metadataFingerprint":"test","rating":0,"flagState":"unflagged","tags":[],"createdAt":"2026-01-01","updatedAt":"2026-01-01","trashed":false}"#.utf8))
        let key = "video-trim:https://trim.invalid:test:" + asset.id.uuidString
        let request = KeepsVideoTrimRequest(id: CompletedTrimProtocol.requestID, contentHash: "hash", startSeconds: 1, endSeconds: 2)
        UserDefaults.standard.set(try JSONEncoder().encode(request), forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let store = VideoPlaybackStore()
        defer { store.close() }
        store.open(asset: asset, client: client)
        try await waitUntil { !store.trimBusy }
        #expect(store.savedAssetID == CompletedTrimProtocol.newAssetID)
        #expect(store.trimError == nil)
        #expect(!store.hasPendingTrim)
        #expect(!store.canSaveTrim)
        #expect(UserDefaults.standard.data(forKey: key) == nil)
    }

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

    @Test func failedMediaConnectionClearsPlayerAndLoadingState() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeniedPlaybackProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = KeepsClient(configuration: KeepsConfiguration(baseURL: URL(string: "http://127.0.0.1:1")!, libraryID: "test", accessCredential: "test-token"), session: session)
        let asset = try JSONDecoder().decode(KeepsAsset.self, from: Data(#"{"id":"00000000-0000-0000-0000-000000000001","cameraMake":"","cameraModel":"","lensModel":"","originalFilename":"synthetic.mp4","contentFingerprint":"test","metadataFingerprint":"test","rating":0,"flagState":"unflagged","tags":[],"createdAt":"2026-01-01","updatedAt":"2026-01-01","trashed":false}"#.utf8))
        let store = VideoPlaybackStore()
        defer { store.close() }
        store.open(asset: asset, client: client)
        try await waitUntil { store.error != nil }
        #expect(store.error?.contains("影片播放失败") == true)
        #expect(!store.isLoading)
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
        try await waitUntil { store.duration > 0 }
        store.trimStart = 0.25
        store.trimEnd = min(1.0, store.duration)
        #expect(store.validTrim)
        store.previewTrim()
        #expect(item.forwardPlaybackEndTime.seconds == store.trimEnd)
        store.endTrimPreview()
        #expect(!item.forwardPlaybackEndTime.isValid)
        store.trimStart = store.trimEnd
        #expect(!store.validTrim)
        store.trimStart = -.infinity
        #expect(!store.validTrim)
        if ProcessInfo.processInfo.environment["KEEPS_TEST_VIDEO_TRIM"] == "1" {
            store.trimStart = 0.25
            store.trimEnd = 1.25
            store.saveTrim()
            try await waitUntil { !store.trimBusy }
            #expect(store.trimError == nil)
            let savedID = try #require(store.savedAssetID)
            #expect(savedID != asset.id)
            #expect(try await client.asset(id: asset.id).trashed)
            let saved = try await client.asset(id: savedID)
            #expect(!saved.trashed)
            #expect(saved.originalFilename.hasSuffix(".mp4"))
            store.openSavedVideo()
            try await waitUntil { store.title == saved.originalFilename && store.duration > 0 }
            #expect(abs(store.duration - 1.0) < 0.25)
        }
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
        let mediaFailure = request.url?.host == "127.0.0.1"
        let body = isVersions
            ? #"{"items":[{"contentHash":"test","width":640,"height":360,"priority":2,"isDefault":true,"userSelected":false,"available":true,"paths":[{"path":"/samples/synthetic.mp4","available":true}]}]}"#
            : mediaFailure
                ? #"{"playbackURL":"http://192.0.2.1:2283/derivatives/local-playback/synthetic-token","expiresAt":4102444800}"#
                : #"{"detail":"playback denied"}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: isVersions || mediaFailure ? 200 : 403, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class CompletedTrimProtocol: URLProtocol, @unchecked Sendable {
    static let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let newAssetID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let trim = request.url!.path.hasSuffix("/video-trims")
        var body = Data()
        if let data = request.httpBody { body = data }
        else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
        }
        if trim {
            #expect(request.httpMethod == "POST")
            let submitted = try? JSONDecoder().decode(KeepsVideoTrimRequest.self, from: body)
            #expect(submitted?.id == Self.requestID)
        }
        let json = trim
            ? """
              {"id":"\(Self.requestID)","assetID":"00000000-0000-0000-0000-000000000001","contentHash":"hash","startSeconds":1,"endSeconds":2,"status":"completed","newAssetID":"\(Self.newAssetID)"}
              """
            : "{}"
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: trim ? 202 : 403, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
