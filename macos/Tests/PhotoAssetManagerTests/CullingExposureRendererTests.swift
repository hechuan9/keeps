import CoreImage
import Foundation
import Testing
@testable import PhotoAssetManager

struct CullingExposureRendererTests {
    @Test func automaticRevealsDarkTonesInOrderAndLeavesSourceUntouched() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("dark.png")
        let levels: [CGFloat] = [0, 0.015, 0.03, 0.06]
        var image = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 80, height: 20))
        for (index, level) in levels.enumerated() {
            let patch = CIImage(color: CIColor(red: level, green: level, blue: level))
                .cropped(to: CGRect(x: index * 20, y: 0, width: 20, height: 20))
            image = patch.composited(over: image)
        }
        try write(image, to: source)
        let original = try Data(contentsOf: source)
        let renderer = CullingExposureRenderer()
        let before = try await renderer.render(sourceURL: source, automatic: false, exposureEV: 0)
        let after = try await renderer.render(sourceURL: source, automatic: true, exposureEV: 0)
        let values = (0..<4).map { pixel(after, x: $0 * 20 + 10) }
        #expect(values[0] < 0.001)
        #expect(values[1] > pixel(before, x: 30) * 2)
        #expect(values[0] < values[1] && values[1] < values[2] && values[2] < values[3])
        #expect(try Data(contentsOf: source) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["dark.png"])
    }

    @Test func manualExposureWorksAfterAutomaticAndPreviewIsBounded() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("large.png")
        try write(CIImage(color: CIColor(red: 0.05, green: 0.05, blue: 0.05))
            .cropped(to: CGRect(x: 0, y: 0, width: 3201, height: 1200)), to: source)
        let renderer = CullingExposureRenderer()
        let dark = try await renderer.render(sourceURL: source, automatic: true, exposureEV: -2)
        let light = try await renderer.render(sourceURL: source, automatic: true, exposureEV: -1)
        #expect(dark.width <= 1600 && dark.height <= 1600)
        #expect(pixel(light, x: 10) > pixel(dark, x: 10) * 1.8)
    }

    @Test func blackStaysBlackAndChangingSourceInvalidatesCache() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let renderer = CullingExposureRenderer()
        for (name, level) in [("black", CGFloat(0)), ("gray", CGFloat(0.1))] {
            let source = root.appendingPathComponent("\(name).png")
            try write(CIImage(color: CIColor(red: level, green: level, blue: level))
                .cropped(to: CGRect(x: 0, y: 0, width: 20, height: 20)), to: source)
            let result = try await renderer.render(sourceURL: source, automatic: true, exposureEV: 0)
            if level == 0 { #expect(pixel(result, x: 10) < 0.001) }
            else { #expect(pixel(result, x: 10) > 0.1) }
        }
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ image: CIImage, to url: URL) throws {
        try CIContext().writePNGRepresentation(of: image, to: url, format: .RGBA16,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [:])
    }

    private func pixel(_ image: CGImage, x: Int) -> Float {
        var channels = [Float](repeating: 0, count: 4)
        channels.withUnsafeMutableBytes {
            CIContext().render(CIImage(cgImage: image), toBitmap: $0.baseAddress!, rowBytes: 16,
                bounds: CGRect(x: x, y: 10, width: 1, height: 1), format: .RGBAf,
                colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        }
        return channels[0]
    }
}
