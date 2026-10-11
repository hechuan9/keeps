import SwiftUI

struct RejectedTrashSheet: View {
    @ObservedObject var library: LibraryStore
    @State private var confirmation = ""
    private var busy: Bool { library.rejectedTrash != nil && !library.rejectedTrashFinished }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("删除所有弃用照片").font(.headline)
            Text("范围为整个资料库中标记为“排除”的照片，包括隐藏目录，不含 Keeps 图库回收站。原片、关联版本和 sidecar 将移入 NAS 回收站。需要恢复时，请在 NAS 的 File Station 中操作。")
            if let preview = library.rejectedTrashPreview {
                Text("弃用照片：\(preview.count) 张")
                Text("关联文件：\(preview.totalFiles) 个（含原片、关联版本和 sidecar 元数据文件）")
                Text("一张照片可能对应多个文件，以下进度按文件统计，不代表照片张数。")
                    .font(.caption).foregroundStyle(.secondary)
                if preview.status == "draft" && library.rejectedTrash == nil {
                    Text("请输入照片总数 \(preview.count) 以确认：")
                    TextField("照片总数", text: $confirmation).textFieldStyle(.roundedBorder)
                    if preview.count == 0 { Text("没有可删除的弃用照片。").foregroundStyle(.secondary) }
                }
                if busy {
                    ProgressView(value: Double(preview.completedFiles), total: Double(max(1, preview.totalFiles)))
                    Text(preview.phase == "reconciling" ? "正在更新资料库索引" : preview.phase == "validating" ? "正在核对删除清单" : "正在移入 NAS 回收站")
                    Text("已移入 NAS 回收站的文件：\(preview.completedFiles) / \(preview.totalFiles) 个")
                }
                if preview.status == "completed" {
                    Text("已将 \(preview.count) 张弃用照片及其关联文件移入 NAS 回收站，共 \(preview.completedFiles) 个文件。")
                }
            }
            if library.isPreparingRejectedTrash { ProgressView("正在统计弃用照片…") }
            if busy { Text("其他操作已暂停。退出应用不会取消任务，下次启动将继续查询进度。").font(.caption) }
            if let message = library.rejectedTrashMessage { Text(message).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button(library.rejectedTrashFinished ? "关闭" : "取消") { library.closeRejectedTrash() }
                    .keyboardShortcut(.cancelAction).disabled(busy || library.isPreparingRejectedTrash)
                Button("移入 NAS 回收站", role: .destructive) {
                    Task { await library.submitRejectedTrash(confirmation: confirmation) }
                }.disabled(!library.canConfirmRejectedTrash(confirmation))
            }
        }
        .padding(24).frame(width: 480)
        .interactiveDismissDisabled(busy || library.isPreparingRejectedTrash)
        .task { if library.rejectedTrash == nil && library.rejectedTrashPreview == nil && !library.rejectedTrashFinished { await library.previewRejectedTrash() } }
    }
}
