import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import KeepsColorCore

final class PreviewAnalysisTests: XCTestCase {
    func testRegionCoordinatesAndBounds() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.png")
        var bytes = Data()
        for row in 0..<100 {
            let channel: UInt8 = row < 50 ? 255 : 0
            for _ in 0..<100 { bytes.append(contentsOf: [channel, channel, channel, 255]) }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
        let image = try XCTUnwrap(CGImage(width: 100, height: 100, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 400, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let (jpeg, top) = try PreviewAnalysis.crop(url, x: 0, y: 0, width: 1, height: 0.4)
        let (_, bottom) = try PreviewAnalysis.crop(url, x: 0, y: 0.6, width: 1, height: 0.4)
        XCTAssertGreaterThan(try XCTUnwrap(top["sRGBLumaMedian"]), 0.95)
        XCTAssertLessThan(try XCTUnwrap(bottom["sRGBLumaMedian"]), 0.05)
        XCTAssertNotNil(CGImageSourceCreateWithData(jpeg as CFData, nil))
        XCTAssertThrowsError(try PreviewAnalysis.crop(url, x: 0.9, y: 0, width: 0.2, height: 1))
        XCTAssertThrowsError(try PreviewAnalysis.crop(url, x: .nan, y: 0, width: 1, height: 1))
    }
}
