import SwiftUI
import AVKit
import KeepsAPI
import OSLog

@MainActor
final class VideoPlaybackStore: ObservableObject {
    @Published private(set) var title = "影片播放"
    @Published private(set) var player: AVPlayer?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    private var task: Task<Void, Never>?
    private var directory: URL?
    private var observation: NSKeyValueObservation?
    private let logger = Logger(subsystem: "local.keeps", category: "VideoPlayback")

    static func playableVersion(_ versions: [KeepsAssetVersion]) -> KeepsAssetVersion? {
        let videos = versions.filter { version in
            version.available && version.paths.contains {
                $0.available && ["mov", "mp4", "m4v", "avi", "mkv", "mts", "m2ts"].contains(URL(fileURLWithPath: $0.path).pathExtension.lowercased())
            }
        }
        return videos.first(where: \.isDefault) ?? videos.first
    }

    func open(asset: KeepsAsset, client: KeepsClient) {
        close()
        title = asset.originalFilename
        error = nil
        isLoading = true
        task = Task { [self] in
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("KeepsVideo-" + UUID().uuidString)
            var installed = false
            defer {
                if !installed { removeTemporary(temporary) }
            }
            do {
                let versions = try await client.versions(assetID: asset.id)
                try Task.checkCancellation()
                guard let version = Self.playableVersion(versions) else {
                    throw PlaybackError.unavailable
                }
                try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
                let url = temporary.appendingPathComponent("video").appendingPathExtension(URL(fileURLWithPath: version.filename).pathExtension)
                try await client.downloadVersion(assetID: asset.id, contentHash: version.contentHash, to: url)
                try Task.checkCancellation()
                let media = AVURLAsset(url: url)
                guard try await media.load(.isPlayable) else { throw PlaybackError.unsupported }
                try Task.checkCancellation()
                let item = AVPlayerItem(asset: media)
                let playback = AVPlayer(playerItem: item)
                observation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                    guard item.status == .failed else { return }
                    let message = String(reflecting: item.error)
                    Task { @MainActor [weak self] in
                        guard let self, self.player?.currentItem === item else { return }
                        self.error = "影片播放失败：\(message)"
                        self.logger.error("Playback failed: \(message, privacy: .public)")
                        self.player?.pause()
                    }
                }
                directory = temporary
                installed = true
                player = playback
                isLoading = false
                playback.play()
            } catch {
                guard !Task.isCancelled else { return }
                self.error = "无法播放影片：\(error.localizedDescription)\n\(String(reflecting: error))"
                logger.error("Video preparation failed: \(String(reflecting: error), privacy: .public)")
                isLoading = false
            }
        }
    }

    func close() {
        task?.cancel()
        task = nil
        observation = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        if let directory { removeTemporary(directory) }
        directory = nil
        isLoading = false
    }

    private func removeTemporary(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do { try FileManager.default.removeItem(at: url) }
        catch { logger.error("Video cache cleanup failed: \(String(reflecting: error), privacy: .public)") }
    }

    private enum PlaybackError: LocalizedError {
        case unavailable, unsupported
        var errorDescription: String? {
            switch self {
            case .unavailable: "服务器没有可用的影片原文件。"
            case .unsupported: "macOS 播放器不支持此影片的编码或格式。"
            }
        }
    }
}

struct VideoPlaybackWindow: View {
    @ObservedObject var store: VideoPlaybackStore

    var body: some View {
        ZStack {
            Color.black
            if let error = store.error {
                ScrollView { Text(error).textSelection(.enabled).padding(24) }
            } else if store.isLoading {
                VStack(spacing: 16) {
                    ProgressView().progressViewStyle(.linear).frame(width: 260)
                    Text("正在从服务器下载影片，下载完成后开始播放…")
                }.padding(24)
            } else if let player = store.player {
                VideoPlayer(player: player)
            } else {
                Text("在图库中双击影片开始播放。")
            }
        }
        .foregroundStyle(.white)
        .frame(minWidth: 480, minHeight: 300)
        .navigationTitle(store.title)
        .onDisappear { store.close() }
    }
}
