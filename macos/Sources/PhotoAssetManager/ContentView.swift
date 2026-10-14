import SwiftUI
import KeepsAPI

struct GallerySelectionActions {
    let selectAll: () -> Void
    let deselectAll: () -> Void
}

struct AIWorkspaceActions {
    let open: () -> Void
}

private struct AIWorkspaceKey: FocusedValueKey {
    typealias Value = AIWorkspaceActions
}

private struct GallerySelectionKey: FocusedValueKey {
    typealias Value = GallerySelectionActions
}

extension FocusedValues {
    var aiWorkspace: AIWorkspaceActions? {
        get { self[AIWorkspaceKey.self] }
        set { self[AIWorkspaceKey.self] = newValue }
    }

    var gallerySelection: GallerySelectionActions? {
        get { self[GallerySelectionKey.self] }
        set { self[GallerySelectionKey.self] = newValue }
    }
}

struct ContentView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var batch: AIEditingBatchStore
    @EnvironmentObject private var geometryTasks: GeometryTaskStore
    @State private var showsAIWorkspace = false
    @State private var startsAIWorkspace = false
    @State private var showsImport = false
    @State private var showsCulling = false
    @EnvironmentObject private var importTasks: ImportTaskOwner
    private var importStore: ImportStore? { importTasks.store }
    @State private var importWindowID = UUID()
    @FocusState private var galleryFocused: Bool

    @State private var showsSidebar = true
    @State private var showsInspector = false
    @State private var showsFilters = false
    @State private var thumbnailSize = 190.0
    @State private var detailMode = false
    @State private var galleryReturnAssetID: UUID?
    @State private var assetToCrop: KeepsAsset?

    var body: some View {
        Group {
            if showsAIWorkspace {
                AIEditingWorkspaceView(autoStart: startsAIWorkspace, returnToLibrary: { showsAIWorkspace = false })
                    .disabled(library.isCullingActive)
            } else {
                libraryScreen
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            AIEditingBackgroundStatus(store: batch) { showsAIWorkspace = true }
        }
        .sheet(isPresented: $showsCulling) { AICullingView() }
        .sheet(item: $assetToCrop) { asset in
            PhotoCropSheet(asset: asset)
        }
        .onChange(of: library.configuration, initial: true) { _, _ in configureGeometryTasks() }
        .onChange(of: library.isOperationBlocking) { _, _ in configureGeometryTasks() }
        .onChange(of: geometryTasks.completionRevision) { _, _ in library.refresh(force: true) }
        .focusedSceneValue(\.aiWorkspace, AIWorkspaceActions(open: openAIWorkspace))
        .sheet(isPresented: $library.showsRejectedTrash) {
            RejectedTrashSheet(library: library)
        }
    }

    private var libraryScreen: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            if let client = library.client {
                NASTasksView(client: client, library: library).id(ObjectIdentifier(client))
            }
            HStack(spacing: 0) {
                HSplitView {
                    if showsSidebar {
                        sidebar
                            .frame(minWidth: 200, idealWidth: 268, maxWidth: 480)
                            .background(SidebarLayoutAutosave())
                    }
                    workspace.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                }
                .id(showsSidebar)
                if showsInspector {
                    Divider()
                    inspector.frame(width: 292)
                }
                Divider()
                inspectorRail
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(WorkspaceStyle.canvas)
        .foregroundStyle(WorkspaceStyle.text)
        .preferredColorScheme(.dark)
        .tint(WorkspaceStyle.accent)
        .disabled(library.isOperationBlocking)
        .overlay { if library.isOperationBlocking { Color.clear.contentShape(Rectangle()).onTapGesture {} } }
        .sheet(isPresented: $showsImport, onDismiss: { library.refreshNavigation(); library.refresh(force: true) }) {
            if let importStore {
                ImportView(store: importStore, initialTarget: library.query.directory)
                    .disabled(library.isOperationBlocking)
                    .onAppear { library.openImportWindows.insert(importWindowID) }
                    .onDisappear { library.openImportWindows.remove(importWindowID) }
            }
        }
        .overlay {
            if library.isAISettingsBusy {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("AI 修图设置正在运行，请在设置中查看进度。")
                    Button("取消", action: batch.editor.cancel)
                }.padding(28).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            } else if library.isMovingDirectory {
                DirectoryMoveProgressView(library: library)
            } else if library.photoMove != nil {
                PhotoMoveProgressView(library: library)
            }
        }
        .sheet(item: $library.directoryToCreate) { directory in
            DirectoryCreateSheet(library: library, directory: directory)
                .disabled(library.isAIEditingBlocking || library.isAISettingsBusy)
        }
        .sheet(item: $library.directoryToRename) { directory in
            DirectoryRenameSheet(library: library, directory: directory)
                .disabled(library.isAIEditingBlocking || library.isAISettingsBusy)
        }
        .sheet(item: $library.directoryToTrash) { directory in
            DirectoryTrashSheet(library: library, directory: directory)
                .disabled(library.isAIEditingBlocking || library.isAISettingsBusy)
        }
        .onChange(of: library.isDirectoryOperationBlocking) { _, blocking in
            if !blocking { batch.restore(library: library) }
        }
        .task { batch.restore(library: library); library.refresh(); library.refreshNavigation(force: false) }
        .onChange(of: library.query) { _, _ in library.refresh() }
        .onChange(of: library.query.directory) { _, _ in
            detailMode = false
            galleryReturnAssetID = nil
        }
    }

    private var topBar: some View {
        HStack(spacing: 20) {
            railButton("显示或隐藏目录", icon: "sidebar.left", selected: showsSidebar) { showsSidebar.toggle() }
            Text("Keeps").font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
            Button {
                guard let client = library.client else { return }
                importTasks.configure(client) { library.refreshNavigation(); library.refresh(force: true) }
                importTasks.prepareNewIfCompleted()
                showsImport = true
            } label: { Label("导入", systemImage: "square.and.arrow.down") }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(library.client == nil)
            Button {
                guard library.query.directory != nil else { return }
                showsCulling = true
            } label: { Label("AI 筛片", systemImage: "photo.on.rectangle.angled") }
                .disabled(library.query.directory == nil || library.client == nil || library.isMutating || batch.isRunning || batch.editor.isBusy)
                .help(library.query.directory == nil ? "请先选择一个目录" : "让 AI 引导筛选当前目录，或继续上次筛片")
            Spacer(minLength: 12)
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索文件名、相机或标签", text: $library.query.q)
                    .textFieldStyle(.plain)
                if !library.query.q.isEmpty {
                    Button { library.query.q = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).help("清除搜索")
                }
            }
            .font(.system(size: 13)).padding(.horizontal, 12).frame(height: 32)
            .background(WorkspaceStyle.field, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.08)))
            .frame(maxWidth: 620)
            Button { showsFilters.toggle() } label: { Image(systemName: "line.3.horizontal.decrease").frame(width: 28, height: 28) }
                .buttonStyle(.plain).help("显示或隐藏筛选")
            Button { library.refresh(force: true); library.refreshNavigation() } label: {
                Image(systemName: "arrow.clockwise").frame(width: 28, height: 28)
            }.buttonStyle(.plain).help("刷新资料库").disabled(library.client == nil)
            SettingsLink { Image(systemName: "gearshape").frame(width: 28, height: 28) }
                .buttonStyle(.plain).help("设置")
        }
        .padding(.leading, 84).padding(.trailing, 16).frame(height: 44).background(WorkspaceStyle.panel)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("资料库").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.bottom, 8)
            scopeButton("全部照片", count: library.counts?.all, trashed: false, picked: false)
            scopeButton("精选", count: library.counts?.picked, trashed: false, picked: true)
            scopeButton("回收站", count: library.counts?.trashed, trashed: true, picked: false)
                .contextMenu {
                    Button("清空 Keeps 回收站…", role: .destructive) { library.openRejectedTrash(emptyingTrash: true) }
                        .disabled(library.isOperationBlocking || library.isMutating || !library.isStartupReady)
                }
            Divider().padding(.vertical, 20).padding(.horizontal, 16)
            if library.isLoadingNavigation && !library.isRefreshingDirectoryAfterTrash {
                ProgressView().progressViewStyle(.linear)
                    .accessibilityLabel("正在读取目录")
                    .padding(.horizontal, 16).padding(.bottom, 8)
            }
            DirectoryOutlineView(library: library).padding(.horizontal, 6)
            if let error = library.navigationError {
                WorkspaceErrorView(title: "目录暂时不可用", details: error).padding(12)
                Button("重试读取目录") { library.refreshNavigation() }.padding(.horizontal, 12)
            }

        }.padding(.top, 12).background(WorkspaceStyle.panel)
    }

    private var workspace: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(library.locationTitle).font(.system(size: 18, weight: .semibold)).lineLimit(1).help(library.locationTitle)
                Spacer(minLength: 8)
                if library.configuration != nil, library.lastError == nil, library.hasLoadedResults {
                    Text("\(library.total) 张照片").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 16).frame(height: 52)
            if showsFilters { filters; Divider() }
            galleryContent.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let error = library.lastError, !library.assets.isEmpty {
                WorkspaceErrorView(title: "请求失败", details: error)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            GeometryTaskStatusView(store: geometryTasks, configuration: library.configuration)
            bottomBar
        }
    }

    @ViewBuilder private var galleryContent: some View {
        if library.configuration == nil {
            ContentUnavailableView {
                Label("连接 Keeps Server", systemImage: "server.rack")
            } description: { Text("在应用设置中连接 Keeps Server，浏览和整理照片。") }
            actions: { SettingsLink { Text("打开设置") } }
        } else if let error = library.lastError, library.assets.isEmpty {
            ContentUnavailableView {
                Label("无法加载资料库", systemImage: "network.slash")
            } description: { WorkspaceErrorView(title: "请检查服务器连接后重试。", details: error) }
            actions: { Button("重试") { library.refresh(force: true) } }
        } else if !library.hasLoadedResults && library.isLoading {
            ProgressView("正在读取目录内容…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if library.assets.isEmpty {
            ContentUnavailableView("没有符合条件的照片", systemImage: "photo.on.rectangle", description: Text("可调整筛选条件，或在“设置 → 来源”中添加服务器目录并扫描。"))
        } else {
            gallery
        }
    }

    private var gallery: some View {
        Group {
            if detailMode, let asset = library.selectedAsset {
                RemotePreview(asset: asset, loadStandard: true).padding(24)
                    .overlay(alignment: .topLeading) {
                        if asset.flagState == "rejected" {
                            Label("已弃用", systemImage: "xmark.circle.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(WorkspaceStyle.text)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(WorkspaceStyle.panel, in: RoundedRectangle(cornerRadius: 6))
                                .padding(24)
                                .allowsHitTesting(false)
                        }
                    }
            } else {
                GeometryReader { geometry in
                    let rows = JustifiedAssetGridLayout.rows(
                        aspectRatios: library.assets.map { JustifiedAssetGridLayout.aspectRatio($0.gridPreview) },
                        availableWidth: max(1, geometry.size.width - 2),
                        targetHeight: thumbnailSize * 0.78
                    )
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 1) {
                                ForEach(rows, id: \.indices.lowerBound) { row in
                                    HStack(spacing: 1) {
                                        ForEach(row.indices, id: \.self) { index in
                                            let asset = library.assets[index]
                                            galleryTile(asset, height: row.height)
                                        }
                                    }
                                    .id(row.indices.lowerBound)
                                }
                                if library.nextCursor != nil {
                                    ProgressView()
                                        .opacity(library.isLoading && !library.isCheckingRevision ? 1 : 0)
                                        .frame(maxWidth: .infinity)
                                        .padding()
                                        .onAppear { library.setPaginationVisible(true) }
                                        .onDisappear { library.setPaginationVisible(false) }
                                }
                            }.padding(1)
                                .background(OverlayScrollerConfiguration())
                        }
                        .onAppear {
                            guard let assetID = galleryReturnAssetID,
                                  let index = library.assets.firstIndex(where: { $0.id == assetID }),
                                  let row = rows.first(where: { $0.indices.contains(index) }) else { return }
                            proxy.scrollTo(row.indices.lowerBound, anchor: .center)
                            galleryReturnAssetID = nil
                        }
                    }
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($galleryFocused)
        .focusedValue(\.gallerySelection, GallerySelectionActions(
            selectAll: { library.selectAll() }, deselectAll: { library.deselectAll() }
        ))
        .onKeyPress(keys: [.leftArrow]) { key in
            library.selectAdjacent(-1, extending: key.modifiers.contains(.shift)); return .handled
        }
        .onKeyPress(keys: [.rightArrow]) { key in
            library.selectAdjacent(1, extending: key.modifiers.contains(.shift)); return .handled
        }
        .onKeyPress(keys: ["a"]) { key in
            guard key.modifiers.contains(.command) || key.modifiers.contains(.control) else { return .ignored }
            library.selectAll(); return .handled
        }
        .onKeyPress(.escape) {
            if detailMode {
                returnToGallery()
            } else {
                library.deselectAll()
            }
            return .handled
        }
    }

    private func returnToGallery() {
        guard detailMode else { return }
        galleryReturnAssetID = library.selectedAsset?.id
        detailMode = false
        galleryFocused = true
    }

    private func galleryTile(_ asset: KeepsAsset, height: CGFloat) -> some View {
        RemotePreview(asset: asset)
            .frame(width: height * JustifiedAssetGridLayout.aspectRatio(asset.gridPreview), height: height)
            .background(WorkspaceStyle.tile)
            .overlay(alignment: .bottomLeading) {
                if asset.rating > 0 || asset.flagState != "unflagged" {
                    HStack(spacing: 5) {
                        if asset.flagState == "picked" { Image(systemName: "flag.fill") }
                        if asset.flagState == "rejected" { Image(systemName: "xmark") }
                        if asset.rating > 0 { Text(String(repeating: "★", count: max(0, min(asset.rating, 5)))) }
                    }.font(.system(size: 10)).padding(5).background(.black.opacity(0.65)).padding(6)
                }
            }
            .overlay {
                Rectangle().strokeBorder(library.selectedIDs.contains(asset.id) ? WorkspaceStyle.accent : .clear, lineWidth: 2)
            }
            .contentShape(Rectangle())
            .overlay {
                PhotoDragSource(item: { library.photoDragItem(for: asset.id) }, open: {
                    library.select(asset.id, extending: false)
                    detailMode = true
                    galleryFocused = true
                }) { modifiers in
                    galleryFocused = true
                    library.select(asset.id, extending: modifiers.contains(.command) || modifiers.contains(.control),
                                   range: modifiers.contains(.shift))
                }
            }
            .help(asset.originalFilename)
            .contextMenu {
                rotationActions(for: asset)
                Divider()
                Button("选择此照片") { library.select(asset.id, extending: false) }
                Button("全选当前目录照片") { library.selectAll() }
                Button("取消选择") { library.deselectAll() }
            }
            .accessibilityLabel(asset.originalFilename)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { library.select(asset.id) }
            .accessibilityAddTraits(library.selectedIDs.contains(asset.id) ? [.isSelected] : [])
    }

    private func configureGeometryTasks() {
        geometryTasks.configure(library.isOperationBlocking ? nil : library.configuration)
    }

    @ViewBuilder private func rotationActions(for asset: KeepsAsset) -> some View {
        Button("向左旋转 90°") { geometryTasks.rotate(assetID: asset.id, quarterTurns: -1) }
            .disabled(adjustmentUnavailable(for: asset))
        Button("向右旋转 90°") { geometryTasks.rotate(assetID: asset.id, quarterTurns: 1) }
            .disabled(adjustmentUnavailable(for: asset))
        Button("旋转 180°") { geometryTasks.rotate(assetID: asset.id, quarterTurns: 2) }
            .disabled(adjustmentUnavailable(for: asset))
    }

    private func adjustmentUnavailable(for asset: KeepsAsset) -> Bool {
        asset.trashed || library.isOperationBlocking || geometryTasks.isPending(assetID: asset.id) || geometryTasks.storageError != nil || library.configuration == nil
    }

    private var bottomBar: some View {
        HStack(spacing: 16) {
            railButton("网格视图", icon: "square.grid.2x2", selected: !detailMode) { returnToGallery() }
            railButton("单张视图", icon: "rectangle", selected: detailMode) {
                if library.selectedAsset == nil, let first = library.assets.first { library.select(first.id, extending: false) }
                detailMode = true
                galleryFocused = true
            }.disabled(library.assets.isEmpty)
            Divider().frame(height: 16)
            if detailMode, let asset = library.selectedAsset {
                Button { assetToCrop = asset } label: { Image(systemName: "crop") }
                    .buttonStyle(.plain).help("裁剪").accessibilityLabel("裁剪")
                    .disabled(adjustmentUnavailable(for: asset) || asset.standard == nil)
                Button { geometryTasks.rotate(assetID: asset.id, quarterTurns: -1) } label: { Image(systemName: "rotate.left") }
                    .buttonStyle(.plain).help("向左旋转 90°").accessibilityLabel("向左旋转 90°")
                    .disabled(adjustmentUnavailable(for: asset))
                Button { geometryTasks.rotate(assetID: asset.id, quarterTurns: 1) } label: { Image(systemName: "rotate.right") }
                    .buttonStyle(.plain).help("向右旋转 90°").accessibilityLabel("向右旋转 90°")
                    .disabled(adjustmentUnavailable(for: asset))
                Button("180°") { geometryTasks.rotate(assetID: asset.id, quarterTurns: 2) }
                    .buttonStyle(.plain).help("旋转 180°").accessibilityLabel("旋转 180°")
                    .disabled(adjustmentUnavailable(for: asset))
                Divider().frame(height: 16)
            }
            if !library.selectedIDs.isEmpty {
                HStack(spacing: 6) {
                    ForEach(1...5, id: \.self) { rating in
                        Button { library.updateSelected(KeepsAssetPatch(rating: library.selectedAsset?.rating == rating ? 0 : rating)) } label: {
                            Image(systemName: "star.fill").foregroundStyle(rating <= (library.selectedAsset?.rating ?? 0) ? WorkspaceStyle.text : Color(white: 0.4))
                        }.buttonStyle(.plain).help("\(rating) 星")
                    }
                    Divider().frame(height: 18)
                    Button { library.updateSelected(KeepsAssetPatch(flagState: library.selectedAsset?.flagState == "picked" ? "unflagged" : "picked")) } label: {
                        Image(systemName: "flag.fill").foregroundStyle(library.selectedAsset?.flagState == "picked" ? WorkspaceStyle.text : Color(white: 0.4))
                    }.buttonStyle(.plain).help("留用")
                    Button { library.updateSelected(KeepsAssetPatch(flagState: library.selectedAsset?.flagState == "rejected" ? "unflagged" : "rejected")) } label: {
                        Image(systemName: "flag.slash.fill")
                            .foregroundStyle(library.selectedAsset?.flagState == "rejected" ? WorkspaceStyle.text : Color(white: 0.4))
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(library.selectedAsset?.flagState == "rejected" ? WorkspaceStyle.field : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                    }.buttonStyle(.plain)
                        .help(library.selectedAsset?.flagState == "rejected" ? "取消弃用" : "标记为弃用")
                        .accessibilityLabel(library.selectedAsset?.flagState == "rejected" ? "取消弃用" : "标记为弃用")
                        .accessibilityAddTraits(library.selectedAsset?.flagState == "rejected" ? [.isSelected] : [])
                }.disabled(library.isMutating || library.isSelectingAll)
            }
            Group {
                if library.isLoading && !library.hasLoadedResults { Text("正在读取…") }
                else if library.configuration != nil && library.lastError == nil {
                    Text(selectionSummary).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if library.isSelectingAll { Text("正在选择全部照片…").foregroundStyle(.secondary) }
            if (library.isLoading && !library.isCheckingRevision) || library.isMutating { ProgressView().controlSize(.small) }
            if !detailMode && !showsInspector {
                Image(systemName: "square.grid.3x3").foregroundStyle(.secondary)
                Slider(value: $thumbnailSize, in: 130...300).frame(width: 100).help("缩略图大小")
                    .accessibilityLabel("缩略图大小")
            }
        }.font(.system(size: 11)).padding(.horizontal, 20).frame(height: 46).background(WorkspaceStyle.panel)
    }

    private var selectionSummary: String {
        if detailMode, let selected = library.selectedAsset,
           library.selectedIDs.count == 1,
           let index = library.assets.firstIndex(where: { $0.id == selected.id }) {
            return "第 \(index + 1) / \(max(library.total, library.assets.count)) 张"
        }
        return library.selectedIDs.isEmpty ? "\(library.assets.count) / \(library.total) 张" : "已选 \(library.selectedIDs.count) 张"
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("信息").font(.system(size: 16, weight: .semibold)).padding(20)
            Divider()
            if let asset = library.selectedAsset { AssetDetailView(asset: asset) }
            else {
                VStack(spacing: 12) {
                    Image(systemName: "info.circle").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("选择照片以查看信息").font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            Button { openAIWorkspace() } label: {
                Label(aiEditingTitle, systemImage: "wand.and.stars").frame(maxWidth: .infinity)
            }.disabled(!canStartAIEditing).padding(16)
        }.background(WorkspaceStyle.panel)
    }

    private func openAIWorkspace() {
        startsAIWorkspace = !library.selectedIDs.isEmpty
        if startsAIWorkspace { batch.prepare(library: library) }
        showsAIWorkspace = true
    }

    private var aiEditingTitle: String {
        batch.batch != nil ? "打开调色工作台" : library.selectedIDs.count > 1 ? "AI 调色（\(library.selectedIDs.count) 张）" : "AI 调色"
    }

    private var canStartAIEditing: Bool {
        (batch.batch != nil || !library.selectedIDs.isEmpty) && library.client != nil && !library.isOperationBlocking &&
        !library.isMutating && !library.isSelectingAll && !library.isCheckingConnection && !library.isUpdatingHiddenDirectory &&
        !library.isImportingPhotos && library.directoryToCreate == nil && library.directoryToRename == nil && library.directoryToTrash == nil
    }

    private var inspectorRail: some View {
        VStack {
            railButton("照片信息", icon: "info.circle", selected: showsInspector) { showsInspector.toggle() }
            railButton(aiEditingTitle, icon: "wand.and.stars", selected: false) { openAIWorkspace() }
                .disabled(!canStartAIEditing)
                .accessibilityIdentifier("ai-editing-selected-photos")
            Spacer()
        }.padding(.top, 18).frame(width: 48).background(WorkspaceStyle.panel)
    }

    private func railButton(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 17, weight: .regular))
                .foregroundStyle(selected ? WorkspaceStyle.accent : WorkspaceStyle.text)
                .frame(width: 30, height: 30)
        }.buttonStyle(.plain).help(title).accessibilityLabel(title)
    }

    private var filters: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("评分", selection: $library.query.minRating) {
                    Text("全部评分").tag(0)
                    ForEach(1...5, id: \.self) { Text("至少 \($0) 星").tag($0) }
                }
                Picker("排序", selection: $library.query.sort) {
                    Text("拍摄时间倒序").tag("capture_desc")
                    Text("拍摄时间正序").tag("capture_asc")
                    Text("文件名").tag("filename")
                    Text("评分倒序").tag("rating_desc")
                }
            }.labelsHidden()
            HStack {
                TextField("按标签筛选", text: Binding(get: { library.query.tag ?? "" }, set: { library.query.tag = $0.isEmpty ? nil : $0 })).textFieldStyle(.roundedBorder)
                if library.query.directory != nil {
                    Toggle("含子目录", isOn: $library.query.recursive).toggleStyle(.checkbox)
                }
            }
        }.padding(12)
    }

    private func scopeButton(_ title: String, count: Int?, trashed: Bool, picked: Bool) -> some View {
        Button {
            library.showLibrary(trashed: trashed, picked: picked)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: trashed ? "trash" : (picked ? "flag" : "photo.on.rectangle"))
                    .frame(width: 18).foregroundStyle(.secondary)
                Text(title)
                Spacer()
                if let count { Text(String(count)).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            .font(.system(size: 13)).padding(.horizontal, 12).frame(height: 36)
            .background(library.query.directory == nil && library.query.trashed == trashed && (library.query.flagState == "picked") == picked ? WorkspaceStyle.selection : .clear, in: RoundedRectangle(cornerRadius: 4))
        }.buttonStyle(.plain).padding(.horizontal, 8)
    }
}

