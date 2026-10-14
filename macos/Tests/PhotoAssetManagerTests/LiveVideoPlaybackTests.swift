import Foundation
import Testing
import AVFoundation
import AVKit
import SwiftUI
import KeepsAPI
@testable import PhotoAssetManager

/// Explicitly opted-in, read-only playback against an existing catalog asset.
@MainActor
struct LiveVideoPlaybackTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KEEPS_LIVE_VIDEO_ASSET"] != nil))
    func existingCatalogVideoPlaysAndSeeks() async throws {
        let env = ProcessInfo.processInfo.environment
        let base = try #require(URL(string: env["KEEPS_LIVE_VIDEO_URL"] ?? ""))
        let id = try #require(UUID(uuidString: env["KEEPS_LIVE_VIDEO_ASSET"] ?? ""))
        let client = KeepsClient(configuration: KeepsConfiguration(baseURL: base,
            libraryID: env["KEEPS_LIVE_VIDEO_LIBRARY"] ?? "local-library",
            accessCredential: env["KEEPS_LIVE_VIDEO_TOKEN"]))
        let asset = try await client.asset(id: id)
        let key = "video-trim:" + base.absoluteString + ":" + client.configuration.libraryID + ":" + id.uuidString
        // Opening must never resume a previously saved mutation during this read-only test.
        try #require(UserDefaults.standard.data(forKey: key) == nil)
        _ = NSApplication.shared
        let store = VideoPlaybackStore()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: VideoPlaybackWindow(store: store))
        window.orderFront(nil)
        defer { store.close(); window.contentView = nil; window.close() }
        let start = Date()
        store.open(asset: asset, client: client)
        try await wait { store.player != nil || store.error != nil }
        try #require(store.error == nil)
        let player = try #require(store.player)
        player.isMuted = true
        let item = try #require(player.currentItem)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(output)
        try await wait { output.hasNewPixelBuffer(forItemTime: player.currentTime()) || store.error != nil }
        try #require(store.error == nil)
        let firstFrame = Date().timeIntervalSince(start)
        print("LIVE_VIDEO first_frame_seconds=\(firstFrame)")
        #expect(firstFrame < 10)
        let sampleSeconds = Int(env["KEEPS_LIVE_VIDEO_SECONDS"] ?? "12") ?? 12
        try #require((1...120).contains(sampleSeconds))
        let duration = try await item.asset.load(.duration).seconds
        let initial = player.currentTime().seconds
        let sampleWindow = min(Double(sampleSeconds), max(0, duration - initial))
        let sampleStart = Date()
        var waiting = 0
        for _ in 0..<Int(ceil(sampleWindow * 10)) {
            try await Task.sleep(for: .milliseconds(100))
            if player.timeControlStatus == .waitingToPlayAtSpecifiedRate { waiting += 1 }
        }
        let advance = player.currentTime().seconds - initial
        print("LIVE_VIDEO continuous_wall_seconds=\(Date().timeIntervalSince(sampleStart)) advanced_seconds=\(advance) buffering_samples=\(waiting)")
        #expect(advance >= max(sampleWindow - 2, sampleWindow * 0.8))
        #expect(store.error == nil)
        if env["KEEPS_LIVE_VIDEO_ROTATION"] == "1" {
            let track = try #require(try await item.asset.loadTracks(withMediaType: .video).first)
            let size = try await track.load(.naturalSize)
            let preferred = try await track.load(.preferredTransform)
            player.pause()
            let pausedPosition = player.currentTime().seconds
            for turns in [1, 2, 3, 0] {
                let began = Date()
                store.rotate(clockwise: true)
                try await wait { !store.rotationBusy }
                try #require(store.rotationError == nil)
                #expect(store.rotationQuarterTurns == turns)
                #expect(player.currentItem === item)
                let expected = VideoPlaybackStore.rotationGeometry(size: size, preferred: preferred, turns: turns).size
                try await wait {
                    guard let pixel = output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil) else { return false }
                    return CVPixelBufferGetWidth(pixel) == Int(expected.width)
                        && CVPixelBufferGetHeight(pixel) == Int(expected.height)
                }
                print("LIVE_VIDEO rotation_degrees=\(turns * 90) frame_seconds=\(Date().timeIntervalSince(began))")
                if turns == 1 {
                    #expect(abs(player.currentTime().seconds - pausedPosition) < 0.1)
                    #expect(player.rate == 0)
                    player.play()
                }
            }
            store.rotate(clockwise: false)
            try await wait { !store.rotationBusy }
            #expect(store.rotationQuarterTurns == 3)
            store.rotate(clockwise: true)
            try await wait { !store.rotationBusy }
            #expect(store.rotationQuarterTurns == 0)
            #expect(item.videoComposition == nil)
        }
        for fraction in [0.5, 0.9] {
            let target = duration * fraction
            let began = Date()
            let reached = await player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            #expect(reached)
            player.play()
            try await wait { player.currentTime().seconds > target + min(0.1, (duration - target) / 3) && output.hasNewPixelBuffer(forItemTime: player.currentTime()) || store.error != nil }
            try #require(store.error == nil)
            let latency = Date().timeIntervalSince(began)
            print("LIVE_VIDEO seek_fraction=\(fraction) decoded_frame_seconds=\(latency)")
            #expect(latency < 5)
        }
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(45)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
}
