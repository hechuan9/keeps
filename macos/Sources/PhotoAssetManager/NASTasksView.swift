import SwiftUI
import KeepsAPI

struct NASTasksView: View {
    let client: KeepsClient
    @State private var taskStatus: KeepsTaskStatus?
    @State private var isBusy = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).textSelection(.enabled)
                    .font(.caption).accessibilityIdentifier("nas-task-error")
            }
            Text("任务状态每 5 秒自动更新。关闭窗口不影响后台任务执行。")
                .font(.caption).foregroundStyle(.secondary)
            if let taskStatus {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("自动更新").font(.headline)
                            Spacer()
                            Text(Self.statusLabel(taskStatus.automatic.status)).foregroundStyle(.secondary)
                        }
                        if taskStatus.automatic.status == "running" || taskStatus.automatic.status == "pending" {
                            ProgressView(taskStatus.automatic.status == "pending" ? "等待更新照片…" : "正在更新照片…")
                                .progressViewStyle(.linear)
                        }
                        if let photo = taskStatus.automatic.currentPhoto {
                            Text("当前照片：\(photo)").lineLimit(2).truncationMode(.middle)
                                .textSelection(.enabled).help(photo)
                        }
                        Text("已知待更新 \(taskStatus.automatic.remainingPhotos) 张照片")
                            .monospacedDigit()
                        if taskStatus.automatic.failedPhotos > 0 {
                            Text("更新失败 \(taskStatus.automatic.failedPhotos) 张照片").foregroundStyle(.red)
                        }
                        if let error = taskStatus.automatic.error {
                            Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("后台长任务").font(.headline)
                            Spacer()
                            Text(Self.statusLabel(taskStatus.longTask.status)).foregroundStyle(.secondary)
                        }
                        if taskStatus.longTask.status == "running" || taskStatus.longTask.status == "pending" {
                            ProgressView(taskStatus.longTask.status == "pending" ? "等待后台任务开始…" : "正在执行后台任务…")
                                .progressViewStyle(.linear)
                        }
                        if let kind = taskStatus.longTask.kind {
                            Text(Self.kindLabel(kind))
                        }
                        if let path = taskStatus.longTask.path {
                            Text("目录：\(path)").lineLimit(2).truncationMode(.middle)
                                .textSelection(.enabled).help(path)
                        }
                        if let photo = taskStatus.longTask.currentPhoto {
                            Text("当前照片：\(photo)").lineLimit(2).truncationMode(.middle)
                                .textSelection(.enabled).help(photo)
                        }
                        if let processed = taskStatus.longTask.processed {
                            Text("已处理 \(processed) 个文件").monospacedDigit()
                        }
                        if let failed = taskStatus.longTask.failed, failed > 0 {
                            Text("失败 \(failed) 个文件").foregroundStyle(.red)
                        }
                        if let error = taskStatus.longTask.error {
                            Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            } else if isBusy {
                ProgressView("正在读取任务…").progressViewStyle(.linear)
            }
            Spacer(minLength: 0)
        }
        .padding(20).frame(width: 680, height: 540)
        .background(TaskWindowConfiguration())
        .task {
            await refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                await refresh()
            }
        }
    }

    static func statusLabel(_ status: String) -> String {
        switch status {
        case "idle": "空闲"
        case "pending": "等待中"
        case "running": "处理中"
        case "completed": "已完成"
        case "failed": "失败"
        default: status
        }
    }

    static func kindLabel(_ kind: String) -> String {
        switch kind {
        case "manual": "手动一次性作业"
        case "maintenance": "自动维护"
        case "reconcile": "全库补漏"
        default: kind
        }
    }

    @MainActor private func refresh() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            taskStatus = try await client.taskStatus()
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            errorMessage = String(reflecting: error) + "\n" + error.localizedDescription
        }
    }
}

struct NASSourceSettingsView: View {
    let client: KeepsClient
    @State private var rootPath = ""
    @State private var folders: [KeepsFolder] = []
    @State private var newPath = "."
    @State private var isBusy = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("来源").font(.title2)
                Spacer()
                Button("刷新") { perform { try await refresh() } }.disabled(isBusy)
            }
            if isBusy {
                ProgressView("正在更新 NAS 来源…").progressViewStyle(.linear)
            }
            Text("服务器原片根目录：\(rootPath.isEmpty ? "等待连接" : rootPath)")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text("此处管理服务器目录，无需在本机挂载 NAS。输入相对于服务器原片根目录的路径；“.” 表示整个根目录。停止追踪只修改索引配置，保留所有原片。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("例如：2026/旅行，或 .", text: $newPath).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("nas-folder-path")
                Button("添加追踪") {
                    perform {
                        _ = try await client.addFolder(path: newPath.trimmingCharacters(in: .whitespacesAndNewlines))
                        try await refresh()
                    }
                }
                .disabled(isBusy || newPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("服务器来源").font(.headline)
                    if folders.isEmpty { Text("尚未添加服务端目录").foregroundStyle(.secondary) }
                    ForEach(folders) { folder in
                        HStack {
                            Text(folder.path).textSelection(.enabled)
                            Spacer()
                            Text(folder.active ? "追踪中" : "已停止").foregroundStyle(.secondary)
                            if folder.active {
                                Button("核对") { perform {
                                    _ = try await client.scanFolder(id: folder.id)
                                    try await refresh()
                                } }
                                Button("停止追踪") { perform {
                                    try await client.removeFolder(id: folder.id)
                                    try await refresh()
                                } }
                            }
                        }.disabled(isBusy)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .background(OverlayScrollerConfiguration())
            }
        }
        .padding(24).frame(width: 680, height: 420)
        .task { await run { try await refresh() } }
    }

    private func refresh() async throws {
        let response = try await client.folders()
        rootPath = response.rootPath
        folders = response.folders
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        Task { await run(action) }
    }

    @MainActor private func run(_ action: @MainActor () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await action()
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            errorMessage = String(reflecting: error) + "\n" + error.localizedDescription
        }
    }
}

private struct TaskWindowConfiguration: NSViewRepresentable {
    func makeNSView(context: Context) -> ConfigurationView { ConfigurationView() }
    func updateNSView(_ view: ConfigurationView, context: Context) {}

    final class ConfigurationView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window?.standardWindowButton(.zoomButton)?.isHidden = true
        }
    }
}
