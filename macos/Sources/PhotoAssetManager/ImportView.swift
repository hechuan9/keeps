import SwiftUI
import KeepsAPI
import UniformTypeIdentifiers

struct ImportView: View {
    @ObservedObject private var store: ImportStore
    @Environment(\.dismiss) private var dismiss
    @State private var choosingSource = false
    @State private var targetPath: String?
    @State private var rootPath: String?
    @State private var directories: [KeepsNavigationDirectory] = []
    @State private var history: [String?] = []
    @State private var loadingDirectories = false
    @State private var directoryError: String?
    @State private var showingNewFolder = false
    @State private var newFolderName = ""
    @State private var creatingDirectory = false
    @State private var creationError: String?

    init(store: ImportStore, initialTarget: String?) {
        self.store = store
        _targetPath = State(initialValue: store.manifest?.targetPath ?? initialTarget)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("导入照片到 NAS").font(.title2)
            Text("递归读取来源中的 RAW、JPG/JPEG、HEIF/HEIC 及关联 XMP。原文件保留，同名文件自动另取名称。")
                .foregroundStyle(.secondary)
            HStack {
                Text("来源：\(store.source?.path ?? "未选择")").lineLimit(2).textSelection(.enabled)
                Spacer()
                Button("选择文件夹…") { choosingSource = true }
                    .disabled(store.isBusy || store.manifest != nil)
            }
            targetBrowser
            Toggle("保持导入结构", isOn: $store.preserveStructure)
                .disabled(store.isBusy || store.manifest != nil)
            Text(store.preserveStructure
                 ? "在目标目录中保留来源文件夹内的子目录层级，不额外创建来源文件夹本身。"
                 : "默认关闭：所有照片及关联 XMP 平铺到同一个目标文件夹。")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("跳过目标文件夹中内容完全相同的文件", isOn: $store.deduplicate)
                .disabled(store.isBusy || store.manifest != nil)
            Text(store.deduplicate
                 ? "开启后会在对应目标目录比较文件内容；缺失的 RAW、JPEG、HEIF 或 XMP 会按配对补齐。"
                 : "默认不去重、不预读整批照片；RAW、JPEG、HEIF 和 XMP 保持配对，同名冲突整组改名。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text(store.message).textSelection(.enabled)
            if store.isBusy {
                ProgressView().progressViewStyle(.linear)
                    .accessibilityLabel(store.message)
            }
            if store.fileCount > 0 {
                ProgressView("上传数据", value: Double(store.sentBytes), total: Double(max(1, store.totalBytes)))
                    .progressViewStyle(.linear)
                Text("\(store.completedFiles) / \(store.fileCount) 个文件 · \(ByteCountFormatter.string(fromByteCount: store.sentBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: store.totalBytes, countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = store.errorMessage {
                ScrollView { Text(error).foregroundStyle(.red).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 100)
            }
            Text("上传期间请保持 Mac 和应用运行；提交成功后，NAS 会继续后台整理。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(store.job == nil ? "关闭" : "完成") { dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(store.isBusy || creatingDirectory)
                if !store.isBusy, store.manifest != nil, store.job == nil {
                    Button("重新选择…") { store.reset() }
                        .help("保留 NAS 已接收的文件，以新批次重新导入")
                }
                Spacer()
                if store.isBusy {
                    Button("暂停上传") { store.pause() }
                } else if store.job == nil {
                    Button(store.manifest == nil ? "开始导入" : "继续导入") { store.start(targetPath: targetPath ?? "") }
                        .keyboardShortcut(.defaultAction)
                        .disabled(store.source == nil || targetPath == nil || loadingDirectories || creatingDirectory || directoryError != nil)
                }
            }
        }
        .padding(24).frame(width: 660)
        .interactiveDismissDisabled(store.isBusy || creatingDirectory)
        .fileImporter(isPresented: $choosingSource, allowedContentTypes: [.folder]) { result in
            switch result {
            case let .success(url): store.selectSource(url)
            case let .failure(error): store.report(error)
            }
        }
        .alert("新建文件夹", isPresented: $showingNewFolder) {
            TextField("文件夹名称", text: $newFolderName)
            Button("取消", role: .cancel) {}
            Button("创建") { Task { await createDirectory() } }
                .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("在当前 NAS 目标目录中创建，创建后自动选为导入目标。")
        }
        .task { if store.manifest == nil { await loadDirectory(targetPath, remember: false) } }
    }

    private var targetBrowser: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("NAS 目标文件夹").font(.headline)
                Spacer()
                Button("新建文件夹…") {
                    newFolderName = ""
                    creationError = nil
                    showingNewFolder = true
                }.disabled(targetPath == nil || directoryError != nil)
                Button("返回") {
                    let previous = history.isEmpty ? nil : history.removeLast()
                    Task { await loadDirectory(previous, remember: false) }
                }.disabled(targetPath == nil || (history.isEmpty && targetPath == rootPath))
            }
            if loadingDirectories || creatingDirectory {
                ProgressView(creatingDirectory ? "正在创建 NAS 文件夹…" : "正在读取 NAS 目录…")
                    .progressViewStyle(.linear)
            }
            Text(targetPath ?? "请选择服务器目录")
                .font(.caption).textSelection(.enabled)
            List(directories) { directory in
                Button {
                    Task { await loadDirectory(directory.path, remember: true) }
                } label: {
                    Label(directory.name, systemImage: "folder").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }.frame(height: 150)
            if let creationError {
                Text(creationError).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if let directoryError {
                Text(directoryError).font(.caption).foregroundStyle(.red)
                Button("重试读取目录") { Task { await loadDirectory(targetPath, remember: false) } }
            } else if targetPath != nil {
                Text(store.preserveStructure
                     ? "以上方路径为根目录保留子目录层级。点击子文件夹可更换目标。"
                     : "文件将直接导入上方路径。点击子文件夹可更换目标。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.disabled(loadingDirectories || creatingDirectory || store.isBusy || store.manifest != nil)
    }

    @MainActor private func createDirectory() async {
        guard let targetPath, !creatingDirectory else { return }
        creatingDirectory = true
        defer { creatingDirectory = false }
        do {
            let createdPath = try await store.client.createDirectory(
                parentPath: targetPath,
                name: newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            creationError = nil
            await loadDirectory(createdPath, remember: true)
        } catch {
            creationError = String(reflecting: error) + "\n" + error.localizedDescription
        }
    }

    @MainActor private func loadDirectory(_ path: String?, remember: Bool) async {
        guard !loadingDirectories else { return }
        loadingDirectories = true
        defer { loadingDirectories = false }
        do {
            if rootPath == nil { rootPath = try await store.client.folders().rootPath }
            let resolvedPath = path ?? rootPath
            let response = try await store.client.navigation(path: resolvedPath)
            if remember { history.append(targetPath) }
            targetPath = resolvedPath
            directories = response.directories
            directoryError = nil
        } catch {
            directoryError = String(reflecting: error) + "\n" + error.localizedDescription
        }
    }
}
