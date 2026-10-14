import AppKit
import KeepsAPI
import SwiftUI

struct ZoomablePhotoView: View {
    let asset: KeepsAsset
    let configuration: KeepsConfiguration?
    @State private var image: CGImage?
    @State private var error: String?
    @State private var retry = 0

    var body: some View {
        ZStack {
            KeepsPreviewImage(asset: asset, configuration: configuration)
            if let image { PhotoCanvas(image: image) }
        }
        .overlay(alignment: .bottom) {
            if let error {
                VStack {
                    Button("重新载入清晰图像") { retry += 1 }
                    Text(error).font(.caption2).lineLimit(3).textSelection(.enabled)
                }.padding(8).background(.regularMaterial)
            }
        }
        .help("双击切换适应窗口与 1:1；滚轮缩放；按住鼠标左键拖动")
        .task(id: retry) {
            guard let configuration, let standard = asset.standard else { return }
            error = nil
            do {
                let loaded = try await PreviewCache.standards.image(
                    assetID: asset.id, preview: standard, configuration: configuration,
                    maxPixelSize: max(standard.width, standard.height))
                try Task.checkCancellation()
                image = loaded
            } catch {
                guard !Task.isCancelled else { return }
                self.error = String(reflecting: error)
            }
        }
    }
}

private struct PhotoCanvas: NSViewRepresentable {
    let image: CGImage
    func makeNSView(context: Context) -> PhotoCanvasView { PhotoCanvasView(image: image) }
    func updateNSView(_ view: PhotoCanvasView, context: Context) { view.update(image: image) }
}

final class PhotoCanvasView: NSView {
    private var image: CGImage
    private(set) var zoom: CGFloat = 1
    private(set) var offset = CGPoint.zero
    private var fitsWindow = true
    override var isFlipped: Bool { true }

    init(image: CGImage) {
        self.image = image
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var fitZoom: CGFloat {
        min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
    }
    var pixelZoom: CGFloat { 1 / (window?.backingScaleFactor ?? 1) }
    private var imageRect: CGRect {
        let size = CGSize(width: CGFloat(image.width) * zoom, height: CGFloat(image.height) * zoom)
        return CGRect(x: (bounds.width - size.width) / 2 + offset.x,
                      y: (bounds.height - size.height) / 2 + offset.y,
                      width: size.width, height: size.height)
    }

    func update(image: CGImage) {
        guard self.image !== image else { return }
        self.image = image
        fitsWindow = true
        resizeImage()
    }
    override func layout() { super.layout(); resizeImage() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); resizeImage() }

    private func resizeImage() {
        if fitsWindow { zoom = fitZoom; offset = .zero }
        constrainOffset()
        needsDisplay = true
    }
    private func constrainOffset() {
        let x = max(0, (CGFloat(image.width) * zoom - bounds.width) / 2)
        let y = max(0, (CGFloat(image.height) * zoom - bounds.height) / 2)
        offset.x = min(x, max(-x, offset.x))
        offset.y = min(y, max(-y, offset.y))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.15, alpha: 1).setFill()
        bounds.fill()
        NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
            .draw(in: imageRect, from: .zero, operation: .copy, fraction: 1,
                  respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }

    func setZoom(_ requested: CGFloat, around point: CGPoint) {
        guard zoom > 0, fitZoom > 0 else { return }
        let next = min(max(fitZoom, pixelZoom * 8), max(min(fitZoom, pixelZoom), requested))
        let ratio = next / zoom
        let relative = CGPoint(x: point.x - bounds.midX, y: point.y - bounds.midY)
        offset = CGPoint(x: relative.x - (relative.x - offset.x) * ratio,
                         y: relative.y - (relative.y - offset.y) * ratio)
        zoom = next
        fitsWindow = abs(zoom - fitZoom) < 0.000001
        constrainOffset()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2 else { return }
        if fitsWindow {
            setZoom(pixelZoom, around: convert(event.locationInWindow, from: nil))
        } else {
            fitsWindow = true
            resizeImage()
        }
    }
    override func mouseDragged(with event: NSEvent) {
        offset.x += event.deltaX
        offset.y += event.deltaY
        constrainOffset()
        needsDisplay = true
    }
    override func scrollWheel(with event: NSEvent) {
        let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.01 : 0.12
        setZoom(zoom * exp(-event.scrollingDeltaY * sensitivity),
                around: convert(event.locationInWindow, from: nil))
    }
    override func magnify(with event: NSEvent) {
        setZoom(zoom * (1 + event.magnification), around: convert(event.locationInWindow, from: nil))
    }
}
