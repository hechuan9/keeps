import SwiftUI
import Photos
import UIKit
import KeepsAPI
import OSLog

struct IOSWaterfallGallery: View {
    @EnvironmentObject private var library: IOSLibraryStore
    @Binding var selecting: Bool
    @Binding var selectedIDs: Set<UUID>
    @Binding var density: KeepsGalleryDensity
    @Binding var visibleDates: String
    var style: KeepsGalleryStyle
    var preparationFinished: (String?) -> Void
    @State private var selected: KeepsAsset?
    @State private var information: KeepsAsset?

    var body: some View {
        IOSPhotoCollectionView(library: library, selecting: $selecting, selectedIDs: $selectedIDs,
                               density: $density, visibleDates: $visibleDates,
                               style: style, preparationFinished: preparationFinished,
                               open: { selected = $0 }, information: { information = $0 })
        .fullScreenCover(item: $selected) { asset in IOSPhotoViewer(initialAsset: asset).environmentObject(library) }
        .sheet(item: $information) { asset in
            NavigationStack {
                IOSAssetDetail(asset: asset)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { information = nil } } }
            }.environmentObject(library)
        }
    }
}

struct IOSPreviewImage: View {
    let asset: KeepsAsset
    let configuration: KeepsConfiguration?
    var contentMode: ContentMode = .fit
    var loadStandard = false
    var previewScale: CGFloat = 1
    var body: some View {
        KeepsPreviewImage(asset: asset, configuration: configuration, contentMode: contentMode,
                          loadStandard: loadStandard, previewScale: previewScale)
    }
}

struct IOSPhotoViewer: View {
    @EnvironmentObject private var library: IOSLibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID
    @State private var photos: [KeepsAsset] = []
    @State private var controlsVisible = true
    @State private var restoringSelection = false
    @State private var information: KeepsAsset?
    @State private var savingToPhotos = false
    @State private var saveMessage: String?
    let initialAsset: KeepsAsset

    init(initialAsset: KeepsAsset) {
        self.initialAsset = initialAsset
        _selection = State(initialValue: initialAsset.id)
    }

    private var current: KeepsAsset { photos.first { $0.id == selection } ?? initialAsset }

    private var previewBuffer: [KeepsAsset] {
        guard let index = photos.firstIndex(where: { $0.id == selection }) else { return [initialAsset] }
        return [0, 1, -1, 2, -2].compactMap { offset in
            let candidate = index + offset
            return photos.indices.contains(candidate) ? photos[candidate] : nil
        }
    }

