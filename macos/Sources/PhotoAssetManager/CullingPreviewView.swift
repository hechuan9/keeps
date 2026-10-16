import AppKit
import CoreImage
import KeepsAPI
import SwiftUI

struct CullingPreviewView: View {
    let asset: KeepsAsset
    let configuration: KeepsConfiguration?
    let exposureEV: Double

    var body: some View {
        CullingImageLoader(asset: asset, configuration: configuration, exposureEV: exposureEV, fullSize: false) { image in
            Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
        }
    }
}

struct CullingZoomView: View {
    let asset: KeepsAsset
    let configuration: KeepsConfiguration?
    @Binding var exposureEV: Double
    let close: () -> Void
    @State private var zoomCommand = ZoomCommand()

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(asset.originalFilename).font(.headline).lineLimit(1)
                Spacer()
                Button("适应窗口") { zoomCommand = ZoomCommand(action: .fit) }
                Button("1:1") { zoomCommand = ZoomCommand(action: .actualSize) }
                Button { zoomCommand = ZoomCommand(action: .out) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("缩小")
                Button { zoomCommand = ZoomCommand(action: .in) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("放大")
                Button("关闭", action: close).keyboardShortcut(.cancelAction)
            }
            CullingImageLoader(asset: asset, configuration: configuration, exposureEV: exposureEV, fullSize: true) { image in
                CullingPhotoCanvas(image: image, command: zoomCommand)
            }
            HStack {
                Text("全局曝光")
                Slider(value: $exposureEV, in: -4...4).frame(width: 160)
                Text(String(format: "%+.1f EV", exposureEV)).monospacedDigit().frame(width: 75)
                Button("重置") { exposureEV = 0 }
            }

        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WorkspaceStyle.canvas)
    }
}

private struct ZoomCommand: Equatable {
    enum Action { case fit, actualSize, `in`, out }
    var action: Action = .fit
    var id = UUID()
}

private struct CullingPhotoCanvas: NSViewRepresentable {
    let image: CGImage
    let command: ZoomCommand
    class Coordinator { var commandID: UUID? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> PhotoCanvasView { PhotoCanvasView(image: image) }
    func updateNSView(_ view: PhotoCanvasView, context: Context) {
        view.update(image: image, preserveViewport: true)
        guard context.coordinator.commandID != command.id else { return }
        context.coordinator.commandID = command.id
        let scale: CGFloat
        switch command.action {
        case .fit: scale = view.fitZoom
        case .actualSize: scale = view.pixelZoom
        case .in: scale = view.zoom * 1.5
        case .out: scale = view.zoom / 1.5
        }
        view.setZoom(scale, around: CGPoint(x: view.bounds.midX, y: view.bounds.midY))
    }
}

private struct CullingImageLoader<Content: View>: View {
    let asset: KeepsAsset
    let configuration: KeepsConfiguration?
    let exposureEV: Double
    let fullSize: Bool
    @ViewBuilder let content: (CGImage) -> Content
    @State private var source: CGImage?
    @State private var displayed: CGImage?
    @State private var error: String?
    @State private var revision = 0
    @State private var retry = 0

    private var identity: String {
        "\(asset.id)|\(asset.gridPreview?.version ?? "")|\(asset.standard?.version ?? "")|\(configuration?.baseURL.absoluteString ?? "")|\(configuration?.libraryID ?? "")|\(configuration?.accessCredential ?? "")|\(retry)"
    }

    var body: some View {
        ZStack {
            Color(white: 0.15)
            if let displayed { content(displayed) }
            else { KeepsPreviewImage(asset: asset, configuration: configuration) }
        }
        .overlay(alignment: .topTrailing) {
            if displayed == nil {
                Text("非全尺寸").font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.regularMaterial, in: Capsule()).padding(6)
            }
        }
        .overlay(alignment: .bottom) {
            if let error {
                VStack {
                    Text(error).font(.caption2).lineLimit(3).textSelection(.enabled)
                    Button("重新载入照片") { retry += 1 }
                }.padding(8).background(.regularMaterial)
            }
        }
        .task(id: identity) { await load() }
        .task(id: "\(identity)|\(revision)|\(exposureEV)") { await render() }
    }

    @MainActor
    private func load() async {
        source = nil
        displayed = nil
        error = nil
        guard let configuration else { return }
        do {
            let loaded = try await CullingFullSizeCache.shared.image(
                asset: asset, configuration: configuration, maxPixelSize: fullSize ? nil : 1024)
            try Task.checkCancellation()
            source = loaded
            revision += 1
        } catch {
            guard !Task.isCancelled else { return }
            self.error = "全尺寸照片载入失败：" + AIEditingFailure.userMessage(error)
        }
    }

    @MainActor
    private func render() async {
        guard let source else { return }
        if exposureEV == 0 { displayed = source; return }
        do {
            try await Task.sleep(for: .milliseconds(80))
            let rendered = try await CullingPreviewRenderer.shared.render(source, exposureEV: exposureEV)
            try Task.checkCancellation()
            displayed = rendered
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            self.error = String(reflecting: error)
        }
    }
}

private actor CullingPreviewRenderer {
    static let shared = CullingPreviewRenderer()
    private let context = CIContext()

    func render(_ image: CGImage, exposureEV: Double) throws -> CGImage {
        try Task.checkCancellation()
        let input = CIImage(cgImage: image)
        let output = input.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: exposureEV])
        guard let result = context.createCGImage(output, from: input.extent) else {
            throw NSError(domain: "CullingPreviewRenderer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法生成曝光预览。"])
        }
        return result
    }
}
