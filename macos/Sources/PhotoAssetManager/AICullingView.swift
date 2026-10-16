import SwiftUI
import AppKit
import KeepsAPI

struct AICullingView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var batch: AIEditingBatchStore
    @StateObject private var store = AICullingStore()
    @State private var instruction = ""
    @State private var preferences = ""
    @State private var includeSubdirectories = true
    @State private var preferenceError: String?
    @State private var editsPreferences = false
    @State private var editsInstruction = false
    @State private var preferenceDraft = ""
    @State private var instructionDraft = ""
    @State private var zoomed: KeepsAsset?
    @State private var globalExposure = 0.0
    @State private var photoSize = 240.0
    @AppStorage("keeps.culling.preloadCount") private var preloadCount = 6
    @State private var instructionError: String?
    @State private var enlarged: KeepsAsset?
    @State private var exposureSettings: [UUID: CullingExposureSettings] = [:]
    let returnToLibrary: () -> Void

    var body: some View {
        ZStack {
            reviewContent
                .disabled(enlarged != nil || zoomed != nil)
                .accessibilityHidden(enlarged != nil || zoomed != nil)
            if let asset = zoomed {
                VStack(spacing: 0) {
                    CullingZoomView(asset: asset, configuration: library.configuration,
                                    exposureEV: $globalExposure, close: { zoomed = nil })
                    decisionControls(for: asset).padding(.bottom, 12)
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(WorkspaceStyle.panel)
            }
            if let asset = enlarged {
                exposureEditor(asset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background)
            }
        }
        .task {
            if let configuration = library.configuration { store.configure(configuration) }
            preferences = store.preferences
            instruction = store.session?.instruction ?? ""
            library.isCullingActive = true
        }
        .task(id: preloadIdentity) {
            guard let configuration = library.configuration else { return }
            await CullingFullSizeCache.shared.prefetch(assets: preloadAssets, configuration: configuration)
        }
        .onDisappear {
            store.cancel(); library.isCullingActive = false; library.refresh(force: true)
            Task { await CullingFullSizeCache.shared.cancel() }
        }
    }

    private var reviewContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("AI 筛片").font(.headline)
                requirements
                Spacer(minLength: 8)
                if store.group != nil {
                    Text("曝光").font(.subheadline)
                    Slider(value: $globalExposure, in: -4...4).frame(width: 110)
                        .accessibilityLabel("全局曝光")
                    Text(String(format: "%+.1f", globalExposure)).monospacedDigit().frame(width: 36)
                    Button { globalExposure = 0 } label: { Image(systemName: "arrow.counterclockwise") }
                        .help("重置曝光")
                    Text("照片大小").font(.subheadline)
                    Slider(value: $photoSize, in: 220...480).frame(width: 110)
                        .accessibilityLabel("照片大小")
                }
                Picker("预载", selection: $preloadCount) {
                    ForEach([0, 3, 6, 12, 24], id: \.self) { count in Text("\(count) 张").tag(count) }
                }.frame(width: 100)
                if let session = store.session {
                    Text("\(session.completed)/\(session.assets.count)").foregroundStyle(.secondary).monospacedDigit()
                }
                Button("稍后继续") { returnToLibrary() }.disabled(store.busy)
            }.controlSize(.small)
            if store.session == nil {
                setup
            } else if store.finished {
                ContentUnavailableView("整个目录已过目", systemImage: "checkmark.circle",
                    description: Text("已确认 \((store.session?.completed ?? 0) - (store.session?.skippedCount ?? 0)) 张，跳过 \(store.session?.skippedCount ?? 0) 张。跳过的照片保持原标记；开始后新加入目录的照片不在本次清单内。"))
                Button("完成") { store.finish(); if store.session == nil { returnToLibrary() } }
            } else if let group = store.group, let session = store.session {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: photoSize, maximum: photoSize), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(group.photos, id: \.index) { photo in
                            card(photo, asset: session.assets[photo.index])
                        }
                    }
                }
                reviewActions.disabled(store.loadFailed)
            } else {
                Spacer()
                Text(store.paused ? "已保存进度，继续后 AI 会带你看下一组。" : "AI 将继续整理目录中的下一组照片。")
                    .foregroundStyle(.secondary)
                Button(store.error == nil ? "继续筛片" : "重试分析") { analyze() }
                    .disabled(store.busy)
                Spacer()
            }
            if store.busy {
                ProgressView().progressViewStyle(.linear)
                HStack {
                    Text(store.status)
                    Spacer()
                    Button("暂停", action: store.cancel)
                }
            }
            if store.loadFailed { Text("进度无法保存或读取，请关闭后重新打开筛片助手。").foregroundStyle(.red) }
            if let error = store.error {
                ScrollView { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                    .frame(maxHeight: 100)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .interactiveDismissDisabled(store.busy)
        .onChange(of: store.session?.completed) { _, _ in exposureSettings.removeAll() }
        .onChange(of: store.readyForAnalysis) { _, ready in if ready { analyze() } }
        .sheet(isPresented: $editsPreferences) {
            textEditingSheet(title: "长期筛片偏好", text: $preferenceDraft,
                             error: preferenceError, cancel: { editsPreferences = false }) {
                do {
                    try store.savePreferences(preferenceDraft)
                    preferences = store.preferences
                    try store.updateRequirements(preferences: preferences, instruction: instruction)
                    preferenceError = nil
                    editsPreferences = false
                } catch { preferenceError = String(reflecting: error) }
            }
        }
        .sheet(isPresented: $editsInstruction) {
            textEditingSheet(title: "本次目录的补充要求", text: $instructionDraft,
                             error: instructionError, cancel: { editsInstruction = false }) {
                do {
                    try store.updateRequirements(preferences: preferences, instruction: instructionDraft)
                    instruction = instructionDraft
                    editsInstruction = false
                    instructionError = nil
                } catch { instructionError = AIEditingFailure.userMessage(error) }
            }
        }
    }

    private func exposureEditor(_ asset: KeepsAsset) -> some View {
        CullingExposureView(asset: asset, client: library.client,
            settings: Binding(get: { exposureSettings[asset.id] ?? CullingExposureSettings() },
                              set: { exposureSettings[asset.id] = $0 }),
            flagState: flagBinding(for: asset), rating: ratingBinding(for: asset),
            proposal: proposal(for: asset),
            canChoose: !store.busy && !store.hasPending && !store.loadFailed,
            returnToGroup: { enlarged = nil })
    }

    private func flagBinding(for asset: KeepsAsset) -> Binding<String> {
        Binding(get: {
            guard let index = store.session?.assets.firstIndex(where: { $0.id == asset.id }) else { return "unflagged" }
            if store.session?.rejected.contains(index) == true { return "rejected" }
            return store.session?.picked?.contains(index) == true ? "picked" : "unflagged"
        }, set: { value in
            guard let index = store.session?.assets.firstIndex(where: { $0.id == asset.id }) else { return }
            store.setFlag(index: index, value: value)
        })
    }

    private func ratingBinding(for asset: KeepsAsset) -> Binding<Int> {
        Binding(get: {
            guard let index = store.session?.assets.firstIndex(where: { $0.id == asset.id }) else { return asset.rating }
            return store.session?.ratings[index] ?? asset.rating
        }, set: { value in
            guard let index = store.session?.assets.firstIndex(where: { $0.id == asset.id }) else { return }
            store.setRating(index: index, value: value)
        })
    }

    private func proposal(for asset: KeepsAsset) -> AICullingResult.Photo? {
        guard let index = store.session?.assets.firstIndex(where: { $0.id == asset.id }) else { return nil }
        return store.group?.photos.first { $0.index == index }
    }

    private func decisionControls(for asset: KeepsAsset) -> some View {
        CullingDecisionControls(flagState: flagBinding(for: asset), rating: ratingBinding(for: asset), proposal: proposal(for: asset))
            .disabled(store.busy || store.hasPending || store.loadFailed)
    }

    private var preloadAssets: [KeepsAsset] {
        guard let session = store.session else { return [] }
        let current = store.group?.photos.map(\.index) ?? []
        let laterGroups = session.groups.dropFirst(session.groupIndex + 1).flatMap { $0.photos.map(\.index) }
        let unprocessed = Array(session.offset..<session.assets.count)
        var seen = Set<Int>()
        let indices = (current + Array((laterGroups + unprocessed).prefix(max(0, min(24, preloadCount)))))
            .filter { session.assets.indices.contains($0) && seen.insert($0).inserted }
        return indices.map { session.assets[$0] }
    }

    private var preloadIdentity: String {
        (library.configuration?.baseURL.absoluteString ?? "") + "|" +
        (library.configuration?.libraryID ?? "") + "|" +
        (library.configuration?.accessCredential ?? "") + "|" +
        preloadAssets.map { $0.id.uuidString + ($0.standard?.version ?? "") }.joined(separator: ",")
    }

    private var setup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Toggle("包含子目录", isOn: $includeSubdirectories)
                if let preferenceError { Text(preferenceError).foregroundStyle(.red).textSelection(.enabled) }
                Button("保存偏好并开始此目录") {
                    guard let client = library.client, let path = library.query.directory else { return }
                    do {
                        try store.savePreferences(preferences)
                        preferenceError = nil
                        store.startDirectory(client: client, path: path, recursive: includeSubdirectories,
                            instruction: instruction, showHidden: !library.hiddenDirectoryFilterEnabled)
                    } catch { preferenceError = String(reflecting: error) }
                }.disabled(library.query.directory == nil || store.busy || store.loadFailed)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(2)
        }
    }

    private var requirements: some View {
        HStack(spacing: 6) {
            Button("长期偏好", action: beginPreferenceEditing)
            Button("本次要求", action: beginInstructionEditing)
        }.disabled(store.busy || store.hasPending || store.loadFailed)
    }

    private func beginInstructionEditing() {
        instructionDraft = instruction
        instructionError = nil
        editsInstruction = true
    }

    private func beginPreferenceEditing() {
        preferenceDraft = preferences
        preferenceError = nil
        editsPreferences = true
    }

    private func textEditingSheet(title: String, text: Binding<String>, error: String? = nil,
                                  cancel: @escaping () -> Void, save: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2)
            CullingRequirementsEditor(text: text)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.3)))
            if let error {
                ScrollView { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    .frame(maxHeight: 80)
            }
            HStack {
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("确认保存", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 580, height: 360)
    }

    private func card(_ photo: AICullingResult.Photo, asset: KeepsAsset) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            CullingPreviewView(asset: asset, configuration: library.configuration, exposureEV: globalExposure)
                .frame(height: photoSize * 0.75).frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { zoomed = asset }
            HStack {
                Text(asset.originalFilename).lineLimit(1)
                Spacer()
                Button("放大") { zoomed = asset }
                Button("编辑") { enlarged = asset }
            }
            decisionControls(for: asset)
                .help(photo.reason)
        }.padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(store.session?.rejected.contains(photo.index) == true ? Color.red : .clear, lineWidth: 2))
    }

    private var reviewActions: some View {
        HStack {
            Spacer()
            Text("弃用 \(store.session?.rejected.count ?? 0) 张").foregroundStyle(.secondary)
            Button(store.hasPending ? "继续保存已确认标记" : "下一组") { confirm() }
                .buttonStyle(.borderedProminent).disabled(store.busy)
        }
    }

    private func analyze() {
        guard let client = library.client else { return }
        store.analyze(client: client, editor: batch.editor)
    }
    private func confirm() {
        guard let client = library.client else { return }
        store.confirm(client: client)
    }
}

