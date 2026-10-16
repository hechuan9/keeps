import SwiftUI
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
    @State private var enlarged: KeepsAsset?
    @State private var exposureSettings: [UUID: CullingExposureSettings] = [:]
    let returnToLibrary: () -> Void

    var body: some View {
        ZStack {
            reviewContent
                .disabled(enlarged != nil)
                .accessibilityHidden(enlarged != nil)
            if let asset = enlarged {
                exposureEditor(asset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background)
            }
        }
        .task {
            if let configuration = library.configuration { store.configure(configuration) }
            preferences = store.preferences
            library.isCullingActive = true
        }
        .onDisappear { store.cancel(); library.isCullingActive = false; library.refresh(force: true) }
    }

    private var reviewContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("AI 筛片助手").font(.title2.bold())
                Spacer()
                if let session = store.session {
                    Text("已过目 \(session.completed)/\(session.assets.count) 张").foregroundStyle(.secondary)
                }
                Button("稍后继续") { returnToLibrary() }.disabled(store.busy)
            }
            if let session = store.session {
                Text(session.sourcePath ?? "恢复中的筛片任务").font(.headline).lineLimit(1)
                    .help(session.sourcePath ?? "")
                DisclosureGroup("本次使用的筛片偏好") {
                    Text(session.preferences ?? "未设置长期偏好").frame(maxWidth: .infinity, alignment: .leading)
                    if !session.instruction.isEmpty { Text("本次要求：" + session.instruction) }
                    Text("偏好在开始时固定。新的长期偏好用于下一次目录筛片。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("编辑长期偏好") { beginPreferenceEditing() }
                    .disabled(store.busy)
            }
            if store.session == nil {
                setup
            } else if store.finished {
                ContentUnavailableView("整个目录已过目", systemImage: "checkmark.circle",
                    description: Text("已确认 \((store.session?.completed ?? 0) - (store.session?.skippedCount ?? 0)) 张，跳过 \(store.session?.skippedCount ?? 0) 张。跳过的照片保持原标记；开始后新加入目录的照片不在本次清单内。"))
                Button("完成") { store.finish(); if store.session == nil { returnToLibrary() } }
            } else if let group = store.group, let session = store.session {
                Text(group.title).font(.title3.bold())
                Text(group.reason).foregroundStyle(.secondary)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16)], spacing: 16) {
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
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .interactiveDismissDisabled(store.busy)
        .onChange(of: store.session?.completed) { _, _ in exposureSettings.removeAll() }
        .onChange(of: store.readyForAnalysis) { _, ready in if ready { analyze() } }
        .sheet(isPresented: $editsPreferences) {
            textEditingSheet(title: "长期筛片偏好", text: $preferenceDraft,
                             error: preferenceError, cancel: { editsPreferences = false }) {
                do {
                    try store.savePreferences(preferenceDraft)
                    preferences = preferenceDraft
                    preferenceError = nil
                    editsPreferences = false
                } catch { preferenceError = String(reflecting: error) }
            }
        }
        .sheet(isPresented: $editsInstruction) {
            textEditingSheet(title: "本次目录的补充要求", text: $instructionDraft,
                             cancel: { editsInstruction = false }) {
                instruction = instructionDraft
                editsInstruction = false
            }
        }
    }

    private func exposureEditor(_ asset: KeepsAsset) -> some View {
        CullingExposureView(asset: asset, client: library.client,
            settings: Binding(get: { exposureSettings[asset.id] ?? CullingExposureSettings() },
                              set: { exposureSettings[asset.id] = $0 }),
            kept: Binding(get: {
                guard let index = store.session?.assets.firstIndex(where: { $0.id == asset.id }) else { return false }
                return store.session?.kept.contains(index) == true
            }, set: { value in
                guard let index = store.session?.assets.firstIndex(where: { $0.id == asset.id }),
                      store.session?.kept.contains(index) != value else { return }
                store.toggle(index)
            }), canChoose: !store.busy && !store.hasPending && !store.loadFailed,
            returnToGroup: { enlarged = nil })
    }

    private var setup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(library.query.directory ?? "请先在服务器来源中打开要筛选的目录").font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("包含子目录", isOn: $includeSubdirectories)
                Text("从整个目录读取照片清单，AI 按场景带你逐组过目。确认或跳过后自动继续，直到清单全部看完。当前搜索、评分筛选和照片选择不限制本次范围，隐藏目录仍遵循图库设置。")
                Text("个人长期偏好").font(.headline)
                preferenceSummary(preferences, placeholder: "尚未设置长期偏好", action: beginPreferenceEditing)
                Text("例如：更重视真实表情；不同构图都保留；家庭纪念照宁可多留；连拍通常留两张。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("本次目录的补充要求")
                preferenceSummary(instruction, placeholder: "未设置补充要求") {
                    instructionDraft = instruction
                    editsInstruction = true
                }
                Text("确认一组后，所选标为留用、其余标为排除；跳过保持原标记。不会移动或删除文件。长期偏好由你明确保存，不从单次改选自动推断。")
                Text("使用「AI 修图」账户发送照片预览分析。无标准图时使用缩略图，推荐不能代替原片级对焦检查；进度保存在这台 Mac。")
                    .font(.callout).foregroundStyle(.secondary)
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

    private func beginPreferenceEditing() {
        preferenceDraft = preferences
        preferenceError = nil
        editsPreferences = true
    }

    private func preferenceSummary(_ text: String, placeholder: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text.isEmpty ? placeholder : text)
                .foregroundStyle(text.isEmpty ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("双击编辑").font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.3)))
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: action)
        .accessibilityAction(named: Text("编辑"), action)
    }

    private func textEditingSheet(title: String, text: Binding<String>, error: String? = nil,
                                  cancel: @escaping () -> Void, save: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2)
            TextEditor(text: text)
                .scrollContentBackground(.hidden)
                .padding(10)
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
        VStack(alignment: .leading, spacing: 10) {
            KeepsPreviewImage(asset: asset, configuration: library.configuration, loadStandard: true)
                .frame(height: 210).frame(maxWidth: .infinity)
            HStack {
                Text(asset.originalFilename).lineLimit(1)
                Spacer()
                Button("编辑") { enlarged = asset }
            }
            HStack {
                let kept = store.session?.kept.contains(photo.index) == true
                Button {
                    if !kept { store.toggle(photo.index) }
                } label: {
                    Label("留用", systemImage: kept ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .tint(kept ? .accentColor : .secondary)
                Button {
                    if kept { store.toggle(photo.index) }
                } label: {
                    Label("排除", systemImage: kept ? "xmark.circle" : "xmark.circle.fill")
                }
                .tint(kept ? .secondary : .red)
            }
            .buttonStyle(.bordered)
            .disabled(store.busy || store.hasPending || store.loadFailed)
            if photo.recommended { Text("AI 推荐保留").font(.caption.bold()).foregroundStyle(.green) }
            Text(photo.reason).font(.callout).foregroundStyle(.secondary)
            Text("原标记：\(asset.flagState == "picked" ? "留用" : asset.flagState == "rejected" ? "排除" : "未标记")")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(store.session?.kept.contains(photo.index) == true ? Color.accentColor : .clear, lineWidth: 2))
    }

    private var reviewActions: some View {
        HStack {
            Button("跳过这组") { store.skip() }.disabled(store.busy || store.hasPending)
            Button("整组留用") { confirm(keepAll: true) }.disabled(store.busy || store.hasPending)
            Spacer()
            let keep = store.session?.kept.count ?? 0
            let reject = (store.group?.photos.count ?? 0) - keep
            Text("留用 \(keep) 张 · 排除 \(reject) 张").foregroundStyle(.secondary)
            Button(store.hasPending ? "继续保存已确认标记" : "确认这组并继续") { confirm() }
                .buttonStyle(.borderedProminent).disabled(store.busy)
        }
    }

    private func analyze() {
        guard let client = library.client else { return }
        store.analyze(client: client, editor: batch.editor)
    }
    private func confirm(keepAll: Bool = false) {
        guard let client = library.client else { return }
        store.confirm(client: client, keepAll: keepAll)
    }
}
