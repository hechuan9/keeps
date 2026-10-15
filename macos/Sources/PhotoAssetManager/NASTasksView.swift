import SwiftUI
import KeepsAPI

struct NASTasksView: View {
    let client: KeepsClient
    @ObservedObject var library: LibraryStore
    @State private var taskStatus: KeepsTaskStatus?
    @State private var isBusy = false
    @State private var errorMessage: String?

    @State private var expanded = false

    private var errors: String {
        ([errorMessage, taskStatus?.longTask.error]
            .compactMap { $0 }).joined(separator: "\n\n")
    }

    static func isVisible(_ status: String) -> Bool {
        ["running", "pending", "failed"].contains(status)
    }

    private var hasWork: Bool {
        let hasServerWork = taskStatus.map { status in
            Self.isVisible(status.longTask.status)
            || (status.longTask.failed ?? 0) > 0
        } ?? false
        return library.isRefreshingDirectoryAfterTrash || hasServerWork
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasWork || !errors.isEmpty {
                HStack(spacing: 10) {
                    Button { expanded.toggle() } label: {
                        Label(errors.isEmpty ? "后台任务" : "后台任务出错",
                              systemImage: expanded ? "chevron.down" : "chevron.right")
                    }.buttonStyle(.plain)
                    if library.isRefreshingDirectoryAfterTrash {
                        Text("正在更新目录")
                        ProgressView().progressViewStyle(.linear).frame(width: 100)
                    }
                    if let status = taskStatus {
                        if Self.isVisible(status.longTask.status) {
                            Text("\(status.longTask.kind.map(Self.kindLabel) ?? "后台长任务") · \(Self.statusLabel(status.longTask.status))")
                        }
                        if status.longTask.status == "running" || status.longTask.status == "pending" {
                            ProgressView().progressViewStyle(.linear).frame(width: 100)
                        }
                    }
                    if let task = taskStatus?.longTask, task.status == "failed", let jobID = task.jobID {
                        Button("重试") { Task { await retry(jobID: jobID) } }
                            .disabled(isBusy)
                            .accessibilityIdentifier("nas-task-retry")
                    }
                    Spacer(minLength: 0)
                    if !errors.isEmpty {
                        Button("复制错误", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(errors, forType: .string)
                        }.accessibilityIdentifier("nas-task-copy-error")
                    }
                }.padding(.horizontal, 16).padding(.vertical, 8)
                if expanded {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            if let task = taskStatus?.longTask, Self.isVisible(task.status) {
                                if let phase = task.phase { Text("阶段：\(Self.phaseLabel(phase))") }
                                if let path = task.path { Text("目录：\(path)").textSelection(.enabled) }
                                if let photo = task.currentPhoto { Text("当前照片：\(photo)").textSelection(.enabled) }
                                if let processed = task.processed { Text("已处理 \(processed) 个文件") }
                                if let failed = task.failed, failed > 0 { Text("失败 \(failed) 个文件").foregroundStyle(.red) }
                            }
                            if !errors.isEmpty {
                                Text(errors).foregroundStyle(.red).textSelection(.enabled)
                                    .accessibilityIdentifier("nas-task-error")
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }.frame(maxHeight: 180)
                }
                Divider()
            }
        }
        .font(.caption).background(WorkspaceStyle.panel)
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

    static func phaseLabel(_ phase: String) -> String {
        switch phase {
        case "waiting": "等待执行"
        case "scanning": "扫描目录"
        case "indexing": "更新身份与索引"
        case "media": "生成展示图"
        case "cleanup": "清理旧缓存"
        case "publishing": "发布目录状态"
        case "completed": "已完成"
        default: phase
        }
    }

    static func kindLabel(_ kind: String) -> String {
        switch kind {
        case "manual": "用户任务"
        case "import-media": "导入处理"
        case "trash": "清理回收站"
        default: kind
        }
    }

    @MainActor private func retry(jobID: String) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await client.retryJob(id: jobID)
            taskStatus = try await client.taskStatus()
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            errorMessage = String(reflecting: error) + "\n" + error.localizedDescription
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
            Text("此处管理服务器目录，无需在本机挂载 NAS。输入相对于服务器原片根目录的路径；“.” 表示整个根目录。添加来源不会自动扫描；新增或修改文件后，请点击“扫描”。移除来源只修改索引配置，保留所有原片。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("例如：2026/旅行，或 .", text: $newPath).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("nas-folder-path")
                Button("添加来源") {
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
                            Text(folder.active ? "已添加" : "已停用").foregroundStyle(.secondary)
                            if folder.active {
                                Button("扫描") { perform {
                                    _ = try await client.scanFolder(id: folder.id)
                                    try await refresh()
                                } }
                                Button("移除来源") { perform {
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
