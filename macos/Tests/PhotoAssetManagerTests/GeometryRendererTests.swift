import CoreImage
import Foundation
import ImageIO
import Testing
@testable import PhotoAssetManager

struct GeometryRendererTests {
    @Test func cropRotationUsesCurrentAppearanceAndDoesNotChangeSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.heic")
        let image = CIImage(color: CIColor(red: 0.2, green: 0.3, blue: 0.4))
            .cropped(to: CGRect(x: 0, y: 0, width: 640, height: 320))
        try CIContext().writeHEIFRepresentation(of: image, to: source, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [:])
        let original = try Data(contentsOf: source)
        let render = try await GeometryRenderer().render(sourceURL: source, outputDirectory: root.appendingPathComponent("result"),
            quarterTurns: 1, crop: CGRect(x: 0.25, y: 0, width: 0.5, height: 1))
        #expect(render.width == 160 && render.height == 640)
        #expect(try Data(contentsOf: source) == original)
        func centerPixel(_ url: URL) throws -> [UInt8] {
            let decoded = try #require(CIImage(contentsOf: url, options: [.applyOrientationProperty: true]))
            var result = [UInt8](repeating: 0, count: 4)
            result.withUnsafeMutableBytes {
                CIContext().render(decoded, toBitmap: $0.baseAddress!, rowBytes: 4,
                    bounds: CGRect(x: decoded.extent.midX, y: decoded.extent.midY, width: 1, height: 1),
                    format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            }
            return result
        }
        let before = try centerPixel(source), after = try centerPixel(render.standard)
        for channel in 0..<3 { #expect(abs(Int(before[channel]) - Int(after[channel])) <= 4) }
        for (url, width, height) in [(render.standard, 160, 640), (render.thumbnail, 128, 512), (render.browse, 16, 64)] {
            let src = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            let props = try #require(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
            #expect(props[kCGImagePropertyPixelWidth] as? Int == width)
            #expect(props[kCGImagePropertyPixelHeight] as? Int == height)
        }
    }

    @Test func allDirectionsAndLowerLeftCropAreCorrect() throws {
        let background = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 40, height: 20))
        let patch = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 10, height: 10))
        let image = patch.composited(over: background)
        for (turns, point) in [(1, CGPoint(x: 5, y: 35)), (-1, CGPoint(x: 15, y: 5)), (2, CGPoint(x: 35, y: 15))] {
            let rotated = try GeometryRenderer.geometry(image, quarterTurns: turns, crop: nil)
            var pixel = [UInt8](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes {
                CIContext().render(rotated, toBitmap: $0.baseAddress!, rowBytes: 4,
                    bounds: CGRect(origin: point, size: CGSize(width: 1, height: 1)), format: .RGBA8,
                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            }
            #expect(pixel[0] > 240 && pixel[1] < 10)
        }
        let crop = try GeometryRenderer.geometry(image, quarterTurns: 0, crop: CGRect(x: 0, y: 0, width: 0.25, height: 0.5))
        #expect(crop.extent == CGRect(x: 0, y: 0, width: 10, height: 10))
        let again = try GeometryRenderer.geometry(try GeometryRenderer.geometry(image, quarterTurns: 1, crop: nil), quarterTurns: -1, crop: nil)
        #expect(again.extent == image.extent)
    }

    @Test func invalidCropFailsAndOddSizesStayWithinThumbnailLimits() async throws {
        let image = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 641, height: 319))
        #expect(throws: AIEditingFailure.self) {
            try GeometryRenderer.geometry(image, quarterTurns: 0, crop: CGRect(x: 0.8, y: 0, width: 0.3, height: 1))
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.png")
        try CIContext().writePNGRepresentation(of: image, to: source, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [:])
        let rendered = try await GeometryRenderer().render(sourceURL: source, outputDirectory: root, quarterTurns: -1, crop: nil)
        for (url, limit) in [(rendered.thumbnail, 512), (rendered.browse, 64)] {
            let src = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            let props = try #require(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
            let width = try #require(props[kCGImagePropertyPixelWidth] as? Int)
            let height = try #require(props[kCGImagePropertyPixelHeight] as? Int)
            #expect(width <= limit && height <= limit)
            #expect(width % 2 == 0 && height % 2 == 0)
        }
    }
}
