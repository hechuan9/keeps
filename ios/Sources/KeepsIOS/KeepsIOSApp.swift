import SwiftUI
import KeepsAPI
import BackgroundTasks
import OSLog

@main
struct KeepsIOSApp: App {
    @UIApplicationDelegateAdaptor(ThumbnailBackgroundDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var library = IOSLibraryStore()
    var body: some Scene {
        WindowGroup { IOSRootView().environmentObject(library) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { ThumbnailBackgroundDelegate.schedule() }
            }
    }
}

struct IOSRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var library: IOSLibraryStore
    @StateObject private var directories = IOSDirectoryStore()
    @ObservedObject private var thumbnailDownload = IOSThumbnailDownload.shared
    @State private var showingSettings = false
    @State private var showingSearch = false
    @State private var collections = false
    @State private var collectionPath: [IOSCollectionRoute] = []
    @State private var showingDirectories = false
    @State private var selecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var visibleDates = ""
    @State private var changing = false
    @State private var confirmTrash = false
    @State private var galleryReady = false
    @State private var startupError: String?
    @State private var preparationAttempt = 0
    @AppStorage("galleryStyle") private var galleryStyle: KeepsGalleryStyle = .square
    @AppStorage("galleryDensity") private var density: KeepsGalleryDensity = .large

