import Foundation
import CoreGraphics
import ImageIO
import XCTest
@testable import KeepsColorCore
@testable import KeepsColorMCP

final class IterationTests: XCTestCase {
    @MainActor func testPreviewDefersSelectionAndFullSizeExportToHuman() throws {
        let names = tools.compactMap { $0["name"] as? String }
        XCTAssertFalse(names.contains("compare_candidates"))
        XCTAssertFalse(names.contains("select_candidate"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let job = root.appendingPathComponent("job")
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("renderer")
        try Data("""
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          printf 'darktable 5.6.2\\n'
        else
          printf 'preview fixture' > "$3"
        fi
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let source = root.appendingPathComponent("source.jpg")
        try Data([1, 2, 3]).write(to: source)
        try Data(DarktableRecipeTests.baseline.utf8).write(to: job.appendingPathComponent("baseline.xmp"))
        let engine = try DarktableProcess(executable: executable, source: source, directory: job)
        let api = try ColorTools(engine: engine)
        let initial = try XCTUnwrap(engine.store.candidates.first)
        _ = try api.call("set_adjustments", ["parentID": initial.id, "operationID": "human-choice", "adjustments": ["exposureEV": 0.5]])
        let candidate = try XCTUnwrap(engine.store.candidates.last)
        _ = try api.call("set_adjustments", ["parentID": initial.id, "operationID": "human-choice", "adjustments": ["exposureEV": 0.5]])
        XCTAssertEqual(engine.store.candidates.count, 2)
        XCTAssertThrowsError(try api.call("set_adjustments", ["parentID": candidate.id, "operationID": "second-adjustment", "adjustments": ["exposureEV": 0.8]]))
        XCTAssertThrowsError(try api.call("preview_region", ["candidateID": candidate.id, "x": 0.0, "y": 0.0, "width": 0.5, "height": 0.5]))
        let blocks = try api.call("render_preview", ["candidateID": candidate.id])
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?["type"] as? String, "text")
        let text = try XCTUnwrap(blocks.first?["text"] as? String)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(result["candidateID"] as? String, candidate.id)
        XCTAssertEqual(result["readyForHuman"] as? Bool, true)
        XCTAssertEqual(result["preview"] as? String, job.appendingPathComponent(candidate.id + "-preview.jpg").path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.appendingPathComponent(candidate.id + "-full.jpg").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.appendingPathComponent("selection.json").path))
        XCTAssertThrowsError(try api.call("select_candidate", ["candidateID": candidate.id]))
        XCTAssertThrowsError(try api.call("compare_candidates", ["firstID": initial.id, "secondID": candidate.id]))
        let selected = try api.selectCandidate(candidate.id)
        XCTAssertEqual(selected["candidateID"] as? String, candidate.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: job.appendingPathComponent(candidate.id + "-full.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: job.appendingPathComponent("selection.json").path))
    }

    @MainActor func testRasterRecipeUsesOpaqueToolReferencesAndReplaysExactPixels() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let job = root.appendingPathComponent("job")
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("darktable")
        try Data("#!/bin/sh\nprintf 'darktable 5.6.2\\n'\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let source = root.appendingPathComponent("source.tiff")
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 16, bitsPerComponent: 8,
            bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let image = try XCTUnwrap(context.makeImage())
        let sourceWriter = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, "public.tiff" as CFString, 1, nil))
        CGImageDestinationAddImage(sourceWriter, image, [kCGImagePropertyOrientation: 1] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(sourceWriter))
        let png = NSMutableData()
        let writer = try XCTUnwrap(CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(writer, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        try Data(DarktableRecipeTests.baseline.utf8).write(to: job.appendingPathComponent("baseline.xmp"))
        let engine = try DarktableProcess(executable: executable, source: source, directory: job)
        let raster = ColorMask.raster(pngBase64: (png as Data).base64EncodedString(), invert: false)
        let base = ColorRecipe(localAdjustments: [.init(id: "person", exposureEV: 0.5, mask: raster)])
        let tools = try ColorTools(engine: engine, baseRecipe: JSONEncoder().encode(base))
        let parent = try XCTUnwrap(engine.store.candidates.last)
        let blocks = try tools.call("get_recipe", ["candidateID": parent.id])
        let text = try XCTUnwrap(blocks.first?["text"] as? String)
        XCTAssertFalse(text.contains("pngBase64"))
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        var patch = try XCTUnwrap(response["recipe"] as? [String: Any])
        patch["exposureEV"] = 0.2
        _ = try tools.call("set_adjustments", ["parentID": parent.id, "operationID": "opaque-mask", "adjustments": patch])
        let replay = try DarktableRecipe.decode(XCTUnwrap(engine.store.candidates.last).recipe)
        XCTAssertEqual(replay.localAdjustments, base.localAdjustments)
        XCTAssertEqual(replay.exposureEV, 0.2)
        XCTAssertThrowsError(try tools.call("set_adjustments", ["parentID": parent.id, "operationID": "unknown-mask", "adjustments": ["localAdjustments": [["id": "bad", "exposureEV": 1, "mask": ["raster": ["maskID": "../../source", "invert": false]]]]]]))
    }

    @MainActor func testIterationStartsFromExactRecipeAndRetainsUntouchedParameters() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("keeps-iteration-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let job = root.appendingPathComponent("job")
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("darktable")
        try Data("#!/bin/sh\nprintf 'darktable 5.6.2\\n'\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let source = root.appendingPathComponent("sample.jpg")
        try Data([1, 2, 3]).write(to: source)
        try Data(DarktableRecipeTests.baseline.utf8).write(to: job.appendingPathComponent("baseline.xmp"))
        let engine = try DarktableProcess(executable: executable, source: source, directory: job)
        let base = ColorRecipe(exposureEV: 1.25, whiteBalanceRGB: [1.1, 1, 0.9], contrast: 1.4, saturation: 0.8)
        let tools = try ColorTools(engine: engine, baseRecipe: JSONEncoder().encode(base))
        let initial = try XCTUnwrap(engine.store.candidates.first { $0.operationID == "iteration-base" })
        XCTAssertEqual(try DarktableRecipe.decode(initial.recipe), base)
        _ = try tools.call("set_adjustments", ["parentID": initial.id, "operationID": "reduce-exposure", "adjustments": ["exposureEV": 0.5]])
        let next = try XCTUnwrap(engine.store.candidates.last)
        var expected = base
        expected.exposureEV = 0.5
        XCTAssertEqual(try DarktableRecipe.decode(next.recipe), expected)
        XCTAssertEqual(try Data(contentsOf: source), Data([1, 2, 3]))
    }
}
