import CoreImage
import Foundation
import KeepsAPI
import Testing
@testable import PhotoAssetManager

struct CullingFullSizeCacheTests {
    @Test func credentialsAndLibrariesHaveSeparateCacheNamespaces() {
        let a = KeepsConfiguration(baseURL: URL(string: "https://example.test")!, libraryID: "one", accessCredential: "first")
        var b = a
        b.accessCredential = "second"
        #expect(CullingFullSizeCache.namespace(a) != CullingFullSizeCache.namespace(b))
        b = a
        b.libraryID = "two"
        #expect(CullingFullSizeCache.namespace(a) != CullingFullSizeCache.namespace(b))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["KEEPS_TEST_RAW"] != nil))
    func realRAWDecodesAtNativeSize() async throws {
        let url = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["KEEPS_TEST_RAW"]))
        let raw = try #require(CIRAWFilter(imageURL: url))
        let expected = raw.nativeSize
        let cache = CullingFullSizeCache()
        let image = try await cache.decode(url: url, maxPixelSize: nil)
        #expect(max(image.width, image.height) == Int(max(expected.width, expected.height)))
        #expect(min(image.width, image.height) == Int(min(expected.width, expected.height)))
    }

    @Test func fullSizeDecodePreservesDimensionsAndCardDecodeIsBounded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.png")
        let input = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 3000, height: 2000))
        try CIContext().writePNGRepresentation(of: input, to: source, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let bytes = try Data(contentsOf: source)
        let cache = CullingFullSizeCache(directory: root.appendingPathComponent("cache"))
        let full = try await cache.decode(url: source, maxPixelSize: nil)
        let card = try await cache.decode(url: source, maxPixelSize: 1024)
        #expect(full.width == 3000 && full.height == 2000)
        #expect(card.width <= 1024 && card.height <= 1024)
        #expect(try Data(contentsOf: source) == bytes)
    }
}
