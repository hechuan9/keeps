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
    let returnToGroup: () -> Void
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
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("筛片曝光检查").font(.title2)
                Text(asset.originalFilename).lineLimit(1)
                Spacer()
                Button("返回这组", action: returnToGroup).keyboardShortcut(.cancelAction)
            }
            HStack(alignment: .top, spacing: 20) {
                ZStack {
                    Color.black
                    if let preview = showOriginal ? original : image {
                        Image(decorative: preview, scale: 1).resizable().scaledToFit()
                    }
                    if loading {
                        ProgressView("正在读取照片…").padding().background(.regularMaterial)
                    } else if rendering {
                        ProgressView().padding().background(.regularMaterial)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 16) {
                    Text(sourceName).font(.headline)
                    if let error {
                        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        Button("重新载入照片") { retry += 1 }
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        Button("自动曝光 · 看信息") { settings.automatic = true; settings.exposureEV = 0 }
                        Text(settings.automatic ? "自动展开明暗" : "未调整曝光").foregroundStyle(.secondary)
                        Toggle("查看调整前", isOn: $showOriginal).toggleStyle(.checkbox)
                        Text("曝光 " + String(format: "%+.1f EV", settings.exposureEV)).monospacedDigit()
                        Slider(value: $settings.exposureEV, in: -4...4, step: 0.1).disabled(showOriginal)
                        Button("重置") { settings = CullingExposureSettings(); showOriginal = false }
                    }.disabled(source == nil || loading)
                    Text("仅临时检查原片，不发布调色。自动曝光展开现有明暗层次，不代表恢复已丢失的信息；AI 推荐仍基于此前预览。")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    HStack {
                        Button("留用") { kept = true }.tint(kept ? .accentColor : .secondary)
                        Button("排除") { kept = false }.tint(kept ? .secondary : .accentColor)
                    }.buttonStyle(.borderedProminent).disabled(!canChoose)
                }.frame(width: 260)
            }
        }.padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(WorkspaceStyle.panel)
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
            let versions = try await client.versions(assetID: asset.id)
            let version = try Self.exposureSource(in: versions)
            guard let location = version.paths.first(where: \.available) else {
                throw AIEditingFailure("原片路径不可用，请检查资料库中的文件版本。")
            }
            let name = URL(fileURLWithPath: location.path).lastPathComponent
            sourceName = "原片：" + name
            let file = work.appendingPathComponent("source").appendingPathExtension(URL(fileURLWithPath: name).pathExtension)
            try await client.downloadVersion(assetID: asset.id, contentHash: version.contentHash, to: file)
            let actual = try await AIEditingImages.inspect(file, image: false)
            guard actual.hash == version.contentHash else { throw AIEditingFailure("原片内容已变化，请重新载入。") }
            try Task.checkCancellation()
            original = try await renderer.render(sourceURL: file, automatic: false, exposureEV: 0)
            try Task.checkCancellation()
            source = file
            await render()
        } catch {
            if !Task.isCancelled { report(error) }
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
            if !Task.isCancelled, settings == requested { report(error) }
        }
    }

    static func exposureSource(in versions: [KeepsAssetVersion]) throws -> KeepsAssetVersion {
        let available = versions.filter {
            $0.available && $0.paths.contains(where: \.available) && $0.evidence?.generatedFrom == nil
        }
        func hasExtension(_ version: KeepsAssetVersion, _ extensions: Set<String>) -> Bool {
            version.paths.contains {
                $0.available && extensions.contains(URL(fileURLWithPath: $0.path).pathExtension.lowercased())
            }
        }
        if let hasselbladRAW = available.first(where: { hasExtension($0, ["3fr"]) }) {
            return available.first(where: { hasExtension($0, ["heic", "heif", "hif"]) }) ?? hasselbladRAW
        }
        if let negative = available.first(where: { $0.isNegative == true && $0.priority != 3 }) { return negative }
        let rawExtensions: Set<String> = ["arw", "3fr", "dng", "cr2", "cr3", "nef", "nrw", "orf", "raf", "rw2", "pef", "srw"]
        if let raw = available.first(where: { hasExtension($0, rawExtensions) }) { return raw }
        if let original = available.first(where: { $0.priority == 2 }) { return original }
        throw AIEditingFailure("没有可读取的原片版本，请检查资料库中的文件路径。")
    }

    private func report(_ error: Error) {
        NSLog("Culling exposure failed for asset %@ (%@): %@", asset.id.uuidString, asset.originalFilename, String(reflecting: error))
        if case ExposureRenderError.unreadableSource = error {
            self.error = "本机无法解码这张原片（" + asset.originalFilename + "），曝光检查暂不可用。"
        } else {
            self.error = AIEditingFailure.userMessage(error)
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
