import SwiftUI
import KeepsAPI

@main
struct PhotoAssetManagerApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var library = LibraryStore()
    @StateObject private var importTasks = ImportTaskOwner()
    @StateObject private var exposureTasks = ExposureTaskStore()
    @FocusedValue(\.gallerySelection) private var gallerySelection
    var body: some Scene {
        WindowGroup {
            LibraryStartupView().environmentObject(library).environmentObject(exposureTasks).environmentObject(importTasks).frame(minWidth: 1080, minHeight: 720)
        }
        .onChange(of: library.configuration, initial: true) { _, _ in
            importTasks.configure(library.client) { library.refreshNavigation(); library.refresh(force: true) }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in library.setActive(phase == .active) }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(after: .pasteboard) {
                if let gallerySelection {
                    Button("全选照片", action: gallerySelection.selectAll)
                        .keyboardShortcut("a", modifiers: .command)
                        .disabled(!library.isStartupReady || library.isDirectoryOperationBlocking)
                    Button("取消选择照片", action: gallerySelection.deselectAll)
                        .keyboardShortcut("a", modifiers: [.command, .shift])
                        .disabled(!library.isStartupReady || library.isDirectoryOperationBlocking)
                }
            }
            CommandGroup(after: .sidebar) {
                Toggle("过滤隐藏目录内容", isOn: $library.hiddenDirectoryFilterEnabled).disabled(!library.isStartupReady || library.isDirectoryOperationBlocking)
            }
            CommandMenu("照片") {
                Button("删除所有弃用照片…") { library.showsRejectedTrash = true }
                    .disabled(!library.isStartupReady || library.client == nil || library.isDirectoryOperationBlocking || library.isMutating || library.isCheckingConnection || exposureTasks.tasks.contains { !$0.failed && $0.phase != .completed })
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
                }.disabled(!library.isStartupReady || library.isDirectoryOperationBlocking || library.isSelectingAll)
            }
        }
        Window("任务追踪", id: "nas-tasks") {
            Group {
                if let client = library.client {
                    NASTasksView(client: client).id(ObjectIdentifier(client))
                } else {
                    Text("请先在设置中连接服务器。").padding(24)
                }
            }.disabled(library.isDirectoryOperationBlocking)
            .overlay { if library.isDirectoryOperationBlocking { Text("正在整理照片或文件夹，请在主窗口查看进度。").padding().background(.regularMaterial) } }
        }
        .windowResizability(.contentSize)
        Settings {
            TabView {
                ServerSettingsView()
                    .tabItem { Label("服务器", systemImage: "server.rack") }
                Group {
                    if library.isStartupReady, let client = library.client {
                        NASSourceSettingsView(client: client).id(ObjectIdentifier(client))
                    } else {
                        Text("请先在服务器设置中验证并保存连接。")
                            .padding(24)
                    }
                }
                .tabItem { Label("来源", systemImage: "folder") }
            }
            .environmentObject(library)
            .disabled(library.isDirectoryOperationBlocking)
            .overlay { if library.isDirectoryOperationBlocking { Text("正在整理照片或文件夹，请在主窗口查看进度。").padding().background(.regularMaterial) } }
        }
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
