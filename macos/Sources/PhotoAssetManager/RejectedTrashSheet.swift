import SwiftUI

struct RejectedTrashSheet: View {
    @ObservedObject var library: LibraryStore
    @State private var confirmation = ""
    private var busy: Bool { library.rejectedTrash != nil && !library.rejectedTrashFinished }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(library.isEmptyingTrash ? "清空 Keeps 回收站" : "删除所有弃用照片").font(.headline)
            Text(library.isEmptyingTrash ? "Keeps 回收站内的所有照片、关联版本和 sidecar 将移入 NAS 回收站，图库资料和缓存将清理。需要恢复文件时，请在 NAS 的 File Station 中操作。" : "整个资料库中标记为“排除”的照片将进入 Keeps 回收站，包括隐藏目录中的照片。原片保留，照片可以从 Keeps 回收站恢复。")
            if let preview = library.rejectedTrashPreview {
                Text("照片：\(preview.count) 张")
                if library.isEmptyingTrash {
                    Text("关联文件：\(preview.totalFiles) 个（含原片、关联版本和 sidecar 元数据文件）")
                    Text("一张照片可能对应多个文件，以下进度按文件统计，不代表照片张数。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if preview.status == "draft" && library.rejectedTrash == nil {
                    Text("请输入照片总数 \(preview.count) 以确认：")
                    TextField("照片总数", text: $confirmation).textFieldStyle(.roundedBorder)
                    if preview.count == 0 { Text("没有可删除的照片。").foregroundStyle(.secondary) }
                }
                if busy && library.isEmptyingTrash {
                    ProgressView(value: Double(preview.completedFiles), total: Double(max(1, preview.totalFiles)))
                    Text(preview.phase == "reconciling" ? "正在更新资料库索引" : preview.phase == "validating" ? "正在核对删除清单" : "正在移入 NAS 回收站")
                    Text("已移入 NAS 回收站的文件：\(preview.completedFiles) / \(preview.totalFiles) 个")
                }
                if preview.status == "completed" {
                    Text(library.isEmptyingTrash ? "已将 \(preview.count) 张照片及其关联文件移入 NAS 回收站。" : "已将 \(preview.count) 张照片移入 Keeps 回收站。")
                }
            }
            if library.isPreparingRejectedTrash { ProgressView("正在统计照片…") }
            if busy { Text("其他操作已暂停。退出应用不会取消任务，下次启动将继续查询进度。").font(.caption) }
            if let message = library.rejectedTrashMessage { Text(message).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button(library.rejectedTrashFinished ? "关闭" : "取消") { library.closeRejectedTrash() }
                    .keyboardShortcut(.cancelAction).disabled(busy || library.isPreparingRejectedTrash)
                Button(library.isEmptyingTrash ? "移入 NAS 回收站" : "移入 Keeps 回收站", role: .destructive) {
                    Task { await library.submitRejectedTrash(confirmation: confirmation) }
                }.disabled(!library.canConfirmRejectedTrash(confirmation))
            }
        }
        .padding(24).frame(width: 480)
        .interactiveDismissDisabled(busy || library.isPreparingRejectedTrash)
        .task { if library.rejectedTrash == nil && library.rejectedTrashPreview == nil && !library.rejectedTrashFinished { await library.previewRejectedTrash() } }
    }
}
