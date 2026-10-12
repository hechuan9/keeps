import SwiftUI
import KeepsAPI

struct CullingExposureSettings: Equatable, Hashable {
    var automatic = false
    var exposureEV = 0.0
}

struct CullingExposureView: View {
    let asset: KeepsAsset
    let client: KeepsClient?
    @Binding var settings: CullingExposureSettings
    @Binding var kept: Bool
    let canChoose: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var renderer = CullingExposureRenderer()
    @State private var source: URL?
    @State private var directory: URL?
    @State private var image: CGImage?
    @State private var original: CGImage?
    @State private var error: String?
    @State private var sourceName = ""
    @State private var loading = true
    @State private var rendering = false
    @State private var showOriginal = false
    @State private var retry = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("筛片曝光检查").font(.title2)
            Text(asset.originalFilename).lineLimit(1)
            ZStack {
                Color.black
                if let preview = showOriginal ? original : image {
                    Image(decorative: preview, scale: 1).resizable().scaledToFit()
                }
                if loading { ProgressView("正在读取底片…").progressViewStyle(.linear).frame(width: 240).padding().background(.regularMaterial) }
                else if rendering { ProgressView().padding().background(.regularMaterial).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing) }
            }.frame(minWidth: 800, minHeight: 480)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                Button("重新载入底片") { retry += 1 }
            }
            HStack(spacing: 16) {
                Button("自动曝光 · 看信息") { settings.automatic = true; settings.exposureEV = 0 }
                Text(settings.automatic ? "自动展开明暗" : "底片原始显示").foregroundStyle(.secondary)
                Spacer()
                Toggle("查看调整前", isOn: $showOriginal).toggleStyle(.checkbox)
                Button("重置") { settings = CullingExposureSettings(); showOriginal = false }
            }.disabled(source == nil || loading)
            HStack {
                Text("曝光")
                Slider(value: $settings.exposureEV, in: -4...4, step: 0.1)
                Text(String(format: "%+.1f EV", settings.exposureEV)).monospacedDigit().frame(width: 75)
            }.disabled(source == nil || loading || showOriginal)
            Text("仅检查后期潜力，关闭后不会发布或改变调色。自动模式展开明暗层次，不代表恢复已丢失细节；AI 推荐仍基于此前预览。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(sourceName.isEmpty ? "" : "底片：" + sourceName).font(.caption).lineLimit(1)
                Spacer()
                Toggle("留用这张", isOn: $kept).disabled(!canChoose)
                Button("返回这组") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(24)
            .task(id: retry) { await load() }
            .task(id: settings) { await render() }
            .onDisappear { cleanUp() }
    }

    @MainActor private func load() async {
        loading = true; error = nil; source = nil; image = nil; original = nil
        cleanUp()
        guard let client else { loading = false; error = "请先连接资料库。"; return }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("Keeps-Culling-" + UUID().uuidString, isDirectory: true)
        directory = work
        defer {
            loading = false
            if Task.isCancelled { remove(work) }
        }
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let state = try await client.editState(assetID: asset.id)
            guard state.sourceAvailable, let hash = state.negativeContentHash, let name = state.sourceFilename else {
                throw AIEditingFailure("这张照片没有可读取的底片，无法检查曝光潜力。")
            }
            sourceName = name
            let file = work.appendingPathComponent("negative").appendingPathExtension(URL(fileURLWithPath: name).pathExtension)
            try await client.downloadNegative(assetID: asset.id, contentHash: hash, to: file)
            if let expected = state.sourceFileHash {
                let actual = try await AIEditingImages.inspect(file, image: false)
                guard actual.hash == expected else { throw AIEditingFailure("底片内容已变化，请重新载入。") }
            }
            try Task.checkCancellation()
            original = try await renderer.render(sourceURL: file, automatic: false, exposureEV: 0)
            try Task.checkCancellation()
            source = file
            await render()
        } catch {
            if !Task.isCancelled { self.error = String(reflecting: error) }
        }
    }

    @MainActor private func render() async {
        guard let source else { return }
        let requested = settings
        rendering = true
        defer { if settings == requested { rendering = false } }
        do {
            try await Task.sleep(for: .milliseconds(120))
            let result = try await renderer.render(sourceURL: source, automatic: requested.automatic, exposureEV: requested.exposureEV)
            try Task.checkCancellation()
            guard settings == requested, self.source == source else { return }
            image = result; error = nil
        } catch {
            if !Task.isCancelled, settings == requested { self.error = String(reflecting: error) }
        }
    }

    private func cleanUp() {
        if let directory { remove(directory); self.directory = nil }
    }
    private func remove(_ directory: URL) {
        do { try FileManager.default.removeItem(at: directory) }
        catch let failure as CocoaError where failure.code == .fileNoSuchFile { }
        catch { NSLog("Culling preview cleanup failed: %@", String(reflecting: error)) }
    }
}
