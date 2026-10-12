import SwiftUI
import KeepsAPI

@main
struct PhotoAssetManagerApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var library = LibraryStore()
    @StateObject private var exposureTasks = ExposureTaskStore()
    @StateObject private var importTasks = ImportTaskOwner()
    @StateObject private var batch = AIEditingBatchStore()
    @StateObject private var geometryTasks = GeometryTaskStore()
    @FocusedValue(\.aiWorkspace) private var aiWorkspace
    @FocusedValue(\.gallerySelection) private var gallerySelection
    var body: some Scene {
        WindowGroup {
            LibraryStartupView().environmentObject(library).environmentObject(batch).environmentObject(geometryTasks).environmentObject(importTasks).environmentObject(exposureTasks).frame(minWidth: 1080, minHeight: 720)
                .onReceive(batch.editor.$isBusy, perform: synchronizeEditorActivity)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in batch.stopForExit() }
        }
        .onChange(of: library.configuration, initial: true) { _, _ in
            exposureTasks.configure(library.rejectedTrash == nil ? library.configuration : nil)
            importTasks.configure(library.client, activity: { library.isImportWorkerActive = $0 }) { library.refreshNavigation(); library.refresh(force: true) }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in library.setActive(phase == .active) }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(after: .pasteboard) {
                if let gallerySelection {
                    Button("全选照片", action: gallerySelection.selectAll)
                        .keyboardShortcut("a", modifiers: .command)
                        .disabled(!library.isStartupReady || library.isOperationBlocking)
                    Button("取消选择照片", action: gallerySelection.deselectAll)
                        .keyboardShortcut("a", modifiers: [.command, .shift])
                        .disabled(!library.isStartupReady || library.isOperationBlocking)
                }
            }
            CommandGroup(after: .sidebar) {
                Toggle("过滤隐藏目录内容", isOn: $library.hiddenDirectoryFilterEnabled).disabled(!library.isStartupReady || library.isOperationBlocking)
            }
            CommandMenu("照片") {
                Button("打开 AI 调色工作台") { aiWorkspace?.open() }
                    .disabled(!library.isStartupReady || aiWorkspace == nil || library.isOperationBlocking)
                Button("删除所有弃用照片…") { library.openRejectedTrash() }
                    .disabled(!library.isStartupReady || library.client == nil || library.isOperationBlocking || library.isMutating || library.isCheckingConnection || library.isImportingPhotos || batch.isRunning || batch.editor.isBusy)
                Button("清空 Keeps 回收站…") { library.openRejectedTrash(emptyingTrash: true) }
                    .disabled(!library.isStartupReady || library.client == nil || library.isOperationBlocking || library.isMutating || library.isCheckingConnection || library.isImportingPhotos || batch.isRunning || batch.editor.isBusy)
                Divider()
                Group {
                Button("上一张") { library.selectAdjacent(-1) }
                Button("下一张") { library.selectAdjacent(1) }
                Divider()
                ForEach(0...5, id: \.self) { rating in
                    Button(rating == 0 ? "清除评分" : "\(rating) 星") { library.updateSelected(KeepsAssetPatch(rating: rating)) }
                        .keyboardShortcut(KeyEquivalent(Character(String(rating))), modifiers: [])
                }
                .disabled(library.selectedIDs.isEmpty || library.isMutating || library.isSelectingAll)
                Divider()
                Button("留用") { library.updateSelected(KeepsAssetPatch(flagState: "picked")) }.keyboardShortcut("p", modifiers: [])
                Button("排除") { library.updateSelected(KeepsAssetPatch(flagState: "rejected")) }.keyboardShortcut("x", modifiers: [])
                Button("清除标记") { library.updateSelected(KeepsAssetPatch(flagState: "unflagged")) }.keyboardShortcut("u", modifiers: [])
                }.disabled(!library.isStartupReady || library.isOperationBlocking || library.isSelectingAll)
            }
        }
        Settings {
            TabView {
                ServerSettingsView()
                    .disabled(library.isOperationBlocking)
                    .tabItem { Label("服务器", systemImage: "server.rack") }
                Group {
                    if library.isStartupReady, let client = library.client {
                        NASSourceSettingsView(client: client).id(ObjectIdentifier(client))
                    } else {
                        Text("请先在服务器设置中验证并保存连接。")
                            .padding(24)
                    }
                }
                .disabled(library.isOperationBlocking)
                .tabItem { Label("来源", systemImage: "folder") }
                Group {
                    if library.isStartupReady, let client = library.client {
                        TrashSettingsView(client: client).id(ObjectIdentifier(client))
                    } else {
                        Text("请先验证并保存服务器连接。").padding(24)
                    }
                }
                .disabled(library.isOperationBlocking)
                .tabItem { Label("回收站", systemImage: "trash") }
                AIEditingSettingsView(store: batch.editor)
                    .disabled(library.isImportingPhotos || library.isMutating || library.isCheckingConnection || library.isUpdatingHiddenDirectory || library.directoryToRename != nil || library.directoryToTrash != nil)
                    .tabItem { Label("AI 修图", systemImage: "wand.and.stars") }
            }
            .environmentObject(library)
            .onReceive(batch.editor.$isBusy, perform: synchronizeEditorActivity)
            .disabled(library.isCullingActive || library.isDirectoryOperationBlocking || batch.isRunning)
            .overlay {
                if library.isDirectoryOperationBlocking || batch.isRunning {
                    Text(batch.isRunning ? "正在进行 AI 调色，请在调色工作台查看进度。" : "正在整理照片或文件夹，请在主窗口查看进度。")
                        .padding().background(.regularMaterial)
                }
            }
        }
    }

    private func synchronizeEditorActivity(_ editorBusy: Bool) {
        let busy = editorBusy && !batch.editor.batchActive
        guard library.isAISettingsBusy != busy else { return }
        library.isAISettingsBusy = busy
        if busy { library.pauseLibraryForDirectoryOperation() }
        else if !library.isOperationBlocking { library.refresh(force: true) }
    }
}

private struct LibraryStartupView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var showsSettings = false

    private struct Request: Equatable {
        let showsSettings: Bool
        let configuration: KeepsConfiguration?
    }

    var body: some View {
        Group {
            if library.isStartupReady {
                ContentView()
            } else {
                VStack(spacing: 20) {
                    ProgressView()
                    Text("正在载入资料库").font(.title2)
                    if library.startupAttempt > 0 {
                        Text("第 \(library.startupAttempt) / 10 次尝试").foregroundStyle(.secondary)
                    }
                    if let seconds = library.startupRetrySeconds {
                        Text("连接失败，\(seconds) 秒后自动重试。")
                    }
                    if let error = library.startupError {
                        Text(error).font(.callout).foregroundStyle(.secondary)
                            .textSelection(.enabled).frame(maxWidth: 560)
                    }
                    Button("修改资料库位置…") { showsSettings = true }
                }
                .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $showsSettings) {
            VStack {
                ServerSettingsView()
                Button("返回") { showsSettings = false }.padding(.bottom, 20)
            }
        }
        .task(id: Request(showsSettings: showsSettings, configuration: library.configuration)) {
            guard !showsSettings else { return }
            await library.loadStartupLibrary()
            if library.startupExhausted, !Task.isCancelled { NSApplication.shared.terminate(nil) }
        }
        .onChange(of: library.configuration) { _, _ in
            if showsSettings { showsSettings = false }
        }
    }
}
