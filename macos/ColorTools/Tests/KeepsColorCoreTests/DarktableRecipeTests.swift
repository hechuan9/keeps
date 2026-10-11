import XCTest
import ImageIO
import CoreGraphics
@testable import KeepsColorCore

final class DarktableRecipeTests: XCTestCase {
    func testPortraitRasterRotationPreservesSoftCoverage() throws {
        let values: [UInt8] = [64, 128, 191]
        let pixels: [UInt8] = values.flatMap { [$0, $0, $0, UInt8(255)] }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: 3, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 12, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let png = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let recipe = ColorRecipe(localAdjustments: [.init(id: "soft-subject", exposureEV: 1,
            mask: .raster(pngBase64: (png as Data).base64EncodedString(), invert: false))])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("keeps-soft-mask-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for orientation in [6, 8] {
            let masks = directory.appendingPathComponent(String(orientation))
            _ = try DarktableRecipe.apply(recipe, to: Self.baseline, maskDirectory: masks, maskOrientation: orientation)
            let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: masks, includingPropertiesForKeys: nil).first)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
            let rotated = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(rotated.width, 1)
            XCTAssertEqual(rotated.height, 3)
            XCTAssertEqual(rotated.bitsPerComponent, 8)
            let raw = try XCTUnwrap(rotated.dataProvider?.data) as Data
            let coverage = (0..<3).map { raw[$0 * rotated.bytesPerRow] }
            XCTAssertEqual(coverage.sorted(), values, "Rotation must preserve 25%, 50% and 75% coverage bytes")
        }
    }

    func testRejectsUnknownParameter() throws {
        XCTAssertThrowsError(try DarktableRecipe.decode(Data(#"{"exposureEV":1,"mystery":4}"#.utf8)))
    }
    func testRejectsNonFiniteAndInvalidMask() throws {
        XCTAssertThrowsError(try ColorRecipe(exposureEV: .infinity).validate())
        var recipe = ColorRecipe()
        recipe.localAdjustments = [.init(id: "face", exposureEV: 1, mask: .ellipse(centerX: 0.5, centerY: 0.5, radiusX: -1, radiusY: 0.1, rotation: 0, feather: 0.1))]
        XCTAssertThrowsError(try recipe.validate())
    }
    func testRejectsMalformedAndOversizedRasterMasks() {
        for base64 in ["invalid", Data([137, 80, 78, 71, 13, 10, 26, 10]).base64EncodedString(), String(repeating: "A", count: 700_000)] {
            let recipe = ColorRecipe(localAdjustments: [.init(id: "subject", exposureEV: 1, mask: .raster(pngBase64: base64, invert: false))])
            XCTAssertThrowsError(try recipe.validate())
        }
    }
    func testRejectsUnsupportedBaseline() {
        XCTAssertThrowsError(try DarktableRecipe.apply(ColorRecipe(), to: "<root/>"))
    }
    func testRecipeRoundTrip() throws {
        var recipe = ColorRecipe(exposureEV: 1.2)
        recipe.localAdjustments = [.init(id: "sky", exposureEV: -1, mask: .gradient(anchorX: 0.5, anchorY: 0.4, rotation: 90, compression: 0.2))]
        XCTAssertEqual(try DarktableRecipe.decode(JSONEncoder().encode(recipe)), recipe)
    }
    func testNativeMaskReferencesAndOrdering() throws {
        var recipe = ColorRecipe(exposureEV: 1.5, saturation: 1.1)
        recipe.localAdjustments = [.init(id: "face", exposureEV: 1, mask: .ellipse(centerX: 0.5, centerY: 0.5, radiusX: 0.2, radiusY: 0.3, rotation: 0, feather: 0.1)), .init(id: "sky", exposureEV: -1, mask: .gradient(anchorX: 0.5, anchorY: 0.4, rotation: 90, compression: 0.2))]
        let output = try DarktableRecipe.apply(recipe, to: Self.baseline)
        let document = try XMLDocument(xmlString: output)
        let masks = try document.nodes(forXPath: "//*[local-name()='masks_history']/*/*")
        XCTAssertEqual(masks.count, 4)
        XCTAssertTrue(output.contains("exposure,0,exposure,1,exposure,2,"))
        XCTAssertTrue(output.contains("darktable:history_end=\"14\""))
        XCTAssertTrue(output.contains("darktable:mask_type=\"32\""))
        XCTAssertTrue(output.contains("darktable:mask_type=\"16\""))
        XCTAssertThrowsError(try DarktableRecipe.apply(recipe, to: output))
    }
    func testRejectsMismatchedModuleVersion() {
        XCTAssertThrowsError(try DarktableRecipe.apply(ColorRecipe(), to: Self.baseline.replacingOccurrences(of: "darktable:modversion=\"7\"", with: "darktable:modversion=\"8\"")))
    }
    func testJPEGKeepsDisplayPipelineAndRejectsRAWControls() throws {
        let document = try XMLDocument(xmlString: Self.baseline)
        let description = try XCTUnwrap(try document.nodes(forXPath: "//*[local-name()='Description']").first as? XMLElement)
        description.attribute(forName: "darktable:iop_order_version")?.stringValue = "5"
        for case let item as XMLElement in try document.nodes(forXPath: "//*[local-name()='history']/*/*") {
            if !["colorin", "colorout", "gamma", "flip"].contains(item.attribute(forName: "darktable:operation")?.stringValue ?? "") { item.detach() }
        }
        let baseline = document.xmlString
        let output = try DarktableRecipe.apply(ColorRecipe(exposureEV: -0.5, saturation: 0.8), to: baseline)
        XCTAssertTrue(output.contains("darktable:iop_order_version=\"5\""))
        XCTAssertTrue(output.contains("darktable:operation=\"exposure\""))
        XCTAssertTrue(output.contains("darktable:operation=\"colorbalancergb\""))
        XCTAssertFalse(output.contains("darktable:operation=\"sigmoid\""))
        XCTAssertThrowsError(try DarktableRecipe.apply(ColorRecipe(whiteBalanceRGB: [1.1, 1, 1]), to: baseline))
        XCTAssertThrowsError(try DarktableRecipe.apply(ColorRecipe(contrast: 1.7), to: baseline))
        XCTAssertThrowsError(try DarktableRecipe.apply(ColorRecipe(), to: output))
    }
    static let baseline = #"""
<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="XMP Core 4.4.0-Exiv2"> <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"> <rdf:Description rdf:about="" xmlns:xmpMM="http://ns.adobe.com/xap/1.0/mm/" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:darktable="http://darktable.sf.net/" xmpMM:OriginalDocumentID="xmp.did:00000000-0000-4000-8000-000000000001" xmpMM:DerivedFrom="example.ARW" xmp:Rating="0" darktable:xmp_version="5" darktable:raw_params="0" darktable:auto_presets_applied="1" darktable:history_end="11" darktable:iop_order_version="4"> <darktable:masks_history> <rdf:Seq/> </darktable:masks_history> <darktable:history> <rdf:Seq> <rdf:li darktable:num="0" darktable:operation="rawprepare" darktable:enabled="1" darktable:modversion="2" darktable:params="000000000000000008000000000000000002000200020002003c000000000000" darktable:multi_name="" darktable:multi_name_hand_edited="0" darktable:multi_priority="0" darktable:blendop_version="14" darktable:blendop_params="gz11eJxjYIAACQYYOOHEgAZY0QWAgBGLGANDgz0Ej1Q+dcF/IADRAGpyHQU="/> <rdf:li darktable:num="1" darktable:operation="demosaic" darktable:enabled="1" darktable:modversion="6" darktable:params="0000000000000000000000000500000001000000cdcc4c3e000000007d3fb53e00000000080000000000000000000000" darktable:multi_name="" darktable:multi_name_hand_edited="0" darktable:multi_priority="0" darktable:blendop_version="14" darktable:blendop_params="gz11eJxjYIAACQYYOOHEgAZY0QWAgBGLGANDgz0Ej1Q+dcF/IADRAGpyHQU="/> <rdf:li darktable:num="2" darktable:operation="colorin" darktable:enabled="1" darktable:modversion="7" darktable:params="gz48eJzjZhgFowABWAbaAaNgwAEAOQAAEA==" darktable:multi_name="" darktable:multi_name_hand_edited="0" darktable:multi_priority="0" darktable:blendop_version="14" darktable:blendop_params="gz11eJxjYIAACQYYOOHEgAZY0QWAgBGLGANDgz0Ej1Q+dcF/IADRAGpyHQU="/> <rdf:li darktable:num="3" darktable:operation="colorout" darktable:enabled="1" darktable:modversion="5" darktable:params="gz35eJxjZBgFo4CBAQAEEAAC" darktable:multi_name="" darktable:multi_name_hand_edited="0" darktable:multi_priority="0" darktable:blendop_version="14" darktable:blendop_params="gz11eJxjYIAACQYYOOHEgAZY0QWAgBGLGANDgz0Ej1Q+dcF/IADRAGpyHQU="/> <rdf:li darktable:num="4" darktable:operation="gamma" darktable:enabled="1" darktable:modversion="1" darktable:params="0000000000000000" darktable:multi_name="" darktable:multi_name_hand_edited="0" darktable:multi_priority="0" darktable:blendop_version="14" darktable:blendop_params="gz11eJxjYIAACQYYOOHEgAZY0QWAgBGLGANDgz0Ej1Q+dcF/IADRAGpyHQU="/> <rdf:li darktable:num="5" darktable:operation="temperature" darktable:enabled="1" darktable:modversion="4" darktable:params="004038400000803f0080b13f0000000004000000" darktable:multi_name="" darktable:multi_name_hand_edited="0" darktable:multi_priority="0" darktable:blendop_version="14" darktable:blendop_params="gz11eJxjYIAACQYYOOHEgAZY0QWAgBGLGANDgz0Ej1Q+dcF/IADRAGpyHQU="/> <rdf:li darktable:num="6" darktable:operation="highlights" darktable:enabled="1" darktable:modversion="4" darktable:params="050000000000803f00000000000000000000803f000000001e00000006000000cdcccc3e000000400000000000000000" darktable:multi_name="" darktable:multi_name_hand_edited="0" darktable:multi_priority="0" darktable:blendop_version="14" darktable:blendop_params="gz11eJxjYGBgYARiCQYYOOHEgAZY0QWgejBBgz0Ej1Q+dcF/IADRAGwSHQY="/> <rdf:li darktable:num="7" darktable:operation="channelmixerrgb" darktable:enabled="1" darktable:modversion="3" darktable:params="gz04eJxjYGiwZ8AAxIqRD9iBmAmIWYCYEYjvRKy2s2ndYZfyfIUryC5GqDwArn4JGg==" darktable:multi_name="_builtin_scene-referred default" darktable:multi_name_hand_edited="0" darktable:multi_priority="0" darktable:blendop_version="14" darktable:blendop_params="gz08eJxjYGBgYAFiCQYYOOHEgAZY0QWAgBGLGANDgz0Ej1Q+dlAx68oBEMbFxwX+AwGIBgCbGCeh"/> <rdf:li darktable:num="8" darktable:operation="exposure" darktable:enabled="1" darktable:modversion="7" darktable:params="00000000000080b93333333f00004842000080c00100000001000000" darktable:multi_name="_builtin_scene-referred default" darktable:multi_name_hand_edited="0" darktable:multi_priority="0" darktable:blendop_version="14" darktable:blendop_params="gz08eJxjYGBgYAFiCQYYOOHEgAZY0QWAgBGLGANDgz0Ej1Q+dlAx68oBEMbFxwX+AwGIBgCbGCeh"/> <rdf:li darktable:num="9" darktable:operation="flip" darktable:enabled="1" darktable:modversion="2" darktable:params="ffffffff" darktable:multi_name="_builtin_auto" darktable:multi_name_hand_edited="0" darktable:multi_priority="0" darktable:blendop_version="14" darktable:blendop_params="gz11eJxjYIAACQYYOOHEgAZY0QWAgBGLGANDgz0Ej1Q+dcF/IADRAGpyHQU="/> <rdf:li darktable:num="10" darktable:operation="sigmoid" darktable:enabled="1" darktable:modversion="3" darktable:params="0000c03f000000000000c8426c09793c000000000000c8420000000000000000000000000000000000000000000000000000000000000000" darktable:multi_name="_builtin_scene-referred default" darktable:multi_name_hand_edited="0" darktable:multi_priority="0" darktable:blendop_version="14" darktable:blendop_params="gz08eJxjYGBgYAFiCQYYOOHEgAZY0QWAgBGLGANDgz0Ej1Q+dlAx68oBEMbFxwX+AwGIBgCbGCeh"/> </rdf:Seq> </darktable:history> </rdf:Description> </rdf:RDF> </x:xmpmeta>
"""#
}
