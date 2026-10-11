import AppKit
import SwiftUI

struct AIEditingWorkspaceView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var store: AIEditingBatchStore
    @Environment(\.openSettings) private var openSettings

    var autoStart = false
    var returnToLibrary: () -> Void
    private enum Editor: Identifiable {
        case preferences, instruction, candidates, suggestion(AIEditingPreferenceSuggestion)
        var id: String {
            switch self {
            case .preferences: "preferences"
            case .instruction: "instruction"
            case .candidates: "candidates"
            case .suggestion(let value): value.id.uuidString
            }
        }
    }
    @State private var editor: Editor?
    @State private var editorDraft = ""

    var body: some View {
        GeometryReader { workspace in
            VStack(spacing: 0) {
                header.padding(20)
                Divider()
                if store.batch != nil, store.workspaceItems.isEmpty {
                    Spacer()
                } else if store.batch != nil {
                    ScrollView {
                        LazyVStack(spacing: 20) {
                            ForEach(store.workspaceItems) { item in
                                AIEditingPhotoRow(item: item, store: store, maximumPreviewHeight: min(540, max(300, workspace.size.height * 0.65)))
                            }
                        }.padding(20)
                    }
                } else {
                    ContentUnavailableView("从图库选择照片", systemImage: "photo.on.rectangle", description: Text("选择照片后，点击 AI 调色进入工作台。"))
                }
                Divider()
                footer.padding(16)
            }
        }
        .background(WorkspaceStyle.canvas)
        .preferredColorScheme(.dark)
        .tint(WorkspaceStyle.accent)
        .task {
            store.restore(library: library)
            if autoStart && store.errorMessage == nil { store.start() }
        }
        .sheet(item: $editor) { target in editingDialog(target).interactiveDismissDisabled() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("AI 调色工作台").font(.title2.bold())
                Spacer()
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("我的审美偏好").font(.headline)
                    Spacer()
                    if !store.preferenceSuggestions.isEmpty {
                        Button("偏好候选（\(store.preferenceSuggestions.count)）") { editor = .candidates }
                    }
                    Button("编辑偏好") { openEditor(.preferences, text: store.preferencesText) }
                }
                Text(store.preferencesText.isEmpty ? "尚未设置，双击添加审美偏好" : store.preferencesText)
                    .foregroundStyle(.secondary).lineLimit(3)
                Text("双击编辑，保存在这台 Mac，供尚未开始的照片使用").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12).background(WorkspaceStyle.panel, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { openEditor(.preferences, text: store.preferencesText) }
            .accessibilityAction(named: Text("编辑审美偏好")) { openEditor(.preferences, text: store.preferencesText) }
            HStack {
                Text(store.batchInstruction.isEmpty ? "新增照片要求：未设置" : "新增照片要求：" + store.batchInstruction)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button("调整要求") { openEditor(.instruction, text: store.batchInstruction) }
                    .disabled(store.batch == nil)
            }
            Text("选择采用版本后，该照片立即移出工作台并在后台发布；进度显示在底部状态栏。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func openEditor(_ target: Editor, text: String) {
        editorDraft = text
        editor = target
    }

    @ViewBuilder private func editingDialog(_ target: Editor) -> some View {
        if case .candidates = target {
            VStack(alignment: .leading, spacing: 16) {
                Text("审美偏好候选").font(.title2.bold())
                Text("从你提出的调色要求中总结；只有确认加入，才会用于后续照片。")
                    .font(.callout).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if store.preferenceSuggestions.isEmpty { Text("暂无待确认的候选").foregroundStyle(.secondary) }
                        ForEach(store.preferenceSuggestions) { suggestion in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(suggestion.text).textSelection(.enabled)
                                Text("来自：" + suggestion.sourceName).font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    Button("忽略") { store.dismissPreferenceSuggestion(id: suggestion.id) }
                                    Spacer()
                                    Button("编辑并加入") { openEditor(.suggestion(suggestion), text: suggestion.text) }
                                }
                                Divider()
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if let error = store.errorMessage { Text(error).foregroundStyle(.red).lineLimit(3) }
                HStack { Spacer(); Button("完成") { editor = nil }.keyboardShortcut(.cancelAction) }
            }.padding(24).frame(width: 580, height: 480)
        } else {
            textEditingDialog(target)
        }
    }

    private func textEditingDialog(_ target: Editor) -> some View {
        let title: String
        let help: String
        switch target {
        case .preferences:
            title = "编辑审美偏好"
            help = "确认后保存在这台 Mac；已开始的照片保留原偏好。"
        case .instruction:
            title = "调整新增照片要求"
            help = "确认后仅用于尚未开始的照片，不会直接改写长期偏好。"
        case .suggestion:
            title = "确认偏好候选"
            help = "可以先修改表述；确认后加入长期审美偏好。"
        case .candidates:
            title = "审美偏好候选"; help = ""
        }
        return VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.bold())
            Text(help).font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $editorDraft).font(.body)
                .padding(8).background(WorkspaceStyle.panel, in: RoundedRectangle(cornerRadius: 8))
                .frame(maxHeight: .infinity)
            if let error = store.errorMessage { Text(error).foregroundStyle(.red).lineLimit(3) }
            HStack {
                Spacer()
                Button("取消") { editor = nil }.keyboardShortcut(.cancelAction)
                Button("确认保存") { saveEditor(target) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(isEmptySuggestion(target))
            }
        }.padding(24).frame(width: 580, height: 440)
    }

    private func isEmptySuggestion(_ target: Editor) -> Bool {
        if case .suggestion = target { return editorDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return false
    }

    private func saveEditor(_ target: Editor) {
        switch target {
        case .preferences:
            Task { if await store.savePreferences(text: editorDraft) { editor = nil } }
        case .instruction:
            if store.saveBatchInstruction(text: editorDraft) { editor = nil }
        case .suggestion(let suggestion):
            if store.acceptPreferenceSuggestion(id: suggestion.id, text: editorDraft) { editor = nil }
        case .candidates: break
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = store.errorMessage {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Button("AI 设置") { openSettings() }.disabled(store.isRunning)
                if store.isRunning {
                    Button("暂停", action: store.cancel)
                } else if store.batch?.cancelled == true {
                    Button("继续处理", action: store.retry)
                }
                if !store.failedItems.isEmpty || store.errorMessage != nil {
                    Button("重试未完成任务", action: store.retry).disabled(store.isRunning)
                }
                Spacer()
                if store.isAwaitingConfirmation {
                    Button("开始调色（\(store.totalCount) 张）", action: store.start)
                        .buttonStyle(.borderedProminent)
                }
            }
            Divider()
            HStack {
                Button("取消") { leaveWorkspace() }
                    .disabled(cannotLeaveWorkspace)
                if cannotLeaveWorkspace {
                    Text("任务处理完成后可返回图库").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") {
                    guard !cannotLeaveWorkspace else { return }
                    if store.batch != nil { store.closeCompletedWorkspace() }
                    if store.batch?.items.isEmpty != false { returnToLibrary() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(cannotLeaveWorkspace || (store.batch?.items.contains { $0.phase != .done } ?? false))
            }
        }
    }

    private var cannotLeaveWorkspace: Bool {
        store.isRunning || store.backgroundDecisionCount > 0
    }

    private func leaveWorkspace() {
        guard !cannotLeaveWorkspace else { return }
        returnToLibrary()
    }
}

private struct AIEditingPhotoRow: View {
    @EnvironmentObject private var library: LibraryStore
    let item: AIEditingBatch.Item
    @ObservedObject var store: AIEditingBatchStore
    let maximumPreviewHeight: CGFloat
    @State private var decodedAspectRatio: CGFloat?
    @State private var instruction = ""
    @State private var showsRefinement = false
    @State private var zoom = 1.0
    @State private var offset = CGSize.zero
    @State private var dragOrigin = CGSize.zero

    private var candidates: [AIEditingBatch.Candidate] { item.candidates ?? [] }
    private var selected: AIEditingBatch.Candidate? { candidates.first { $0.id == item.selectedCandidateID } }
    private var displayed: AIEditingBatch.Candidate? { selected ?? candidates.last }
    private var editable: Bool { store.canInteract(item) }
    private var aspectRatio: CGFloat {
        if let decodedAspectRatio { return decodedAspectRatio }
        if let asset = library.assets.first(where: { $0.id == item.assetID }),
           let preview = asset.standard ?? asset.gridPreview ?? asset.browseThumbnail,
           preview.width > 0, preview.height > 0 {
            return CGFloat(preview.width) / CGFloat(preview.height)
        }
        return 1.5
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(item.name)
                    .font(.headline).lineLimit(2).truncationMode(.middle)
                    .textSelection(.enabled).help(item.name)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                Spacer()
                Text(phaseTitle).foregroundStyle(.secondary)
            }
            versionPicker
            AIEditingComparisonLayout(aspectRatio: aspectRatio, maximumHeight: maximumPreviewHeight) {
                comparisonPane(url: item.originalPreview, title: "采用调整前版本", original: true, selected: item.selectedCandidateID == nil) {
                    store.choose(itemID: item.id, candidateID: nil)
                }
                comparisonPane(url: displayed?.result.preview ?? displayed?.result.fullSize, title: displayedVersionTitle, selected: item.selectedCandidateID != nil) {
                    if let candidate = displayed { store.choose(itemID: item.id, candidateID: candidate.id) }
                }
            }
            HStack {
                Image(systemName: "minus.magnifyingglass")
                Slider(value: $zoom, in: 1...4).frame(width: 150).accessibilityLabel("同步缩放")
                Image(systemName: "plus.magnifyingglass")
                Button("重置视图") { zoom = 1; offset = .zero; dragOrigin = .zero }
                Spacer()
            }.font(.caption)
            if let reason = displayed?.result.reason, !reason.isEmpty {
                Text("调色说明：" + reason).textSelection(.enabled)
            }
            if let failure = item.failure {
                if item.isBackgroundDecision {
                    Button("重试后台处理") { store.retryItem(itemID: item.id) }
                        .disabled(store.activities[item.id] != nil)
                }
                Text(failure).foregroundStyle(.red).textSelection(.enabled)
                if let details = item.failureDetails {
                    DisclosureGroup("诊断详情") { Text(details).font(.caption).textSelection(.enabled) }
                }
            }
            HStack {
                Button("继续调色…") { showsRefinement = true }.disabled(!editable)
                Button("重新开始") {
                    if store.restartItem(itemID: item.id) { instruction = "" }
                }.disabled(!store.canRestart(item))
                    .help("清空这张照片的调色版本、意见和对话，从底片重新调色；保留长期审美偏好。")
            }
            HStack {
                if let activity = store.activities[item.id] {
                    ProgressView().controlSize(.small)
                    Text(activity.title).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("弃用") { store.reject(itemID: item.id) }
                    .disabled(!editable)
            }
        }
        .padding(18)
        .background(WorkspaceStyle.panel, in: RoundedRectangle(cornerRadius: 12))
        .sheet(isPresented: $showsRefinement) {
            VStack(alignment: .leading, spacing: 16) {
                Text("继续调色 · " + item.name).font(.title2.bold()).lineLimit(2)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("第 \(index + 1) 版 · \(candidate.instruction.isEmpty ? "首次调色" : candidate.instruction)").font(.headline)
                                if !candidate.result.reason.isEmpty {
                                    Text(candidate.result.reason).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.frame(maxHeight: .infinity)
                Text("你的调整要求").font(.headline)
                RefinementInstructionEditor(text: $instruction).frame(height: 110)
                HStack {
                    Spacer()
                    Button("取消") { showsRefinement = false }.keyboardShortcut(.cancelAction)
                    Button("确认并生成下一版") {
                        if store.refine(itemID: item.id, instruction: instruction) {
                            instruction = ""
                            showsRefinement = false
                        }
                    }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(!editable || instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).frame(width: 620, height: 560).interactiveDismissDisabled()
        }
    }

    private var displayedVersionTitle: String {
        guard let index = candidates.firstIndex(where: { $0.id == displayed?.id }) else { return "采用 AI 结果" }
        return "采用第 \(index + 1) 版"
    }

    private var versionPicker: some View {
        HStack {
            if !candidates.isEmpty {
                Picker("调色版本", selection: Binding<UUID?>(
                    get: { displayed?.id },
                    set: { store.selectCandidate(itemID: item.id, candidateID: $0) }
                )) {
                    ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                        Text("第 \(index + 1) 版 · \(candidate.instruction.isEmpty ? "首次调色" : candidate.instruction)")
                            .tag(Optional(candidate.id))
                            .disabled(!candidate.result.isSelectable)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!editable)
            } else {
                Text("AI 调色结果").foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.font(.subheadline)
    }

    private var phaseTitle: String {
        if item.failure != nil { return "需要处理" }
        switch item.phase {
        case .preparing: return "等待调色"
        case .downloading: return "准备照片"
        case .grading: return "正在调色"
        case .uploading: return "正在发布"
        case .discarding: return "正在弃用"
        case .review: return "待确认"
        case .done: return "已确认"
        }
    }

    private func comparisonPane(url: URL?, title: String, original: Bool = false, selected: Bool, action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                ZStack {
                    Color.black.opacity(0.35)
                    AIEditingComparisonImage(url: url,
                        asset: original ? library.assets.first(where: { $0.id == item.assetID }) : nil,
                        configuration: library.configuration,
                        onImageSize: { size in
                            if original { decodedAspectRatio = size.width / size.height }
                        })
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .scaleEffect(zoom).offset(offset)
                }
                .clipped().contentShape(Rectangle())
                .gesture(DragGesture().onChanged { value in
                    offset = CGSize(width: dragOrigin.width + value.translation.width, height: dragOrigin.height + value.translation.height)
                }.onEnded { _ in dragOrigin = offset })
            }
            Button(action: action) {
                Label(title, systemImage: selected ? "largecircle.fill.circle" : "circle")
                    .frame(maxWidth: .infinity)
            }.buttonStyle(.plain).disabled(!editable || url == nil)
                .frame(height: AIEditingComparisonLayout.controlsHeight - 8)
        }
    }
}

struct AIEditingBackgroundStatus: View {
    @ObservedObject var store: AIEditingBatchStore
    let showWorkspace: () -> Void

    var body: some View {
        if store.backgroundDecisionCount > 0 || store.failedDecisionCount > 0 {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 10) {
                    if store.backgroundDecisionCount > 0 {
                        if store.batch?.cancelled != true { ProgressView().controlSize(.small) }
                        Text("后台处理 \(store.backgroundDecisionCount) 张\(store.batch?.cancelled == true ? " · 已暂停" : "")")
                            .foregroundStyle(.secondary)
                    }
                    if store.failedDecisionCount > 0 {
                        Button("\(store.failedDecisionCount) 张处理失败 · 查看") { showWorkspace() }
                            .foregroundStyle(.red).buttonStyle(.plain)
                    }
                    Spacer()
                }.font(.caption).padding(.horizontal, 16).padding(.vertical, 8)
            }.background(WorkspaceStyle.canvas)
        }
    }
}

struct AIEditingComparisonLayout: Layout {
    var aspectRatio: CGFloat
    var maximumHeight: CGFloat
    static let controlsHeight: CGFloat = 32
    private let spacing: CGFloat = 16

    static func previewSize(availableWidth: CGFloat, aspectRatio: CGFloat, maximumHeight: CGFloat) -> CGSize {
        let ratio = aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : 1.5
        let widthLimit = max(0, (availableWidth - 16) / 2)
        let width = min(sqrt(135_000 * ratio), widthLimit, max(0, maximumHeight) * ratio)
        return CGSize(width: width, height: width / ratio)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 932
        let preview = Self.previewSize(availableWidth: width, aspectRatio: aspectRatio, maximumHeight: maximumHeight)
        return CGSize(width: width, height: preview.height + Self.controlsHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let preview = Self.previewSize(availableWidth: bounds.width, aspectRatio: aspectRatio, maximumHeight: maximumHeight)
        let size = CGSize(width: preview.width, height: preview.height + Self.controlsHeight)
        let start = bounds.midX - (size.width * 2 + spacing) / 2
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: start + CGFloat(index) * (size.width + spacing), y: bounds.minY),
                          anchor: .topLeading, proposal: ProposedViewSize(size))
        }
    }
}

private struct RefinementInstructionEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.delegate = context.coordinator
        view.isRichText = false
        view.font = .systemFont(ofSize: NSFont.systemFontSize)
        view.backgroundColor = .textBackgroundColor
        view.textContainerInset = NSSize(width: 5, height: 4)
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.heightTracksTextView = true
        view.string = text
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.text = $text
        if view.string != text { view.string = text }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            guard let replacementString else { return true }
            if replacementString.isEmpty { return true }
            let candidate = (textView.string as NSString).replacingCharacters(in: range, with: replacementString)
            guard let container = textView.textContainer, let font = textView.font else { return false }
            let storage = NSTextStorage(string: candidate + "\u{200B}", attributes: [.font: font])
            let layout = NSLayoutManager()
            let measuredContainer = NSTextContainer(size: NSSize(
                width: container.containerSize.width, height: .greatestFiniteMagnitude
            ))
            measuredContainer.lineFragmentPadding = container.lineFragmentPadding
            storage.addLayoutManager(layout)
            layout.addTextContainer(measuredContainer)
            layout.ensureLayout(for: measuredContainer)
            return layout.usedRect(for: measuredContainer).height <= textView.bounds.height - 2 * textView.textContainerInset.height
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }
    }
}