    private var previewBufferIdentity: String {
        let connection = library.configuration
        return ([connection?.baseURL.absoluteString ?? "", connection?.libraryID ?? "",
                 connection?.accessCredential ?? ""] + previewBuffer.map {
            "\($0.id)|\($0.standard?.version ?? "")"
        }).joined(separator: "|")
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $selection) {
                ForEach(photos) { asset in
                    IOSZoomablePhoto(asset: asset, configuration: library.configuration,
                                     toggleControls: { withAnimation { controlsVisible.toggle() } },
                                     close: { dismiss() })
                        .tag(asset.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .overlay(alignment: .top) {
                if controlsVisible {
                    HStack {
                        Button { dismiss() } label: { Image(systemName: "chevron.down").padding(12) }
                            .accessibilityLabel("返回图库")
                        Spacer()
                        VStack(spacing: 4) {
                            Text(String((current.captureTime ?? current.createdAt).prefix(10))).font(.headline)
                            Text(current.originalFilename).font(.caption).lineLimit(1)
                        }
                        Spacer()
                        Button { information = current } label: { Image(systemName: "info.circle").padding(12) }
                            .accessibilityLabel("照片信息与整理")
                        Button { Task { await saveCurrentToPhotos() } } label: {
                            if savingToPhotos { ProgressView().padding(12) }
                            else { Image(systemName: "square.and.arrow.down").padding(12) }
                        }
                        .disabled(savingToPhotos)
                        .accessibilityLabel("保存到本机相册")
                    }.padding(.horizontal, 8).padding(.vertical, 6).background(.ultraThinMaterial)
                }
            }
            .overlay(alignment: .bottom) {
                if controlsVisible {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 3) {
                                ForEach(photos) { asset in
                                    Button { selection = asset.id } label: {
                                        IOSPreviewImage(asset: asset, configuration: library.configuration)
                                            .frame(width: 48 * JustifiedAssetGridLayout.aspectRatio(asset.gridPreview), height: 48)
                                            .overlay { if selection == asset.id { Rectangle().stroke(.white, lineWidth: 2) } }
                                    }.buttonStyle(.plain).id(asset.id)
                                        .accessibilityLabel(asset.originalFilename)
                                        .accessibilityAddTraits(selection == asset.id ? .isSelected : [])
                                }
                            }.padding(8)
                        }.frame(height: 64).scrollIndicators(.hidden).background(.ultraThinMaterial)
                            .onAppear { proxy.scrollTo(selection, anchor: .center) }
                            .onChange(of: selection) { _, id in withAnimation { proxy.scrollTo(id, anchor: .center) } }
                    }.frame(height: 64)
                }
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(!controlsVisible)
        .onAppear { photos = library.assets.isEmpty ? [initialAsset] : library.chronologicalAssets }
        .onChange(of: library.assets) { _, updated in
            if updated.contains(where: { $0.id == selection }) {
                photos = updated.reversed()
            } else if !restoringSelection {
                let retained = current
                restoringSelection = true
                Task {
                    let found = await library.restoreWindow(around: retained)
                    restoringSelection = false
                    if !found && selection == retained.id { dismiss() }
                }
            }
        }
        .task(id: selection) {
            if photos.prefix(3).contains(where: { $0.id == selection }), library.canLoadMore {
                await library.loadMore()
            } else if photos.suffix(3).contains(where: { $0.id == selection }), library.canLoadNewer {
                await library.loadNewer()
            }
        }
        .task(id: previewBufferIdentity) {
            guard let configuration = library.configuration else { return }
            // Warm encoded files in order; full-size decoding belongs to the visible page.
            for asset in previewBuffer {
                guard !Task.isCancelled else { return }
                guard let standard = asset.standard else { continue }
                do {
                    let cached = try await PreviewCache.standards.prefetch(
                        assetID: asset.id, preview: standard, configuration: configuration, skipWhenBusy: false
                    )
                    if !cached { return }
                } catch {
                    guard !Task.isCancelled, !(error is CancellationError) else { return }
                    Logger(subsystem: "com.hechuan.Keeps", category: "photo-viewer")
                        .error("Standard preview prefetch failed: \(String(reflecting: error), privacy: .public)")
                }
            }
        }
        .sheet(item: $information) { asset in
            NavigationStack {
                IOSAssetDetail(asset: asset, onRemoved: { id in
                    information = nil
                    let index = photos.firstIndex { $0.id == id } ?? 0
                    photos.removeAll { $0.id == id }
                    if photos.isEmpty { dismiss() }
                    else { selection = photos[min(index, photos.count - 1)].id }
                })
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { information = nil } } }
            }.environmentObject(library)
        }
        .alert("保存到本机相册", isPresented: Binding(
            get: { saveMessage != nil },
            set: { if !$0 { saveMessage = nil } }
        )) {
            Button("好", role: .cancel) { saveMessage = nil }
        } message: {
            Text(saveMessage ?? "")
        }
    }

    @MainActor
    private func saveCurrentToPhotos() async {
        guard !savingToPhotos else { return }
        guard let configuration = library.configuration else {
            saveMessage = "请先连接 NAS 图库。"
            return
        }
        savingToPhotos = true
        defer { savingToPhotos = false }
        do {
            let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            let permitted: Bool
            if status == .notDetermined {
                permitted = await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized
            } else {
                permitted = status == .authorized || status == .limited
            }
            guard permitted else {
                saveMessage = "没有获得添加照片的权限。请在系统设置中允许 Keeps 添加到照片。"
                return
            }

            let client = KeepsClient(configuration: configuration)
            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent("keeps-photo-\(UUID().uuidString).jpg")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try await client.downloadCurrentStandard(assetID: current.id, to: temporary)
            try Task.checkCancellation()
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: temporary)
            }
            saveMessage = "已保存到本机相册。"
        } catch {
            saveMessage = "保存失败：\(error.localizedDescription)\n\(String(reflecting: error))"
        }
    }
}

