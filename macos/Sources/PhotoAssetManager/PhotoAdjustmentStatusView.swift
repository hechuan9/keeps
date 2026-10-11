import KeepsAPI
import SwiftUI

struct PhotoAdjustmentStatusView: View {
    @ObservedObject var store: ExposureTaskStore
    let configuration: KeepsConfiguration?
    @State private var showsTasks = false

    private var tasks: [ExposureTask] {
        store.tasks.filter { $0.baseURL == configuration?.baseURL.absoluteString && $0.libraryID == configuration?.libraryID }
    }

    private var pending: [ExposureTask] { tasks.filter { $0.phase != .completed } }

    var body: some View {
        if !tasks.isEmpty || store.storageError != nil {
            HStack(spacing: 12) {
                if let current = pending.first {
                    if !current.failed { ProgressView().progressViewStyle(.linear).frame(width: 100) }
                    Text(current.statusLabel).lineLimit(1)
                    Text("\(pending.count) 项待完成").foregroundStyle(.secondary)
                } else {
                    Text(store.storageError == nil ? "照片调整已完成" : "无法保存照片调整任务")
                }
                Spacer()
                Button("查看调整任务") { showsTasks = true }
            }
            .font(.caption).padding(.horizontal, 16).padding(.vertical, 8)
            .sheet(isPresented: $showsTasks) { taskSheet }
        }
    }

    private var taskSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("照片调整").font(.headline)
                Spacer()
                Button("关闭") { showsTasks = false }.keyboardShortcut(.cancelAction)
            }
            Text("计算在此 Mac 上执行。断网后会等待重连，退出应用后将在下次启动时继续。")
                .font(.caption).foregroundStyle(.secondary)
            if let error = store.storageError {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(tasks.reversed()) { task in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(task.sourceFilename ?? "照片 \(task.assetID.uuidString.prefix(8))").font(.headline)
                            Text(task.statusLabel)
                            if task.phase != .completed && !task.failed {
                                ProgressView().progressViewStyle(.linear)
                            }
                            if let error = task.error {
                                Text(error).font(.caption).textSelection(.enabled)
                            }
                            if task.failed {
                                HStack {
                                    Button("重试") { store.retry(id: task.id) }
                                    Button("结束此任务") { store.discard(id: task.id) }
                                }
                            }
                        }
                        Divider()
                    }
                }
            }
        }.padding(24).frame(width: 560, height: 420)
    }
}

private extension ExposureTask {
    var statusLabel: String {
        if failed { return "调整未完成" }
        if waitingForConnection { return "等待服务器连接，将自动继续" }
        switch phase {
        case .preparing: return "正在准备照片调整"
        case .downloading: return "正在下载底片"
        case .rendering: return "正在计算曝光并生成展示图"
        case .uploading: return "正在上传并保存调整"
        case .completed: return operation == .reset ? "曝光调整已还原" : operation == .setNegative ? "底片已更新" : "自动曝光已完成"
        }
    }
}
