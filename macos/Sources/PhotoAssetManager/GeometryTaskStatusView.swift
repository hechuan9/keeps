import SwiftUI
import KeepsAPI

struct GeometryTaskStatusView: View {
    @ObservedObject var store: GeometryTaskStore
    let configuration: KeepsConfiguration?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = store.storageError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            ForEach(store.tasks.filter { $0.phase != .completed && $0.baseURL == configuration?.baseURL.absoluteString && $0.libraryID == configuration?.libraryID }) { task in
                HStack {
                    if !task.failed { ProgressView().controlSize(.small) }
                    Text(task.operation == .rotate ? "旋转照片" : "裁剪照片")
                    Text(task.waitingForConnection ? "等待连接" : Self.label(task.phase))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if task.failed {
                        Button("重试") { store.retry(id: task.id) }
                        Button("移除") { store.discard(id: task.id) }
                    }
                }
                if let error = task.error {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
        }
    }

    private static func label(_ phase: GeometryTask.Phase) -> String {
        switch phase {
        case .preparing: "准备"
        case .downloading: "下载标准图"
        case .rendering: "生成展示图"
        case .uploading: "保存"
        case .completed: "完成"
        }
    }
}