    private var showsGallery: Bool { !collections || !collectionPath.isEmpty }
    private var title: String {
        if !showsGallery { return "精选集" }
        if library.showingTrash { return "回收站" }
        return library.showingPicked ? "精选" : "图库"
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if library.configuration != nil && !galleryReady {
                startupScreen
            } else if collections {
                NavigationStack(path: $collectionPath) {
                    IOSCollectionsView(configuration: library.configuration, navigation: directories)
                        .overlay(alignment: .bottom) { bottomBar }
                        .navigationTitle("精选集")
                        .toolbar {
                            ToolbarItemGroup(placement: .topBarTrailing) {
                                Button("连接设置", systemImage: "gearshape") { showingSettings = true }
                            }
                        }
                        .navigationDestination(for: IOSCollectionRoute.self) { route in
                            galleryPage(route: route)
                            .overlay(alignment: .bottom) { bottomBar }
                            .toolbar(.hidden, for: .navigationBar)
                            .disabled(changing)
                        }
                }
            } else {
                galleryPage().overlay(alignment: .bottom) { bottomBar }
            }
        }
        .preferredColorScheme(.dark)
        .tint(.white)
        .sheet(isPresented: $showingSettings) {
            IOSSettingsView(configuration: library.configuration) {
                library.reloadConfiguration(); Task { await library.refresh() }
            }
        }
        .sheet(isPresented: $library.showingTrashCleanup) {
            IOSTrashCleanupSheet(library: library)
        }
        .sheet(isPresented: $showingSearch) {
            IOSSearchSheet(query: library.search) { query in
                collections = false; collectionPath = []
                library.showingTrash = false; library.showingPicked = false; library.directory = nil
                library.search = query; resetSelection()
                Task { await library.refresh() }
            }
        }
        .confirmationDialog("将所选照片移入回收站？原片不会删除。", isPresented: $confirmTrash, titleVisibility: .visible) {
            Button("移入回收站", role: .destructive) { Task { await changeSelection(trash: true) } }
        }
        .task(id: library.configuration) { await prepareLibrary() }
        .onReceive(NotificationCenter.default.publisher(for: NSUbiquitousKeyValueStore.didChangeExternallyNotification)) { _ in
            restoreCloudConnection()
        }
        .task(id: galleryReady && scenePhase == .active) {
            if galleryReady, scenePhase == .active, let configuration = library.configuration {
                await updateLibrarySilently(configuration: configuration)
            }
        }
        .onChange(of: thumbnailDownload.isComplete) { _, complete in
            if complete { galleryReady = true }
        }
        .onChange(of: library.configuration, initial: true) { _, configuration in
            collections = false
            galleryReady = false
            startupError = nil
            preparationAttempt += 1
            let cloud = NSUbiquitousKeyValueStore.default
            if let configuration {
                cloud.set(configuration.baseURL.absoluteString, forKey: "keeps.connection.baseURL")
                cloud.set(configuration.libraryID, forKey: "keeps.connection.libraryID")
            }
            cloud.synchronize()
            if configuration == nil { Task { restoreCloudConnection() } }
            thumbnailDownload.configurationChanged(configuration)
            directories.configure(configuration)
            directories.synchronize = { await library.synchronize() }
            collectionPath = []
            library.directory = nil
            library.showingPicked = false
            library.showingTrash = false
            library.search = ""
            resetSelection()
        }
        .onChange(of: library.databaseRevision) { _, _ in directories.reload() }
        .onChange(of: collectionPath) { _, _ in
            if collections { applyCollectionScope() }
        }
        .onChange(of: library.timeline) { _, entries in
            if entries.isEmpty { visibleDates = "" }
        }
    }

    private func restoreCloudConnection() {
        guard library.configuration == nil else { return }
        let cloud = NSUbiquitousKeyValueStore.default
        guard let baseURL = cloud.string(forKey: "keeps.connection.baseURL"),
              let libraryID = cloud.string(forKey: "keeps.connection.libraryID") else { return }
        UserDefaults.standard.set(baseURL, forKey: KeepsSettings.baseURLKey)
        UserDefaults.standard.set(libraryID, forKey: KeepsSettings.libraryIDKey)
        library.reloadConfiguration()
    }

    private func prepareLibrary() async {
        guard let configuration = library.configuration else { return }
        await library.waitForLocalLoad()
        guard !Task.isCancelled else { return }
        if let error = library.lastError { startupError = error; return }
        if library.hasLocalCatalog { galleryReady = true; return }
        await thumbnailDownload.prepare(configuration: configuration, refreshLocal: { await library.refresh() }) { forceRebuild, progress in
            try await library.synchronizeChecked(forceRebuild: forceRebuild, includeThumbnails: false, progress: progress)
        }
        guard !Task.isCancelled, library.configuration == configuration else { return }
        if thumbnailDownload.isComplete { galleryReady = true }
    }

    private func updateLibrarySilently(configuration: KeepsConfiguration) async {
        await ThumbnailBackgroundDelegate.activeWork?.value
        guard !Task.isCancelled, library.configuration == configuration else { return }
        do {
            try await library.synchronizeChecked()
            try Task.checkCancellation()
            _ = await ThumbnailPrefetch.shared.runLocal(configuration: configuration, downloadMissing: true)
            try Task.checkCancellation()
            try await KeepsCloudReplica.shared.backup(configuration: configuration)
        } catch {
            guard !Task.isCancelled else { return }
            Logger(subsystem: "com.hechuan.Keeps", category: "library-maintenance")
                .error("Silent library update failed: \(String(reflecting: error), privacy: .public)")
        }
    }

    private var startupScreen: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 20) {
                Text("正在打开图库").font(.title2.bold())
                if library.isLoadingLocal {
                    ProgressView().progressViewStyle(.linear)
                    Text("正在读取本机照片目录…").foregroundStyle(.secondary)
                } else {
                    IOSOfflineProgressView(download: thumbnailDownload)
                }
                if let error = startupError ?? thumbnailDownload.error {
                    Text("图库暂时无法打开，请重试或检查连接设置。")
                        .multilineTextAlignment(.center)
                    DisclosureGroup("错误详情") {
                        ScrollView {
                            Text(error).font(.caption).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 160)
                    }.font(.caption)
                }
                if thumbnailDownload.isRunning {
                    Button("暂停") { thumbnailDownload.pause() }
                } else if !library.isLoadingLocal {
                    Button("继续") {
                        startupError = nil
                        preparationAttempt += 1
                        Task {
                            await library.refresh()
                            await prepareLibrary()
                        }
                    }
                }
                Text("照片目录准备好后即可浏览和滚动；缩略图自动在后台下载，缺图时显示占位图。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("连接设置") { showingSettings = true }
            }.padding(32)
        }.accessibilityIdentifier("library-startup")
    }

    private func galleryPage(route: IOSCollectionRoute? = nil) -> some View {
        return VStack(spacing: 0) {
            if let error = library.syncError {
                HStack {
                    Text("同步失败，正在显示本地图库").font(.caption)
                        .accessibilityHint(error)
                    Spacer()
                    Button("重试") { Task { await library.synchronize() } }
                }.padding(8).background(.thinMaterial)
            }
            ZStack {
                if library.configuration == nil {
                    ContentUnavailableView("连接 NAS 图库", systemImage: "externaldrive", description: Text("在连接设置中填写服务地址和访问令牌。"))
                } else if !galleryReady && library.timeline.isEmpty {
                    startupScreen
                } else if library.timeline.isEmpty {
                    ScrollView {
                        Group {
                            if library.isLoadingLocal { ProgressView("正在打开图库…") }
                            else if library.isSyncing && !library.hasLoadedResults { ProgressView("正在建立本地图库…") }
                            else { ContentUnavailableView(library.lastError == nil ? "没有照片" : "无法加载图库", systemImage: library.lastError == nil ? "photo" : "wifi.exclamationmark", description: Text("照片会自动同步")) }
                        }.frame(maxWidth: .infinity, minHeight: 300)
                    }
                } else {
                    IOSWaterfallGallery(selecting: $selecting, selectedIDs: $selectedIDs, density: $density, visibleDates: $visibleDates,
                                        style: galleryStyle, preparationFinished: { _ in })
                        .id("\(library.configuration?.baseURL.absoluteString ?? "")|\(library.configuration?.libraryID ?? "")|\(preparationAttempt)|\(library.showingTrash)|\(library.showingPicked)|\(library.search)|\(library.directory ?? "")")
                        .allowsHitTesting(!changing)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .backgroundExtensionEffect()
            .overlay(alignment: .top) {
                galleryStatus
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .top) {
                if let route, route.hasChildren, showingDirectories, !selecting {
                    IOSDirectoryBrowser(configuration: library.configuration, path: route.directory, navigation: directories)
                        .id(route.directory)
                        .disabled(changing)
                }
            }
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            header(route: route).disabled(changing)
        }
        .background { Color.black.ignoresSafeArea() }
    }

    @ViewBuilder
    private var galleryStatus: some View {
        if let error = library.lastError {
            VStack(spacing: 6) {
                Text(error).font(.caption).lineLimit(3)
                Text("照片会自动同步").font(.caption)
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
        }
    }

    private func header(route: IOSCollectionRoute?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                if route != nil {
                    Button {
                        collectionPath.removeLast()
                    } label: {
                        Image(systemName: "chevron.left").frame(width: 44, height: 44)
                    }.glassEffect(.regular.interactive(), in: Circle())
                        .accessibilityLabel("返回上一级")
                }
                Text(selecting ? "已选 \(selectedIDs.count) 张" : route?.title ?? title).font(.largeTitle.bold()).lineLimit(1).minimumScaleFactor(0.6)
                Spacer()
                if showsGallery {
                    if let route, route.hasChildren, !selecting {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { showingDirectories.toggle() }
                        } label: {
                            Image(systemName: showingDirectories ? "folder.fill" : "folder").frame(width: 44, height: 44)
                        }.glassEffect(.regular.interactive(), in: Circle())
                            .accessibilityLabel(showingDirectories ? "收起子文件夹" : "显示子文件夹")
                    }
                    Menu {
                        Button("放大", systemImage: "plus.magnifyingglass") {
                            density = density.pinched(magnification: 1.4)
                        }.disabled(density == .single)
                        Button("缩小", systemImage: "minus.magnifyingglass") {
                            density = density.pinched(magnification: 0.7)
                        }.disabled(density == .compact)
                        Picker("网格布局", selection: $galleryStyle) {
                            Text("方形网格").tag(KeepsGalleryStyle.square)
                            Text("原始比例网格").tag(KeepsGalleryStyle.aspectRatio)
                        }
                        Divider()
                        if library.showingTrash {
                            Button("清空 Keeps 回收站…", role: .destructive) {
                                library.showingTrashCleanup = true
                            }.disabled(changing)
                        }
                        Button("连接设置", systemImage: "gearshape") { showingSettings = true }
                    } label: { Image(systemName: "line.3.horizontal.decrease").frame(width: 44, height: 44) }
                        .glassEffect(.regular.interactive(), in: Circle()).accessibilityLabel("图库选项")
                    Button(selecting ? "取消" : "选择") {
                        selecting.toggle(); selectedIDs.removeAll()
                    }.padding(.horizontal, 18).frame(height: 44)
                        .glassEffect(.regular.interactive(), in: Capsule()).disabled(changing)
                } else {
                    Button { showingSettings = true } label: { Image(systemName: "gearshape").frame(width: 44, height: 44) }
                        .glassEffect(.regular.interactive(), in: Circle()).accessibilityLabel("连接设置")
                }
            }
            if route == nil && showsGallery && !visibleDates.isEmpty { Text(visibleDates).font(.subheadline.weight(.semibold)) }
            if !library.search.isEmpty && showsGallery { Text("搜索：\(library.search)").font(.caption) }
        }
        .foregroundStyle(.white).padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 18)
        .background(.ultraThinMaterial)
    }

    private var bottomBar: some View {
        GlassEffectContainer(spacing: 20) {
            HStack(spacing: 16) {
                if selecting {
                    HStack(spacing: 22) {
                        Button("全选当前屏幕") { selectedIDs = library.visibleIDs }
                        Spacer(minLength: 0)
                        Button { Task { await changeSelection(trash: false) } } label: {
                            Image(systemName: library.showingTrash ? "arrow.uturn.backward" : "heart")
                        }.accessibilityLabel(library.showingTrash ? "恢复所选照片" : "留用所选照片")
                        if !library.showingTrash {
                            Button { confirmTrash = true } label: { Image(systemName: "trash") }
                                .accessibilityLabel("移入回收站").disabled(selectedIDs.isEmpty)
                        }
                    }.disabled(changing || library.trashCleanupBusy).padding(20).glassEffect(.regular, in: Capsule())
                } else {
                    HStack(spacing: 4) {
                        tabButton("图库", icon: "photo.on.rectangle.fill", active: !collections) {
                            guard collections else { return }
                            collections = false; setScope(nil)
                        }
                        tabButton("精选集", icon: "rectangle.stack.fill", active: collections) {
                            guard !collections else { return }
                            collections = true; applyCollectionScope()
                        }
                    }.padding(5).glassEffect(.regular, in: Capsule())
                    Spacer(minLength: 0)
                    Button { showingSearch = true } label: {
                        Image(systemName: "magnifyingglass").font(.title2).frame(width: 60, height: 60)
                    }.glassEffect(.regular.interactive(), in: Circle()).accessibilityLabel("搜索")
                }
            }
        }.padding(.horizontal, 20).padding(.bottom, 10)
    }

    private func tabButton(_ label: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) { Image(systemName: icon).font(.title3); Text(label).font(.caption.weight(.semibold)) }
                .frame(width: 86, height: 50).foregroundStyle(active ? Color.cyan : .white)
                .background(active ? Color.white.opacity(0.15) : .clear, in: Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(active ? .isSelected : [])
    }

    private func resetSelection() { selecting = false; selectedIDs.removeAll(); visibleDates = ""; showingDirectories = false }

    private func applyCollectionScope() {
        resetSelection()
        guard let route = collectionPath.last else { return }
        setScope(route)
    }

    private func setScope(_ route: IOSCollectionRoute?) {
        library.showingPicked = false
        library.showingTrash = false
        library.directory = route?.directory
        library.search = ""

        resetSelection()
        Task { await library.refresh() }
    }

    private func changeSelection(trash: Bool) async {
        guard let configuration = library.configuration, !selectedIDs.isEmpty else { return }
        changing = true
        defer { changing = false }
        let client = KeepsClient(configuration: configuration)
        do {
            for id in Array(selectedIDs) {
                let asset: KeepsAsset
                if trash { asset = try await client.trashAsset(id: id) }
                else if library.showingTrash { asset = try await client.restoreAsset(id: id) }
                else { asset = try await client.updateAsset(id: id, patch: KeepsAssetPatch(flagState: "picked")) }
                await library.update(asset); selectedIDs.remove(id)
            }
            resetSelection()
        } catch { library.lastError = String(reflecting: error) }
    }
}

