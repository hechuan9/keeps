import SwiftUI
import KeepsAPI

struct PhotoCropSheet: View {
    let asset: KeepsAsset
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var geometryTasks: GeometryTaskStore
    @Environment(\.dismiss) private var dismiss
    @State private var image: CGImage?
    @State private var selection = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var loadError: String?
    @State private var retry = 0
    @State private var expectedRevision: Int64?

    private var unavailable: Bool {
        asset.trashed || library.isOperationBlocking || library.configuration == nil || geometryTasks.storageError != nil || geometryTasks.isPending(assetID: asset.id)
    }

    private var croppedImage: CGImage? {
        guard let image else { return nil }
        return image.cropping(to: CGRect(x: selection.minX * CGFloat(image.width), y: selection.minY * CGFloat(image.height),
                                        width: selection.width * CGFloat(image.width), height: selection.height * CGFloat(image.height)).integral)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("裁剪照片").font(.title2)
            Text("在照片上拖动选择裁剪范围。调整保存为独立展示图，原片保持不变。")
                .font(.callout).foregroundStyle(.secondary)
            if let image {
                HStack(spacing: 20) {
                    cropCanvas(image).frame(width: 560, height: 420)
                    VStack(spacing: 12) {
                        Text("裁剪预览").font(.caption).foregroundStyle(.secondary)
                        if let croppedImage {
                            Image(decorative: croppedImage, scale: 1).resizable().scaledToFit().frame(width: 180, height: 240)
                        }
                    }.frame(width: 180)
                }
            } else if let loadError {
                WorkspaceErrorView(title: "无法载入裁剪照片", details: loadError)
                    .frame(width: 760, height: 420)
                Button("重新载入") { retry += 1 }
            } else {
                ProgressView("正在载入照片…").frame(width: 760, height: 420)
            }
            if let error = geometryTasks.storageError {
                WorkspaceErrorView(title: "无法保存调整任务", details: error)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("应用裁剪") {
                    guard let expectedRevision else { return }
                    geometryTasks.crop(assetID: asset.id, crop: CGRect(
                        x: selection.minX, y: 1 - selection.maxY,
                        width: selection.width, height: selection.height
                    ), expectedRevision: expectedRevision)
                    dismiss()
                }.keyboardShortcut(.defaultAction)
                    .disabled(unavailable || image == nil || expectedRevision == nil || selection.width <= 0 || selection.height <= 0)
            }
        }.padding(24)
            .task(id: "\(asset.id)|\(asset.standard?.version ?? "")|\(library.configuration?.baseURL.absoluteString ?? "")|\(library.configuration?.libraryID ?? "")|\(retry)") {
                await loadImage()
            }
    }

    private func cropCanvas(_ image: CGImage) -> some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / CGFloat(image.width), geometry.size.height / CGFloat(image.height))
            let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            ZStack {
                Color.black
                ZStack(alignment: .topLeading) {
                    Image(decorative: image, scale: 1).resizable().frame(width: size.width, height: size.height)
                    Path { path in
                        path.addRect(CGRect(origin: .zero, size: size))
                        path.addRect(CGRect(x: selection.minX * size.width, y: selection.minY * size.height,
                                            width: selection.width * size.width, height: selection.height * size.height))
                    }.fill(.black.opacity(0.55), style: FillStyle(eoFill: true))
                    Rectangle().stroke(.white, lineWidth: 1)
                        .frame(width: selection.width * size.width, height: selection.height * size.height)
                        .offset(x: selection.minX * size.width, y: selection.minY * size.height)
                }
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 2).onChanged { gesture in
                    let start = bounded(gesture.startLocation, size: size)
                    let end = bounded(gesture.location, size: size)
                    let width = abs(end.x - start.x)
                    let height = abs(end.y - start.y)
                    guard width >= 1 / CGFloat(image.width), height >= 1 / CGFloat(image.height) else { return }
                    selection = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: width, height: height)
                })
                .disabled(unavailable)
                .accessibilityLabel("在照片上拖动选择裁剪范围")
            }
        }
    }

    private func bounded(_ point: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: min(1, max(0, point.x / size.width)), y: min(1, max(0, point.y / size.height)))
    }

    @MainActor private func loadImage() async {
        image = nil
        expectedRevision = nil
        loadError = nil
        guard let configuration = library.configuration else {
            loadError = "当前照片没有可用的展示图。"
            return
        }
        do {
            let client = KeepsClient(configuration: configuration)
            let before = try await client.editState(assetID: asset.id)
            let current = try await client.asset(id: asset.id)
            guard !current.trashed, let standard = current.standard else {
                throw CropPreviewError.unavailable
            }
            let loaded = try await PreviewCache.standards.image(assetID: asset.id, preview: standard,
                                                               configuration: configuration, maxPixelSize: 1600)
            let after = try await client.editState(assetID: asset.id)
            try Task.checkCancellation()
            guard before.revision == after.revision else { throw CropPreviewError.changed }
            expectedRevision = after.revision
            selection = CGRect(x: 0, y: 0, width: 1, height: 1)
            image = loaded
        } catch {
            guard !Task.isCancelled else { return }
            loadError = error.localizedDescription + "\n" + String(reflecting: error)
        }
    }
}

private enum CropPreviewError: LocalizedError {
    case unavailable
    case changed

    var errorDescription: String? {
        switch self {
        case .unavailable: "当前照片没有可用的展示图，或已进入回收站。"
        case .changed: "照片调整与展示图尚未一致，请刷新照片后再裁剪。"
        }
    }
}
