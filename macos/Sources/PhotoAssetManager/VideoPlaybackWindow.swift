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
            do {
                let versions = try await client.versions(assetID: asset.id)
                try Task.checkCancellation()
                guard let version = Self.playableVersion(versions) else {
                    throw PlaybackError.unavailable
                }
                let descriptor = try await client.videoPlayback(assetID: asset.id, contentHash: version.contentHash)
                try Task.checkCancellation()
                let media = AVURLAsset(url: descriptor.playbackURL)
                let item = AVPlayerItem(asset: media)
                let playback = AVPlayer(playerItem: item)
                player = playback
                observation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.player?.currentItem === item else { return }
                        switch item.status {
                        case .readyToPlay:
                            self.isLoading = false
                        case .failed:
                            self.isLoading = false
                            let message = String(reflecting: item.error)
                            self.error = descriptor.expiresAt <= Date().timeIntervalSince1970
                                ? "播放地址已过期，请重新打开影片。\n\(message)"
                                : "影片播放失败，请检查网络或影片格式后重新打开。\n\(message)"
                            self.logger.error("Playback failed: \(message, privacy: .private)")
                            playback.pause()
                        default: break
                        }
                    }
                }
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
        error = nil
        isLoading = false
    }

    private enum PlaybackError: LocalizedError {
        case unavailable
        var errorDescription: String? {
            switch self {
            case .unavailable: "服务器没有可用的影片原文件。"
            }
        }
    }
}

struct VideoPlaybackWindow: View {
    @ObservedObject var store: VideoPlaybackStore

    var body: some View {
        ZStack {
            Color.black
            if let player = store.player {
                NativeVideoPlayer(player: player)
            }
            if let error = store.error {
                ScrollView { Text(error).textSelection(.enabled).padding(24) }
            } else if store.isLoading {
                VStack(spacing: 16) {
                    ProgressView().progressViewStyle(.linear).frame(width: 260)
                    Text("正在连接服务器并缓冲影片…")
                }.padding(24)
            } else if store.player == nil {
                Text("在图库中双击影片开始播放。")
            }
        }
        .foregroundStyle(.white)
        .frame(minWidth: 480, minHeight: 300)
        .navigationTitle(store.title)
        .onDisappear { store.close() }
    }
}

struct NativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player = nil
    }
}