struct RemotePreview: View {
    var asset: KeepsAsset
    var loadStandard = false
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        KeepsPreviewImage(asset: asset, configuration: library.configuration, loadStandard: loadStandard,
                          placeholderDelay: loadStandard ? .milliseconds(150) : .zero)
    }
}

struct AssetDetailView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var exposureTasks: ExposureTaskStore
    var asset: KeepsAsset
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                RemotePreview(asset: asset).frame(height: 164).background(WorkspaceStyle.canvas)
                Text(asset.originalFilename).font(.headline).textSelection(.enabled)
                if library.selectedIDs.count > 1 { Text("评分、标记及标签将应用于所选 \(library.selectedIDs.count) 张照片；底片设置仅作用于当前照片。").font(.caption).foregroundStyle(.secondary) }
                Text([asset.cameraMake, asset.cameraModel, asset.lensModel].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).textSelection(.enabled)
                if let captureTime = asset.captureTime { Text(captureTime).font(.caption).foregroundStyle(.secondary) }
                PhotoRatingControls(rating: asset.rating, flag: asset.flagState) { rating in
                    library.updateSelected(KeepsAssetPatch(rating: rating))
                } setFlag: { flag in
                    library.updateSelected(KeepsAssetPatch(flagState: flag))
                }
                AssetTagsView(asset: asset)
                Divider()
                if let configuration = library.configuration {
                    KeepsAssetVersionsView(assetID: asset.id, revision: asset.updatedAt, configuration: configuration,
                        onSetNegative: { version in exposureTasks.setNegative(assetID: asset.id, contentHash: version.contentHash) },
                        negativeChangePending: asset.trashed || exposureTasks.isPending(assetID: asset.id)) { _ in
                        guard library.configuration == configuration else { return }
                        library.refresh(force: true)
                    }.id(asset.id.uuidString + configuration.baseURL.absoluteString + configuration.libraryID)
                    Divider()
                }
                if asset.trashed { Button("从回收站恢复") { library.restoreSelected() } }
            }.padding(18).disabled(library.isMutating)
                .background(OverlayScrollerConfiguration())
        }
        .font(.system(size: 12))
    }
}