struct IOSSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var query: String
    @FocusState private var focused: Bool
    let submit: (String) -> Void
    var body: some View {
        NavigationStack {
            Form {
                TextField("文件名或相机", text: $query).focused($focused).submitLabel(.search)
                    .onSubmit { submit(query); dismiss() }
                Button("显示全部照片") { submit(""); dismiss() }
            }
            .navigationTitle("搜索")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("搜索") { submit(query); dismiss() } }
            }.onAppear { focused = true }
        }.presentationDetents([.medium, .large])
    }
}

struct IOSSettingsView: View {
    @ObservedObject private var download = IOSThumbnailDownload.shared
    @Environment(\.dismiss) private var dismiss
    @State private var baseURL: String
    @State private var libraryID: String
    @State private var token: String
    @State private var error: String?
    @State private var isChecking = false
    let configuration: KeepsConfiguration?
    var didSave: () -> Void

    init(configuration: KeepsConfiguration?, didSave: @escaping () -> Void) {
        _baseURL = State(initialValue: configuration?.baseURL.absoluteString ?? "https://keeps.hechuannas.synology.me")
        _libraryID = State(initialValue: configuration?.libraryID ?? "local-library")
        _token = State(initialValue: configuration?.accessCredential ?? "")
        self.configuration = configuration
        self.didSave = didSave
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("离线图库进度") {
                    IOSOfflineProgressView(download: download)
                }
                Section("iCloud 副本") {
                    Text(download.cloudStatus).font(.subheadline)
                    Text("仅保存 Keeps 数据库快照和缩略图，不会加入系统照片库。同一 iCloud 账户重装后恢复图库连接和已保存的副本；访问令牌仍只保留在本机钥匙串。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let configuration {
                    Section("Keeps 回收站") {
                        NavigationLink("自动清理设置") { IOSTrashSettingsView(configuration: configuration) }
                    }
                }
                Section("NAS 服务") {
                    TextField("服务地址", text: $baseURL).keyboardType(.URL)
                    TextField("图库 ID", text: $libraryID)
                    SecureField("访问令牌", text: $token)
                }.textInputAutocapitalization(.never).autocorrectionDisabled().disabled(isChecking)
                Section {
                    Text("照片、评分、标签和回收站状态由 NAS 保存。此设备保存可离线浏览的图库副本与图片缓存，联网时从 NAS 同步更新。")
                    Text("删除照片先进入 Keeps 回收站；手动清空或自动清理将文件移入 NAS 回收站，并清理图库资料和缓存。")
                    Text("使用 HTTPS 服务地址时，Wi-Fi 和蜂窝网络均可连接。使用局域网地址时，请允许本地网络访问并连接 NAS 所在网络。")
                }
                if isChecking { ProgressView("正在验证 NAS 连接…") }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
            .interactiveDismissDisabled(isChecking)
            .navigationTitle("连接设置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(isChecking) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("验证并保存") { Task { await verifyAndSave() } }
                        .disabled(isChecking)
                }
            }
        }
    }

    @MainActor
    private func verifyAndSave() async {
        guard !isChecking else { return }
        isChecking = true
        error = nil
        defer { isChecking = false }
        do {
            let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let library = libraryID.trimmingCharacters(in: .whitespacesAndNewlines)
            let credential = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: base), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil, url.user == nil, url.password == nil, url.query == nil,
                  url.fragment == nil, !library.isEmpty else { throw KeepsAPIError.invalidConfiguration }
            let client = KeepsClient(configuration: KeepsConfiguration(baseURL: url, libraryID: library,
                                                                       accessCredential: credential.isEmpty ? nil : credential))
            _ = try await client.counts()
            var probe = KeepsAssetQuery()
            probe.limit = 1
            _ = try await client.assets(query: probe)
            try Task.checkCancellation()
            try KeepsSettings.save(baseURLString: base, libraryID: library, accessCredential: credential)
            didSave()
            dismiss()
        } catch { self.error = error.localizedDescription + "\n" + String(reflecting: error) }
    }
}


