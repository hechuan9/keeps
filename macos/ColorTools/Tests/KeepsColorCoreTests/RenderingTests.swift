import Foundation
import ImageIO
import CoreGraphics
import XCTest
@testable import KeepsColorCore

final class RenderingTests: XCTestCase {
    func testRealRAWRecipeReplayAndMasks() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let executable = environment["KEEPS_TEST_DARKTABLE"], let source = environment["KEEPS_TEST_RAW"] else {
            throw XCTSkip("Set KEEPS_TEST_DARKTABLE and KEEPS_TEST_RAW for real renderer validation")
        }
        let sourceURL = URL(fileURLWithPath: source)
        let before = try contentHash(sourceURL)
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/real-render-\(UUID().uuidString)")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var engine: DarktableProcess? = try DarktableProcess(executable: URL(fileURLWithPath: executable), source: sourceURL, directory: directory)
        func render(_ engine: DarktableProcess, _ recipe: ColorRecipe, _ operation: String, full: Bool = false) throws -> URL {
            let candidate = try engine.store.add(operationID: operation, parentID: nil, recipe: encoder.encode(recipe))
            return try engine.render(xmp: DarktableRecipe.apply(recipe, to: engine.baseline), candidateID: candidate.id, full: full)
        }
        var recipe = ColorRecipe(exposureEV: 1.5, whiteBalanceRGB: [1.01, 1, 0.98], contrast: 1.3, skew: -0.2, saturation: 1.05)
        let plain = try pixels(render(engine!, recipe, "plain"))
        recipe.localAdjustments = [LocalExposure(id: "subject", exposureEV: 1, mask: .ellipse(centerX: 0.42, centerY: 0.4, radiusX: 0.15, radiusY: 0.2, rotation: 0, feather: 0.06))]
        let ellipse = try pixels(render(engine!, recipe, "ellipse"))
        let inside = difference(plain, ellipse, x: 0.36...0.48, y: 0.3...0.5)
        let outside = difference(plain, ellipse, x: 0.75...0.9, y: 0.7...0.9)
        XCTAssertGreaterThan(inside, 3, "Ellipse must affect the intended region")
        XCTAssertLessThan(outside, 1, "Ellipse must not become a global adjustment")
        recipe.localAdjustments.append(LocalExposure(id: "window", exposureEV: -0.5, mask: .gradient(anchorX: 0.5, anchorY: 0.2, rotation: 0, compression: 0.3)))
        let first = try pixels(render(engine!, recipe, "combined"))
        XCTAssertGreaterThan(difference(first, ellipse, x: 0...1, y: 0...1), 0.1, "Gradient must affect pixels")
        engine = nil
        let restarted = try DarktableProcess(executable: URL(fileURLWithPath: executable), source: sourceURL, directory: directory)
        let replay = try pixels(render(restarted, recipe, "replay"))
        XCTAssertEqual(first.bytes, replay.bytes, "Rebuilt recipe in a fresh process must reproduce pixels")
        let full = try pixels(render(restarted, recipe, "full", full: true), width: first.width, height: first.height)
        XCTAssertLessThan(difference(first, full, x: 0...1, y: 0...1), 3, "Preview and full-size must use consistent mask geometry/color")
        recipe.exposureEV = 0.5
        let changed = try pixels(render(restarted, recipe, "earlier-exposure"))
        XCTAssertGreaterThan(difference(first, changed, x: 0...1, y: 0...1), 3)
        XCTAssertEqual(try contentHash(sourceURL), before)
        print("Real renderer artifacts: \(directory.path); ellipse inside=\(inside), outside=\(outside)")
    }

    func testRealMaskDirectionTransitionAndOutwardFeather() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let executable = environment["KEEPS_TEST_DARKTABLE"] else {
            throw XCTSkip("Set KEEPS_TEST_DARKTABLE for synthetic RAW mask geometry validation")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("keeps-mask-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("synthetic.dng")
        try uniformDNG().write(to: sourceURL)
        let originalHash = try contentHash(sourceURL)
        let engine = try DarktableProcess(executable: URL(fileURLWithPath: executable), source: sourceURL, directory: directory.appendingPathComponent("job"))
        func render(_ mask: ColorMask?, _ id: String) throws -> Pixels {
            var recipe = ColorRecipe()
            if let mask { recipe.localAdjustments = [.init(id: id, exposureEV: -1, mask: mask)] }
            let candidate = try engine.store.add(operationID: id, parentID: nil, recipe: JSONEncoder().encode(recipe))
            return try pixels(engine.render(xmp: DarktableRecipe.apply(recipe, to: engine.baseline, maskDirectory: engine.directory.appendingPathComponent("masks")), candidateID: candidate.id), width: 256, height: 192)
        }
        let baseline = try render(nil, "baseline")
        let regions: [(ClosedRange<Double>, ClosedRange<Double>)] = [
            (0.4...0.6, 0.1...0.2), (0.1...0.2, 0.4...0.6),
            (0.8...0.9, 0.4...0.6), (0.4...0.6, 0.8...0.9)
        ]
        for (index, angle) in [0.0, 90, -90, 180].enumerated() {
            let result = try render(.gradient(anchorX: 0.5, anchorY: 0.5, rotation: angle, compression: 0.1), "gradient-\(index)")
            let affected = regions[index], protected = regions[3-index]
            XCTAssertGreaterThan(difference(baseline, result, x: affected.0, y: affected.1), 10, "angle \(angle) direction")
            XCTAssertLessThan(difference(baseline, result, x: protected.0, y: protected.1), 1, "angle \(angle) protected side")
            if index == 0 {
                // Diagonal=320, so compression .1 gives a 64 px transition around y=96.
                let above = difference(baseline, result, x: 0.4...0.6, y: 0.36...0.38)
                let center = difference(baseline, result, x: 0.4...0.6, y: 0.49...0.51)
                let below = difference(baseline, result, x: 0.4...0.6, y: 0.62...0.64)
                XCTAssertGreaterThan(above, center)
                XCTAssertGreaterThan(center, below)
                XCTAssertGreaterThan(below, 1, "Feather must extend below the 50 percent anchor")
            }
        }
        let ellipse = try render(.ellipse(centerX: 0.5, centerY: 0.5, radiusX: 0.1, radiusY: 0.1, rotation: 0, feather: 0.1), "ellipse")
        let inside = difference(baseline, ellipse, x: 0.49...0.51, y: 0.49...0.51)
        let feather = difference(baseline, ellipse, x: 0.60...0.62, y: 0.49...0.51)
        let outside = difference(baseline, ellipse, x: 0.68...0.70, y: 0.49...0.51)
        XCTAssertGreaterThan(inside, feather)
        XCTAssertGreaterThan(feather, 1, "Feather must extend OUTSIDE the inner ellipse")
        XCTAssertLessThan(outside, 1)
        let maskData = try rasterPNG()
        let mask = ColorMask.raster(pngBase64: maskData.base64EncodedString(), invert: false)
        let raster = try render(mask, "raster")
        XCTAssertGreaterThan(difference(baseline, raster, x: 0.10...0.20, y: 0.4...0.6), 10)
        XCTAssertLessThan(difference(baseline, raster, x: 0.8...0.9, y: 0.4...0.6), 1)
        XCTAssertLessThan(difference(baseline, raster, x: 0.25...0.30, y: 0.45...0.55), 1, "Raster must retain a background hole inside the subject")
        let inverted = try render(.raster(pngBase64: maskData.base64EncodedString(), invert: true), "background")
        XCTAssertLessThan(difference(baseline, inverted, x: 0.10...0.20, y: 0.4...0.6), 1)
        XCTAssertGreaterThan(difference(baseline, inverted, x: 0.8...0.9, y: 0.4...0.6), 10)
        let replayDirectory = directory.appendingPathComponent("replay")
        let replayEngine = try DarktableProcess(executable: URL(fileURLWithPath: executable), source: sourceURL, directory: replayDirectory)
        let recipe = ColorRecipe(localAdjustments: [.init(id: "raster", exposureEV: -1, mask: mask)])
        let persisted = try DarktableRecipe.decode(JSONEncoder().encode(recipe))
        let candidate = try replayEngine.store.add(operationID: "replay", parentID: nil, recipe: JSONEncoder().encode(persisted))
        let replay = try pixels(replayEngine.render(xmp: DarktableRecipe.apply(persisted, to: replayEngine.baseline, maskDirectory: replayDirectory.appendingPathComponent("masks")), candidateID: candidate.id, full: true), width: 256, height: 192)
        XCTAssertEqual(raster.bytes, replay.bytes, "Embedded raster must replay in a fresh directory without its old mask files")
        XCTAssertEqual(try contentHash(sourceURL), originalHash)
    }

    func testRealRasterMaskFollowsPortraitOrientation() throws {
        guard let executable = ProcessInfo.processInfo.environment["KEEPS_TEST_DARKTABLE"] else {
            throw XCTSkip("Set KEEPS_TEST_DARKTABLE for portrait raster validation")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("keeps-portrait-mask-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("portrait.dng")
        try uniformDNG(orientation: 6).write(to: source)
        let engine = try DarktableProcess(executable: URL(fileURLWithPath: executable), source: source, directory: root.appendingPathComponent("job"))
        func render(_ recipe: ColorRecipe, id: String) throws -> Pixels {
            let candidate = try engine.store.add(operationID: id, parentID: nil, recipe: JSONEncoder().encode(recipe))
            let url = try engine.render(xmp: DarktableRecipe.apply(recipe, to: engine.baseline, maskDirectory: engine.directory.appendingPathComponent("masks"), maskOrientation: 6), candidateID: candidate.id)
            let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
            XCTAssertEqual(image.width, 192)
            XCTAssertEqual(image.height, 256)
            return try pixels(url, width: 192, height: 256)
        }
        let baseline = try render(ColorRecipe(), id: "baseline")
        let recipe = ColorRecipe(localAdjustments: [.init(id: "subject", exposureEV: -1, mask: .raster(pngBase64: try rasterPNG().base64EncodedString(), invert: false))])
        let result = try render(recipe, id: "subject")
        XCTAssertGreaterThan(difference(baseline, result, x: 0.10...0.20, y: 0.4...0.6), 10)
        XCTAssertLessThan(difference(baseline, result, x: 0.8...0.9, y: 0.4...0.6), 1)
        XCTAssertLessThan(difference(baseline, result, x: 0.25...0.30, y: 0.45...0.55), 1)
    }

    func testRealJPEGExposureAndReplay() throws {
        try verifyDisplayReferredExposureAndReplay(sourceVariable: "KEEPS_TEST_JPEG")
    }

    func testRealHEIFExposureAndReplay() throws {
        try verifyDisplayReferredExposureAndReplay(sourceVariable: "KEEPS_TEST_HEIF")
    }

    private func verifyDisplayReferredExposureAndReplay(sourceVariable: String) throws {
        let environment = ProcessInfo.processInfo.environment
        guard let executable = environment["KEEPS_TEST_DARKTABLE"], let source = environment[sourceVariable] else {
            throw XCTSkip("Set KEEPS_TEST_DARKTABLE and \(sourceVariable) for real display-referred validation")
        }
        let sourceURL = URL(fileURLWithPath: source)
        let before = try contentHash(sourceURL)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("keeps-jpeg-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var engine: DarktableProcess? = try DarktableProcess(executable: URL(fileURLWithPath: executable), source: sourceURL, directory: directory)
        XCTAssertTrue(engine!.isDisplayReferred)
        XCTAssertFalse(engine!.supportsLocalMasks)
        func render(_ engine: DarktableProcess, recipe: ColorRecipe, operation: String, full: Bool = false) throws -> Pixels {
            let candidate = try engine.store.add(operationID: operation, parentID: nil, recipe: JSONEncoder().encode(recipe))
            return try pixels(engine.render(xmp: DarktableRecipe.apply(recipe, to: engine.baseline), candidateID: candidate.id, full: full))
        }
        let initial = try render(engine!, recipe: ColorRecipe(), operation: "initial")
        let recipe = ColorRecipe(exposureEV: -0.5, saturation: 0.8)
        let changed = try render(engine!, recipe: recipe, operation: "changed")
        XCTAssertGreaterThan(difference(initial, changed, x: 0...1, y: 0...1), 3)
        XCTAssertThrowsError(try DarktableRecipe.apply(ColorRecipe(whiteBalanceRGB: [1.1, 1, 1]), to: engine!.baseline))
        XCTAssertThrowsError(try DarktableRecipe.apply(ColorRecipe(contrast: 1.7), to: engine!.baseline))
        engine = nil
        let restarted = try DarktableProcess(executable: URL(fileURLWithPath: executable), source: sourceURL, directory: directory)
        let replay = try render(restarted, recipe: recipe, operation: "replay", full: true)
        XCTAssertLessThan(difference(changed, replay, x: 0...1, y: 0...1), 1)
        XCTAssertEqual(try contentHash(sourceURL), before)
    }

    private func rasterPNG() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 256 * 192)
        for y in 0..<192 {
            for x in 0..<128 where !(x >= 56 && x < 88 && y >= 72 && y < 120) { bytes[y * 256 + x] = 255 }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: 256, height: 192, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 256, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func uniformDNG(orientation: UInt16 = 1) -> Data {
        func u16(_ value: UInt16) -> [UInt8] { [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)] }
        func u32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
        var entries: [(UInt16, UInt16, UInt32, [UInt8])] = []
        func short(_ tag: UInt16, _ values: [UInt16]) { entries.append((tag, 3, UInt32(values.count), values.flatMap(u16))) }
        func long(_ tag: UInt16, _ value: UInt32) { entries.append((tag, 4, 1, u32(value))) }
        func bytes(_ tag: UInt16, _ values: [UInt8], type: UInt16 = 1) { entries.append((tag, type, UInt32(values.count), values)) }
        func rationals(_ tag: UInt16, _ values: [UInt32], signed: Bool = false) {
            entries.append((tag, signed ? 10 : 5, UInt32(values.count), values.flatMap { u32($0) + u32(1) }))
        }
        long(254, 0); long(256, 256); long(257, 192); short(258, [16]); short(259, [1])
        short(262, [32803]); bytes(271, Array("Keeps\0".utf8), type: 2)
        bytes(272, Array("Synthetic\0".utf8), type: 2); long(273, 0); short(274, [orientation])
        short(277, [1]); long(278, 192); long(279, 256 * 192 * 2)
        short(33421, [2, 2]); bytes(33422, [0, 1, 1, 2]); bytes(50706, [1, 4, 0, 0])
        bytes(50707, [1, 1, 0, 0]); bytes(50708, Array("Keeps Synthetic DNG\0".utf8), type: 2)
        rationals(50714, [0]); long(50717, 65535)
        rationals(50721, [1, 0, 0, 0, 1, 0, 0, 0, 1], signed: true)
        rationals(50728, [1, 1, 1]); short(50778, [21]); entries.sort { $0.0 < $1.0 }
        let extraOffset = 8 + 2 + entries.count * 12 + 4
        var extra: [UInt8] = [], records: [UInt8] = []
        for (tag, type, count, data) in entries {
            records += u16(tag) + u16(type) + u32(count)
            if data.count > 4 {
                records += u32(UInt32(extraOffset + extra.count)); extra += data
                if extra.count % 2 != 0 { extra.append(0) }
            } else { records += data + Array(repeating: 0, count: 4 - data.count) }
        }
        let strip = entries.firstIndex { $0.0 == 273 }! * 12 + 8
        records.replaceSubrange(strip..<(strip + 4), with: u32(UInt32(extraOffset + extra.count)))
        var output = Data([73, 73, 42, 0])
        output.append(contentsOf: u32(8))
        output.append(contentsOf: u16(UInt16(entries.count)))
        output.append(contentsOf: records)
        output.append(contentsOf: u32(0))
        output.append(contentsOf: extra)
        let pixel = u16(16000)
        for _ in 0..<(256 * 192) { output.append(contentsOf: pixel) }
        return output
    }

    private struct Pixels { let bytes: [UInt8]; let width: Int; let height: Int }
    private func pixels(_ url: URL, width: Int = 400, height: Int = 267) throws -> Pixels {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width*4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return Pixels(bytes: bytes, width: width, height: height)
    }
    private func difference(_ a: Pixels, _ b: Pixels, x: ClosedRange<Double>, y: ClosedRange<Double>) -> Double {
        var sum = 0.0; var count = 0
        for row in Int(y.lowerBound*Double(a.height))..<min(a.height, Int(y.upperBound*Double(a.height))) {
            for col in Int(x.lowerBound*Double(a.width))..<min(a.width, Int(x.upperBound*Double(a.width))) {
                for channel in 0..<3 {
                    let index = (row*a.width+col)*4+channel
                    sum += abs(Double(a.bytes[index])-Double(b.bytes[index])); count += 1
                }
            }
        }
        return sum / Double(count)
    }
}