struct ServerSettingsView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var baseURL = ""
    @State private var libraryID = "local-library"
    @State private var credential = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Keeps Server", systemImage: "server.rack").font(.title2)
            Text("连接运行在 NAS 上的 Keeps Server。照片索引、整理和后台任务由该服务管理。")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                TextField("NAS Server 地址", text: $baseURL, prompt: Text("http://192.168.0.50:2283"))
                    .accessibilityIdentifier("server-base-url")
                TextField("资料库", text: $libraryID)
                    .accessibilityIdentifier("server-library-id")
                SecureField("服务访问令牌", text: $credential)
                    .accessibilityIdentifier("server-access-credential")
            }
            .textFieldStyle(.roundedBorder)
            .disabled(library.isCheckingConnection)
            Text("使用 Keeps 服务的 HTTP 或 HTTPS 地址。访问令牌保存在系统 Keychain 中。")
                .font(.caption).foregroundStyle(.secondary)
            if let message = library.connectionMessage {
                Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    .font(.callout).accessibilityIdentifier("server-connection-success")
            }
            if let error = library.connectionError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .accessibilityIdentifier("server-connection-error")
            }
            HStack {
                if library.isCheckingConnection { ProgressView().controlSize(.small); Text("正在验证服务连接…").font(.caption) }
                Spacer()
                Button("测试连接") { check(save: false) }
                Button("验证并保存") { check(save: true) }.keyboardShortcut(.defaultAction)
            }.disabled(library.isCheckingConnection || baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || libraryID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(24).frame(width: 540)
        .onAppear {
            baseURL = library.configuration?.baseURL.absoluteString ?? "http://192.168.0.50:2283"
            libraryID = library.configuration?.libraryID ?? "local-library"
            credential = library.configuration?.accessCredential ?? ""
            library.clearConnectionFeedback()
        }
        .onChange(of: baseURL) { _, _ in library.clearConnectionFeedback() }
        .onChange(of: libraryID) { _, _ in library.clearConnectionFeedback() }
        .onChange(of: credential) { _, _ in library.clearConnectionFeedback() }
    }

    private func check(save: Bool) {
        Task { await library.checkConnection(baseURL: baseURL, libraryID: libraryID, accessCredential: credential, save: save) }
    }
}

private struct SidebarLayoutAutosave: NSViewRepresentable {
    func makeNSView(context: Context) -> PersistenceView { PersistenceView() }
    func updateNSView(_ nsView: PersistenceView, context: Context) {}

    final class PersistenceView: NSView {
        private weak var splitView: NSSplitView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else {
                // 隐藏侧边栏后只剩一个分栏，不应覆盖用户保存的双栏布局。
                splitView?.autosaveName = nil
                splitView = nil
                return
            }
            var ancestor = superview
            while let view = ancestor {
                if let splitView = view as? NSSplitView {
                    self.splitView = splitView
                    splitView.autosaveName = "Keeps.Library.Sidebar"
                    return
                }
                ancestor = view.superview
            }
        }
    }
}