@MainActor
final class ThumbnailBackgroundDelegate: NSObject, UIApplicationDelegate {
    static var activeWork: Task<Void, Never>?
    private static let identifier = "local.keeps.thumbnail-prefetch"
    private static let logger = Logger(subsystem: "local.keeps", category: "thumbnail-background")

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: .main) { task in
            let work = Task { @MainActor in
                Self.schedule()
                guard !IOSThumbnailDownload.shared.isRunning else {
                    task.setTaskCompleted(success: true)
                    return
                }
                do {
                    guard let configuration = try KeepsSettings.load() else {
                        task.setTaskCompleted(success: true)
                        return
                    }
                    guard try await IOSCatalogReader().hasCatalog(configuration: configuration) else {
                        task.setTaskCompleted(success: true)
                        return
                    }
                    Self.logger.info("Background thumbnail task started")
                    let library = IOSLibraryStore(configuration: configuration, loadSettings: false)
                    try await library.synchronizeChecked()
                    guard !Task.isCancelled else { task.setTaskCompleted(success: false); return }
                    let completed = await ThumbnailPrefetch.shared.runLocal(configuration: configuration, downloadMissing: true)
                    try Task.checkCancellation()
                    try await KeepsCloudReplica.shared.backup(configuration: configuration)
                    Self.logger.info("Background thumbnail task finished: success=\(completed), cancelled=\(Task.isCancelled)")
                    task.setTaskCompleted(success: completed && !Task.isCancelled)
                } catch {
                    Self.logger.error("Background thumbnails failed: \(String(reflecting: error), privacy: .public)")
                    task.setTaskCompleted(success: false)
                }
            }
            Self.activeWork = work
            task.expirationHandler = { work.cancel() }
        }
        if !registered { Self.logger.error("Background thumbnail task registration failed") }
        return true
    }

    static func schedule() {
        Task { @MainActor in
            let pending = await BGTaskScheduler.shared.pendingTaskRequests()
            guard !pending.contains(where: { $0.identifier == identifier }) else { return }
            let request = BGProcessingTaskRequest(identifier: identifier)
            request.requiresNetworkConnectivity = true
            request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
            do { try BGTaskScheduler.shared.submit(request) }
            catch { logger.error("Background thumbnail scheduling failed: \(String(reflecting: error), privacy: .public)") }
        }
    }
}

