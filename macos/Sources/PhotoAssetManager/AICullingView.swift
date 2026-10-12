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
    @State private var enlarged: KeepsAsset?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("AI 筛片助手").font(.title2.bold())
                Spacer()
                if let session = store.session {
                    Text("已过目 \(session.completed)/\(session.assets.count) 张").foregroundStyle(.secondary)
                }
                Button("稍后继续") { dismiss() }.disabled(store.busy)
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
                Button("编辑长期偏好") { preferences = store.preferences; editsPreferences = true }
                    .disabled(store.busy)
            }
            if store.session == nil {
                setup
            } else if store.finished {
                ContentUnavailableView("整个目录已过目", systemImage: "checkmark.circle",
                    description: Text("已确认 \((store.session?.completed ?? 0) - (store.session?.skippedCount ?? 0)) 张，跳过 \(store.session?.skippedCount ?? 0) 张。跳过的照片保持原标记；开始后新加入目录的照片不在本次清单内。"))
                Button("完成") { store.finish(); if store.session == nil { dismiss() } }
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
        .frame(minWidth: 980, idealWidth: 1100, minHeight: 700)
        .interactiveDismissDisabled(store.busy)
        .task {
            if let configuration = library.configuration { store.configure(configuration) }
            preferences = store.preferences
            library.isCullingActive = true
        }
        .onChange(of: store.readyForAnalysis) { _, ready in if ready { analyze() } }
        .sheet(isPresented: $editsPreferences) {
            VStack(alignment: .leading, spacing: 16) {
                Text("长期筛片偏好").font(.title2)
                Text("写下你通常想保留什么，例如人物表情、构图差异、纪念价值，以及相似照片希望保留的数量。")
                TextEditor(text: $preferences).frame(height: 180)
                if let preferenceError { Text(preferenceError).foregroundStyle(.red).textSelection(.enabled) }
                HStack {
                    Button("取消") { editsPreferences = false }
                    Spacer()
                    Button("保存偏好") {
                        do { try store.savePreferences(preferences); preferenceError = nil; editsPreferences = false }
                        catch { preferenceError = String(reflecting: error) }
                    }
                }
            }.padding(24).frame(width: 580)
        }
        .onDisappear { store.cancel(); library.isCullingActive = false; library.refresh(force: true) }
        .sheet(item: $enlarged) { asset in
            VStack {
                KeepsPreviewImage(asset: asset, configuration: library.configuration, loadStandard: true)
                    .frame(minWidth: 800, minHeight: 560)
                Text(asset.originalFilename)
                Button("关闭") { enlarged = nil }
            }.padding()
        }
    }

    private var setup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(library.query.directory ?? "请先在服务器来源中打开要筛选的目录").font(.headline)
                Toggle("包含子目录", isOn: $includeSubdirectories)
                Text("从整个目录读取照片清单，AI 按场景带你逐组过目。确认或跳过后自动继续，直到清单全部看完。当前搜索、评分筛选和照片选择不限制本次范围，隐藏目录仍遵循图库设置。")
                Text("个人长期偏好").font(.headline)
                TextEditor(text: $preferences).frame(height: 100).border(.secondary.opacity(0.3))
                Text("例如：更重视真实表情；不同构图都保留；家庭纪念照宁可多留；连拍通常留两张。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("本次目录的补充要求")
                TextEditor(text: $instruction).frame(height: 65).border(.secondary.opacity(0.3))
                Text("确认一组后，所选标为留用、其余标为弃用；跳过保持原标记。不会移动或删除文件。长期偏好由你明确保存，不从单次改选自动推断。")
                Text("使用「AI 修图」账户发送照片预览分析。推荐基于预览，不能代替原片级对焦检查；进度保存在这台 Mac。")
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
        }
    }

    private func card(_ photo: AICullingResult.Photo, asset: KeepsAsset) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { store.toggle(photo.index) } label: {
                KeepsPreviewImage(asset: asset, configuration: library.configuration, loadStandard: true)
                    .frame(height: 210).frame(maxWidth: .infinity)
                    .overlay(alignment: .topLeading) {
                        Image(systemName: store.session?.kept.contains(photo.index) == true ? "checkmark.circle.fill" : "circle")
                            .font(.title2).foregroundStyle(.white).padding(8).shadow(radius: 3)
                    }
            }.buttonStyle(.plain).disabled(store.busy || store.hasPending)
            HStack {
                Text(asset.originalFilename).lineLimit(1)
                Spacer()
                Button("放大") { enlarged = asset }
            }
            if photo.recommended { Text("AI 推荐保留").font(.caption.bold()).foregroundStyle(.green) }
            Text(photo.reason).font(.callout).foregroundStyle(.secondary)
            Text("原标记：\(asset.flagState == "picked" ? "留用" : asset.flagState == "rejected" ? "弃用" : "未标记")")
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
            Text("留用 \(keep) 张 · 弃用 \(reject) 张").foregroundStyle(.secondary)
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