private struct CullingRequirementsEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let editor = NSTextView()
        editor.isRichText = false
        editor.font = .systemFont(ofSize: 14)
        editor.textColor = .labelColor
        editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 12, height: 12)
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = true
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.delegate = context.coordinator
        editor.string = text
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let editor = scroll.documentView as? NSTextView, editor.string != text else { return }
        editor.string = text
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            text.wrappedValue = editor.string
        }
    }
}

struct CullingDecisionControls: View {
    @Binding var flagState: String
    @Binding var rating: Int
    let proposal: AICullingResult.Photo?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let proposal {
                HStack(spacing: 6) {
                    Text("AI")
                    Text(proposal.rejected ? "弃用" : "不弃用")
                    if proposal.rating > 0 {
                        Text(String(repeating: "★", count: min(5, proposal.rating)))
                    } else {
                        Text("旧记录未评分")
                    }
                }.font(.caption2).foregroundStyle(.blue).help(proposal.reason)
            }
            HStack(spacing: 8) {
            Button { flagState = flagState == "picked" ? "unflagged" : "picked" } label: {
                Image(systemName: flagState == "picked" ? "flag.fill" : "flag")
            }.tint(flagState == "picked" ? .green : .secondary)
                .buttonStyle(.bordered).help("留用；再次点击取消").accessibilityLabel("留用")
            Button { flagState = flagState == "rejected" ? "unflagged" : "rejected" } label: {
                Image(systemName: flagState == "rejected" ? "xmark.circle.fill" : "xmark.circle")
            }.tint(flagState == "rejected" ? .red : .secondary)
                .buttonStyle(.bordered).help("弃用；再次点击取消").accessibilityLabel("弃用")
            HStack(spacing: 4) {
                ForEach(1...5, id: \.self) { star in
                    Button { rating = rating == star ? 0 : star } label: {
                        Image(systemName: star <= rating ? "star.fill" : "star")
                            .foregroundStyle(star <= rating ? Color.yellow : Color.secondary)
                    }.buttonStyle(.plain).help("\(star) 星").accessibilityLabel("\(star) 星")
                }
            }
            }
        }
    }
}
