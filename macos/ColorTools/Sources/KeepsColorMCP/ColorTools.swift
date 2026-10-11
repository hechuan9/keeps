import Foundation
import CryptoKit
import KeepsColorCore

@MainActor final class ColorTools {
    private let engine: DarktableProcess
    private let encoder: JSONEncoder
    private let initial: ColorCandidate
    private let original: ColorCandidate
    private let candidateLimit: Int

    init(engine: DarktableProcess, baseRecipe: Data? = nil) throws {
        self.engine = engine
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        original = try engine.store.add(operationID: "baseline", parentID: nil, recipe: encoder.encode(ColorRecipe()))
        if let baseRecipe {
            let recipe = try DarktableRecipe.decode(baseRecipe)
            try Self.validateMaskSupport(recipe, engine: engine)
            _ = try DarktableRecipe.apply(recipe, to: engine.baseline, maskDirectory: engine.directory.appendingPathComponent("masks"), maskOrientation: engine.sourceOrientation ?? 1)
            initial = try engine.store.add(operationID: "iteration-base", parentID: original.id, recipe: encoder.encode(recipe))
        } else {
            initial = original
        }
        candidateLimit = baseRecipe == nil ? 2 : 3
    }

    func selectCandidate(_ id: String) throws -> [String: Any] {
        let rendered = try preview(id)
        let full = try preview(id, full: true)
        let selection: [String: Any] = ["candidateID": id, "preview": rendered.path, "fullSize": full.path, "published": false]
        try JSONSerialization.data(withJSONObject: selection, options: [.sortedKeys]).write(to: engine.directory.appendingPathComponent("selection.json"), options: .atomic)
        return selection
    }

    private func preview(_ id: String, full: Bool = false) throws -> URL {
        let candidate = try engine.store.candidate(id)
        let recipe = try DarktableRecipe.decode(candidate.recipe)
        return try engine.render(xmp: DarktableRecipe.apply(recipe, to: engine.baseline, maskDirectory: engine.directory.appendingPathComponent("masks"), maskOrientation: engine.sourceOrientation ?? 1), candidateID: id, full: full)
    }

    private static func validateMaskSupport(_ recipe: ColorRecipe, engine: DarktableProcess) throws {
        for local in recipe.localAdjustments {
            switch local.mask {
            case .raster:
                guard engine.supportsSemanticMasks else { throw ColorToolError("Semantic masks require a RAW source with a supported orientation") }
            case .ellipse, .gradient:
                guard engine.supportsLocalMasks else { throw ColorToolError("Geometric masks require source orientation 1") }
            }
        }
    }

    private func retainMask(_ data: Data) throws -> String {
        let id = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let directory = engine.directory.appendingPathComponent("semantic-masks")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(id + ".png")
        if !FileManager.default.fileExists(atPath: path.path) { try data.write(to: path, options: .atomic) }
        return id
    }

    private func publicRecipe(_ data: Data) throws -> [String: Any] {
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        guard var locals = object["localAdjustments"] as? [[String: Any]] else { return object }
        for index in locals.indices {
            guard let mask = locals[index]["mask"] as? [String: Any],
                  let raster = mask["raster"] as? [String: Any],
                  let encoded = raster["pngBase64"] as? String,
                  let png = Data(base64Encoded: encoded) else { continue }
            locals[index]["mask"] = ["raster": ["maskID": try retainMask(png), "invert": raster["invert"] ?? false]]
        }
        object["localAdjustments"] = locals
        return object
    }