private struct IOSOfflineProgressView: View {
    @ObservedObject var download: IOSThumbnailDownload

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(download.status)
                Spacer()
                Text("\(download.systemProgress.percentage)%").monospacedDigit()
            }.font(.caption)
            ProgressView(value: download.systemProgress.fractionCompleted)
        }
        .accessibilityElement(children: .combine)
    }
}


struct IOSTrashCleanupSheet: View {
    @ObservedObject var library: IOSLibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmation = ""

    var body: some View {
        NavigationStack {
            Form {
                Text("Keeps 回收站内所有照片及关联文件将移入 NAS 回收站，图库资料和缓存将清理。文件可从 NAS File Station 回收站恢复。")
                if let task = library.trashCleanup {
                    Text("照片：\(task.count) 张；关联文件：\(task.totalFiles) 个")
                    if task.status == "draft" && !library.trashCleanupBusy {
                        TextField("输入照片总数 \(task.count) 确认", text: $confirmation).keyboardType(.numberPad)
                        Button("移入 NAS 回收站", role: .destructive) { library.submitTrashCleanup(confirmation) }
                            .disabled(!library.canConfirmTrashCleanup(confirmation))
                    }
                    if library.trashCleanupBusy && task.status != "draft" {
                        ProgressView(value: Double(task.completedFiles), total: Double(max(1, task.totalFiles)))
                        Text("已回收文件：\(task.completedFiles) / \(task.totalFiles)")
                    }
                    if task.status == "completed" { Text("已完成清空 Keeps 回收站。") }
                }
                if library.trashCleanupBusy { ProgressView("正在查询 NAS 回收任务…") }
                Text("任务由 NAS 后台独立执行，退出应用不影响任务；重新打开后继续查询。离线时不能创建清空任务。")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = library.trashCleanupError {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                    if library.hasPendingTrashCleanup && !library.trashCleanupBusy {
                        Button("重新查询同一任务") { library.resumeTrashCleanup() }
                    }
                    if !library.hasPendingTrashCleanup && library.trashCleanup == nil && !library.trashCleanupBusy {
                        Button("重新预览") { Task { await library.previewTrashCleanup() } }
                    }
                }
            }
            .navigationTitle("清空 Keeps 回收站")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { library.closeTrashCleanup(); dismiss() }
                }
            }
        }
        .task { if library.trashCleanup == nil && !library.trashCleanupBusy { await library.previewTrashCleanup() } }
    }
}

