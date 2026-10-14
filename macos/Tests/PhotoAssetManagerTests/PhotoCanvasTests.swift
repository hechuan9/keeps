import AppKit
import Testing
@testable import PhotoAssetManager

@MainActor
struct PhotoCanvasTests {
    private func canvas() throws -> PhotoCanvasView {
        let context = try #require(CGContext(data: nil, width: 2000, height: 1000,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let view = PhotoCanvasView(image: try #require(context.makeImage()))
        view.frame = CGRect(x: 0, y: 0, width: 1000, height: 600)
        view.layout()
        return view
    }

    @Test func zoomPreservesPointUnderPointer() throws {
        let view = try canvas()
        #expect(view.zoom == 0.5)
        view.setZoom(1, around: CGPoint(x: 750, y: 300))
        #expect(view.zoom == 1)
        #expect(view.offset.x == -250)
        #expect(view.offset.y == 0)
    }

    @Test func zoomLimitsAndFitRecentering() throws {
        let view = try canvas()
        view.setZoom(100, around: CGPoint(x: 1000, y: 600))
        #expect(view.zoom == view.pixelZoom * 8)
        view.setZoom(0.001, around: .zero)
        #expect(view.zoom == view.fitZoom)
        #expect(view.offset == .zero)
    }
}