struct IOSAssetDetail: View {
    @EnvironmentObject private var library: IOSLibraryStore
    @Environment(\.dismiss) private var dismiss
    @State var asset: KeepsAsset
    var onRemoved: (UUID) -> Void = { _ in }
    @State private var rating = 0
    @State private var flag = "unflagged"
    @State private var tags = ""
    @State private var busy = false
    @State private var error: String?
    @State private var saved = false

    var body: some View {
        Form {
            Section {
                IOSPreviewImage(asset: asset, configuration: library.configuration)
                    .frame(minHeight: 240, maxHeight: 420)
                LabeledContent("文件名", value: asset.originalFilename)
                if let time = asset.captureTime { LabeledContent("拍摄时间", value: time) }
                if !asset.cameraModel.isEmpty { LabeledContent("相机", value: asset.cameraModel) }
                if !asset.lensModel.isEmpty { LabeledContent("镜头", value: asset.lensModel) }
            }
            if let configuration = library.configuration {
                Section {
                    KeepsAssetVersionsView(assetID: asset.id, revision: asset.updatedAt, configuration: configuration) { updated in
                        guard library.configuration == configuration else { return }
                        asset = updated
                        Task { await library.update(updated) }
                    }.id(asset.id.uuidString + configuration.baseURL.absoluteString + configuration.libraryID)
                }
            }
            Section("整理") {
                HStack {
                    Text("评分")
                    Spacer()
                    ForEach(1...5, id: \.self) { value in
                        Button { rating = rating == value ? 0 : value; saved = false } label: {
                            Image(systemName: value <= rating ? "star.fill" : "star")
                        }.buttonStyle(.plain).accessibilityLabel("\(value) 星")
                    }
                }
                HStack {
                    Text("标记")
                    Spacer()
                    Button { flag = flag == "picked" ? "unflagged" : "picked"; saved = false } label: {
                        Image(systemName: "flag.fill").foregroundStyle(flag == "picked" ? Color.primary : .secondary)
                    }.accessibilityLabel("留用")
                    Button { flag = flag == "rejected" ? "unflagged" : "rejected"; saved = false } label: {
                        Image(systemName: "flag.slash.fill").foregroundStyle(flag == "rejected" ? Color.primary : .secondary)
                    }.accessibilityLabel("弃用")
                }.buttonStyle(.plain)
                TextField("标签，以逗号分隔", text: $tags)
                Button("保存到 NAS") { Task { await save() } }.disabled(busy)
                if saved { Text("已保存").foregroundStyle(.secondary) }
            }
            Section {
                Button(asset.trashed ? "恢复到图库" : "移入回收站", role: asset.trashed ? nil : .destructive) {
                    Task { await toggleTrash() }
                }.disabled(busy)
            } footer: { Text("此操作只改变 NAS 图库状态，不会删除或移动原片。") }
            if busy { ProgressView() }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }
        .onChange(of: library.assets) { _, assets in
            if let updated = assets.first(where: { $0.id == asset.id }) { asset = updated }
        }
        .navigationTitle("照片详情")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            applyFields()
            guard let configuration = library.configuration else { return }
            do { asset = try await KeepsClient(configuration: configuration).asset(id: asset.id); applyFields() }
            catch { self.error = String(reflecting: error) }
        }
    }
    private func applyFields() {
        rating = asset.rating; flag = asset.flagState; tags = asset.tags.joined(separator: ", ")
    }
    private func save() async {
        guard let configuration = library.configuration else { return }
        busy = true; error = nil; saved = false
        defer { busy = false }
        let tagList = tags.replacingOccurrences(of: "，", with: ",").split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        do {
            asset = try await KeepsClient(configuration: configuration).updateAsset(id: asset.id, patch: KeepsAssetPatch(rating: rating, flagState: flag, tags: tagList))
            await library.update(asset); applyFields(); saved = true
        } catch { self.error = String(reflecting: error) }
    }
    private func toggleTrash() async {
        guard let configuration = library.configuration else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let client = KeepsClient(configuration: configuration)
            asset = try await (asset.trashed ? client.restoreAsset(id: asset.id) : client.trashAsset(id: asset.id))
            await library.update(asset); onRemoved(asset.id); dismiss()
        } catch { self.error = String(reflecting: error) }
    }
}
