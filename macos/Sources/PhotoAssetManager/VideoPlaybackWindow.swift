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
    @Published var isTrimming = false
    @Published var trimStart = 0.0
    @Published var trimEnd = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var trimMessage: String?
    @Published private(set) var trimError: String?
    @Published private(set) var trimBusy = false
    @Published private(set) var savedAssetID: UUID?
    private var source: (assetID: UUID, hash: String, client: KeepsClient)?
    private var pendingTrim: KeepsVideoTrimRequest?
    private var trimTask: Task<Void, Never>?
    private var persistenceKey: String?
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
        persistenceKey = "video-trim:" + client.configuration.baseURL.absoluteString
            + ":" + client.configuration.libraryID + ":" + asset.id.uuidString
        if let key = persistenceKey, let data = UserDefaults.standard.data(forKey: key) {
            do {
                pendingTrim = try JSONDecoder().decode(KeepsVideoTrimRequest.self, from: data)
                if let pendingTrim { source = (asset.id, pendingTrim.contentHash, client) }
                isTrimming = true
                runTrim(assetID: asset.id, client: client)
            } catch {
                trimError = "无法恢复裁剪任务：\(String(reflecting: error))"
            }
        }
        error = nil
        isLoading = true
        task = Task { [self] in
            do {
                let versions = try await client.versions(assetID: asset.id)
                try Task.checkCancellation()
                guard let version = Self.playableVersion(versions) else {
                    throw PlaybackError.unavailable
                }
                source = (asset.id, version.contentHash, client)
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
                do {
                    let seconds = try await media.load(.duration).seconds
                    try Task.checkCancellation()
                    guard player === playback else { return }
                    if seconds.isFinite && seconds > 0 {
                        duration = seconds
                        trimStart = pendingTrim?.startSeconds ?? 0
                        trimEnd = pendingTrim?.endSeconds ?? seconds
                    } else {
                        trimError = "影片没有有效时长，无法裁剪。"
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    trimError = "无法读取裁剪所需时长：\(String(reflecting: error))"
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.error = "无法播放影片：\(error.localizedDescription)\n\(String(reflecting: error))"
                logger.error("Video preparation failed: \(String(reflecting: error), privacy: .public)")
                isLoading = false
            }
        }
    }

    var validTrim: Bool {
        duration.isFinite && duration > 0 && trimStart.isFinite && trimEnd.isFinite
            && trimStart >= 0 && trimEnd > trimStart && trimEnd <= duration
    }

    var canSaveTrim: Bool {
        !trimBusy && savedAssetID == nil && (pendingTrim != nil || (validTrim && source != nil))
    }

    var hasPendingTrim: Bool { pendingTrim != nil }

    func previewTrim() {
        guard validTrim, let player else { return }
        player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: trimEnd, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: trimStart, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }

    func endTrimPreview() {
        player?.currentItem?.forwardPlaybackEndTime = .invalid
    }

    func saveTrim() {
        guard canSaveTrim, let source else { return }
        if pendingTrim == nil {
            let request = KeepsVideoTrimRequest(contentHash: source.hash, startSeconds: trimStart, endSeconds: trimEnd)
            do {
                let data = try JSONEncoder().encode(request)
                if let key = persistenceKey { UserDefaults.standard.set(data, forKey: key) }
                pendingTrim = request
            } catch {
                trimError = String(reflecting: error)
                return
            }
        }
        player?.pause()
        runTrim(assetID: source.assetID, client: source.client)
    }

    private func runTrim(assetID: UUID, client: KeepsClient) {
        guard let request = pendingTrim else { return }
        trimTask?.cancel()
        trimBusy = true
        trimError = nil
        trimMessage = "正在提交裁剪任务…"
        trimTask = Task { [weak self] in
            do {
                // Reposting the persisted identifier recovers an uncertain network response safely.
                var result = try await client.trimVideo(assetID: assetID, trim: request)
                while true {
                    try Task.checkCancellation()
                    guard let self else { return }
                    switch result.status {
                    case "completed":
                        guard let newAssetID = result.newAssetID else { throw KeepsAPIError.invalidResponse }
                        self.savedAssetID = newAssetID
                        self.trimMessage = "新视频已保存，原视频已进入 Keeps 回收站。"
                        self.clearPendingTrim()
                        self.trimBusy = false
                        return
                    case "failed":
                        self.trimError = result.error ?? "NAS 裁剪失败，未返回错误详情。"
                        self.trimMessage = nil
                        self.clearPendingTrim()
                        self.trimBusy = false
                        return
                    case "pending": self.trimMessage = "等待 NAS 裁剪；关闭窗口后任务仍会继续。"
                    case "processing": self.trimMessage = "NAS 正在裁剪并保存新视频…"
                    case "indexing": self.trimMessage = "新视频正在入库，完成后将原视频放入回收站…"
                    default: throw KeepsAPIError.invalidResponse
                    }
                    try await Task.sleep(for: .seconds(2))
                    result = try await client.videoTrim(assetID: assetID, id: request.id)
                }
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.trimBusy = false
                if case KeepsAPIError.http(let status, _) = error, [400, 404, 409, 422].contains(status) {
                    self.clearPendingTrim()
                    self.trimMessage = "服务器未接受裁剪请求，请检查错误后重试。"
                } else {
                    self.trimMessage = "连接中断，NAS 可能仍在处理。重试将查询同一个任务。"
                }
                self.trimError = String(reflecting: error)
                self.logger.error("Video trim failed: \(String(reflecting: error), privacy: .public)")
            }
        }
    }

    private func clearPendingTrim() {
        pendingTrim = nil
        if let key = persistenceKey { UserDefaults.standard.removeObject(forKey: key) }
    }

    func openSavedVideo() {
        guard let id = savedAssetID, let source else { return }
        trimTask?.cancel()
        trimTask = Task { [weak self] in
            do {
                let asset = try await source.client.asset(id: id)
                try Task.checkCancellation()
                self?.open(asset: asset, client: source.client)
            } catch {
                guard !Task.isCancelled else { return }
                self?.trimError = String(reflecting: error)
            }
        }
    }

    func close() {
        trimTask?.cancel()
        trimTask = nil
        source = nil
        pendingTrim = nil
        persistenceKey = nil
        duration = 0
        trimStart = 0
        trimEnd = 0
        trimBusy = false
        trimMessage = nil
        trimError = nil
        savedAssetID = nil
        isTrimming = false
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Toggle("裁剪时长", isOn: $store.isTrimming).toggleStyle(.button)
                        .disabled(store.trimBusy || store.hasPendingTrim || store.savedAssetID != nil)
                    Spacer()
                    if store.trimBusy { ProgressView().controlSize(.small) }
                    if store.savedAssetID != nil {
                        Button("播放新视频") { store.openSavedVideo() }
                    }
                }
                if store.isTrimming {
                    if store.duration > 0 {
                        trimTimeRow("起点", value: $store.trimStart)
                        trimTimeRow("终点", value: $store.trimEnd)
                        Text("保留 \(max(0, store.trimEnd - store.trimStart), specifier: "%.2f") 秒 · 总长 \(store.duration, specifier: "%.2f") 秒")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if store.duration > 0 && !store.validTrim {
                        Text("起点必须早于终点，且都在影片时长范围内。")
                            .font(.caption).foregroundStyle(.red)
                    }
                    HStack {
                        Button("预览片段") { store.previewTrim() }.disabled(!store.validTrim)
                        Spacer()
                        Button(store.hasPendingTrim ? "重试任务" : "保存新视频并回收原视频") { store.saveTrim() }
                            .disabled(!store.canSaveTrim)
                    }
                    Text("保存到原目录。新视频入库成功后，原视频进入 Keeps 回收站，可恢复。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let message = store.trimMessage { Text(message).font(.callout) }
                    if let error = store.trimError {
                        ScrollView { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                            .frame(maxHeight: 80)
                    }
                }
            }
            .padding(12)
            .background(.regularMaterial)
            .foregroundStyle(.primary)
        }
        .onChange(of: store.isTrimming) { _, enabled in
            if !enabled { store.endTrimPreview() }
        }
        .onDisappear { store.close() }
    }

    private func trimTimeRow(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title).frame(width: 32)
            Slider(value: value, in: 0...max(store.duration, 0.01))
            TextField("秒", value: value, format: .number.precision(.fractionLength(2)))
                .frame(width: 76).textFieldStyle(.roundedBorder)
            Text("秒").font(.caption)
            Button("当前画面") {
                if let seconds = store.player?.currentTime().seconds, seconds.isFinite {
                    value.wrappedValue = min(store.duration, max(0, seconds))
                }
            }
        }
        .disabled(store.trimBusy || store.hasPendingTrim || store.savedAssetID != nil)
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
