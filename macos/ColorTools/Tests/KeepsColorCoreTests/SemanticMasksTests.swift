import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import KeepsColorCore

final class SemanticMasksTests: XCTestCase {
    func testPublicPersonSample() throws {
        guard let path = ProcessInfo.processInfo.environment["KEEPS_TEST_PERSON"] else { throw XCTSkip("Public person sample not configured") }
        let input = URL(fileURLWithPath: path)
        for kind in ["person", "background"] {
            let mask = try SemanticMasks.generate(kind: kind, imageURL: input)
            XCTAssertGreaterThan(mask.width, 0)
            let data = try SemanticMasks.pngData(kind: kind, imageURL: input)
            XCTAssertNotNil(CGImageSourceCreateWithData(data as CFData, nil))
        }
    }

    func testPublicSkySample() throws {
        guard ProcessInfo.processInfo.environment["KEEPS_SKY_MODEL"] != nil else { throw XCTSkip("Sky model not configured") }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let input = repository.appendingPathComponent("macos/scripts/runtime-sample/sample.jpg")
        let mask = try SemanticMasks.generate(kind: "sky", imageURL: input)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(input as CFURL, nil))
        let original = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(mask.width, original.width)
        XCTAssertEqual(mask.height, original.height)
        let data = try SemanticMasks.pngData(kind: "sky", imageURL: input)
        XCTAssertNotNil(CGImageSourceCreateWithData(data as CFData, nil))
    }

    func testBlankImageDoesNotProduceSemanticMasks() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 256, height: 192, bitsPerComponent: 8,
            bytesPerRow: 256 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 256, height: 192))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertThrowsError(try SemanticMasks.generate(kind: "person", imageURL: url)) { error in
            XCTAssertTrue(String(describing: error).contains("No person"), String(describing: error))
        }
        XCTAssertThrowsError(try SemanticMasks.generate(kind: "background", imageURL: url)) { error in
            XCTAssertTrue(String(describing: error).contains("No foreground"), String(describing: error))
        }
    }
}