struct IOSTrashSettingsView: View {
    let configuration: KeepsConfiguration
    @State private var settings = KeepsTrashSettings()
    @State private var loaded = false
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        Form {
            Toggle("自动清理 Keeps 回收站", isOn: $settings.enabled)
            HStack {
                Text("保留天数")
                TextField("30", value: $settings.retentionDays, format: .number).keyboardType(.numberPad)
            }.disabled(!settings.enabled)
            Text("可设置 1–3650 天。NAS 后台清理到期照片：原片和关联文件进入 DSM 回收站，图库资料与缓存同时清理。此设置作用于整个资料库。")
                .font(.caption).foregroundStyle(.secondary)
            Button("保存") {
                Task {
                    busy = true
                    defer { busy = false }
                    do {
                        settings = try await KeepsClient(configuration: configuration).updateTrashSettings(settings)
                        message = "已保存"
                    } catch { message = error.localizedDescription + "\n" + String(reflecting: error) }
                }
            }.disabled(!loaded || busy || !(1...3650).contains(settings.retentionDays))
            if let message { Text(message).textSelection(.enabled) }
        }
        .disabled(!loaded || busy)
        .navigationTitle("回收站自动清理")
        .task {
            busy = true
            defer { busy = false }
            do {
                settings = try await KeepsClient(configuration: configuration).trashSettings()
                loaded = true
            } catch { message = error.localizedDescription + "\n" + String(reflecting: error) }
        }
    }
}