    private func resolvedPatch(_ patch: [String: Any]) throws -> [String: Any] {
        var patch = patch
        guard var locals = patch["localAdjustments"] as? [[String: Any]] else { return patch }
        for index in locals.indices {
            guard let mask = locals[index]["mask"] as? [String: Any],
                  let raster = mask["raster"] as? [String: Any] else { continue }
            guard Set(raster.keys) == Set(["maskID", "invert"]),
                  let id = raster["maskID"] as? String,
                  id.count == 64, id.allSatisfy({ "0123456789abcdef".contains($0) }),
                  let invert = raster["invert"] as? Bool else { throw ColorToolError("Use a maskID from generate_mask or get_recipe") }
            let path = engine.directory.appendingPathComponent("semantic-masks").appendingPathComponent(id + ".png")
            guard FileManager.default.fileExists(atPath: path.path) else { throw ColorToolError("Unknown maskID; call generate_mask or get_recipe first") }
            let png = try Data(contentsOf: path)
            locals[index]["mask"] = ["raster": ["pngBase64": png.base64EncodedString(), "invert": invert]]
        }
        patch["localAdjustments"] = locals
        return patch
    }
    func call(_ name: String, _ arguments: [String: Any]) throws -> [[String: Any]] {
        guard let definition = tools.first(where: { $0["name"] as? String == name }),
              let schema = definition["inputSchema"] as? [String: Any],
              let fields = schema["properties"] as? [String: Any],
              Set(arguments.keys).isSubset(of: Set(fields.keys)) else { throw ColorToolError("Unknown tool or argument") }
        func string(_ key: String) throws -> String {
            guard let value = arguments[key] as? String else { throw ColorToolError("Missing string: \(key)") }
            return value
        }
        switch name {
        case "inspect_photo":
            _ = try preview(original.id)
            let image = try imageBlock(preview(initial.id))
            var maskGeometry: [String: Any] = [:]
            if let width = engine.sourcePixelWidth, let height = engine.sourcePixelHeight {
                maskGeometry = ["width": width, "height": height, "shorterEdge": min(width, height), "diagonal": hypot(Double(width), Double(height))]
            }
            return [try textBlock(["rawMaskGeometryPixels": maskGeometry, "initialCandidateID": initial.id, "candidates": engine.store.candidates.map(\.id), "engine": "darktable 5.6.2", "supportsLocalMasks": engine.supportsLocalMasks, "supportsSemanticMasks": engine.supportsSemanticMasks, "semanticMaskTypes": engine.supportsSemanticMasks ? ["person", "background"] + (SkySegmentation.isAvailable ? ["sky"] : []) : [], "localMaskTypes": (engine.supportsLocalMasks ? ["ellipse", "gradient"] : []) + (engine.supportsSemanticMasks ? ["raster"] : []), "supportedAdjustments": engine.isDisplayReferred ? ["exposureEV", "saturation"] : ["exposureEV", "whiteBalanceRGB", "contrast", "skew", "saturation", "localAdjustments"], "remainingAdjustments": max(0, candidateLimit - engine.store.candidates.count)]), image]
        case "generate_mask":
            guard engine.supportsSemanticMasks else { throw ColorToolError("Semantic masks require a RAW source with a supported orientation") }
            let kind = try string("kind")
            let png = try SemanticMasks.pngData(kind: kind, imageURL: preview(original.id))
            let mask = ColorMask.raster(pngBase64: png.base64EncodedString(), invert: false)
            try ColorRecipe(localAdjustments: [.init(id: "mask", exposureEV: 0, mask: mask)]).validate()
            let id = try retainMask(png)
            return [try textBlock(["maskID": id, "kind": kind, "white": "affected region", "black": "protected region", "review": "Inspect edges and excluded background before applying. Segmentation can make mistakes; never substitute an ellipse for a failed semantic mask."]),
                    ["type": "image", "mimeType": "image/png", "data": png.base64EncodedString()]]
        case "get_recipe":
            let candidate = try engine.store.candidate(string("candidateID"))
            return [try textBlock(["candidateID": candidate.id, "recipe": publicRecipe(candidate.recipe)])]
        case "set_adjustments":
            let parent = try engine.store.candidate(string("parentID"))
            let operation = try string("operationID")
            guard let patch = arguments["adjustments"] as? [String: Any], !patch.isEmpty else { throw ColorToolError("Empty adjustments") }
            var merged = try JSONSerialization.jsonObject(with: parent.recipe) as! [String: Any]
            for (key, value) in try resolvedPatch(patch) { merged[key] = value }
            let recipe = try DarktableRecipe.decode(JSONSerialization.data(withJSONObject: merged))
            try Self.validateMaskSupport(recipe, engine: engine)
            _ = try DarktableRecipe.apply(recipe, to: engine.baseline, maskDirectory: engine.directory.appendingPathComponent("masks"), maskOrientation: engine.sourceOrientation ?? 1)
            guard engine.store.candidates.count < candidateLimit || engine.store.candidates.contains(where: { $0.operationID == operation }) else { throw ColorToolError("Adjustment budget exhausted") }
            let candidate = try engine.store.add(operationID: operation, parentID: parent.id, recipe: encoder.encode(recipe))
            return [try textBlock(["candidateID": candidate.id])]
        case "preview_region":
            let id = try string("candidateID")
            guard id == original.id || id == initial.id else { throw ColorToolError("Only inspect the original or initial candidate before adjusting; the human reviews adjusted candidates") }
            func number(_ key: String) throws -> Double {
                guard let value = arguments[key] as? Double else { throw ColorToolError("Missing number: \(key)") }
                return value
            }
            let (data, stats) = try PreviewAnalysis.crop(preview(id), x: number("x"), y: number("y"), width: number("width"), height: number("height"))
            return [try textBlock(stats), ["type": "image", "mimeType": "image/jpeg", "data": data.base64EncodedString()]]
        case "render_preview":
            let id = try string("candidateID")
            let rendered = try preview(id)
            return [try textBlock(["candidateID": id, "preview": rendered.path, "readyForHuman": true])]
        default: throw ColorToolError("Unknown tool")
        }
    }
}
