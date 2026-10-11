import Foundation
import zlib
import ImageIO
import CryptoKit
import CoreImage

public enum RecipeError: Error, CustomStringConvertible {
    case invalid(String)
    public var description: String { switch self { case .invalid(let message): return message } }
}

public enum ColorMask: Codable, Equatable, Sendable {
    case ellipse(centerX: Double, centerY: Double, radiusX: Double, radiusY: Double, rotation: Double, feather: Double)
    case gradient(anchorX: Double, anchorY: Double, rotation: Double, compression: Double)
    case raster(pngBase64: String, invert: Bool)
}
public struct LocalExposure: Codable, Equatable, Sendable {
    public var id: String
    public var exposureEV: Double
    public var mask: ColorMask
    public init(id: String, exposureEV: Double, mask: ColorMask) { self.id = id; self.exposureEV = exposureEV; self.mask = mask }
}
public struct ColorRecipe: Codable, Equatable, Sendable {
    public var exposureEV: Double
    public var whiteBalanceRGB: [Double]
    public var contrast: Double
    public var skew: Double
    public var saturation: Double
    public var localAdjustments: [LocalExposure]
    public init(exposureEV: Double = 0, whiteBalanceRGB: [Double] = [1,1,1], contrast: Double = 1.5, skew: Double = 0, saturation: Double = 1, localAdjustments: [LocalExposure] = []) {
        self.exposureEV = exposureEV; self.whiteBalanceRGB = whiteBalanceRGB; self.contrast = contrast; self.skew = skew; self.saturation = saturation; self.localAdjustments = localAdjustments
    }
    public func validate() throws {
        func check(_ value: Double, _ range: ClosedRange<Double>, _ name: String) throws {
            guard value.isFinite, range.contains(value) else { throw RecipeError.invalid("\(name) outside \(range)") }
        }
        try check(exposureEV, -5...5, "exposureEV")
        guard whiteBalanceRGB.count == 3 else { throw RecipeError.invalid("whiteBalanceRGB requires three source-relative multipliers") }
        for v in whiteBalanceRGB { try check(v, 0.5...2, "whiteBalanceRGB") }
        try check(contrast, 0.5...3, "contrast"); try check(skew, -1...1, "skew"); try check(saturation, 0...2, "saturation")
        guard localAdjustments.count <= 8, Set(localAdjustments.map(\.id)).count == localAdjustments.count else { throw RecipeError.invalid("At most eight uniquely named local adjustments") }
        for local in localAdjustments {
            guard !local.id.isEmpty else { throw RecipeError.invalid("Empty adjustment id") }
            try check(local.exposureEV, -3...3, "local exposure")
            switch local.mask {
            case let .ellipse(x,y,rx,ry,rotation,feather):
                try check(x,0...1,"centerX"); try check(y,0...1,"centerY"); try check(rx,0.002...1,"radiusX"); try check(ry,0.002...1,"radiusY"); try check(rotation,-180...180,"rotation"); try check(feather,0.001...1,"feather")
            case let .raster(pngBase64, _):
                _ = try DarktableRecipe.rasterPNG(pngBase64)
            case let .gradient(x,y,rotation,compression):
                try check(x,0...1,"anchorX"); try check(y,0...1,"anchorY"); try check(rotation,-180...180,"rotation"); try check(compression,0.001...1,"compression")
            }
        }
    }
}

// The binary layouts are pinned to darktable release-5.6.2: src/iop/{exposure,
// temperature,sigmoid,colorbalancergb}.c, src/develop/{blend,masks}.h and
// src/common/{exif.cc,iop_order.c}. Reject upgrades until replay is verified.
public enum DarktableRecipe {
    public static let engineVersion = "5.6.2"
    public static func decode(_ data: Data) throws -> ColorRecipe {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw RecipeError.invalid("Recipe must be an object") }
        let allowed: Set<String> = ["exposureEV","whiteBalanceRGB","contrast","skew","saturation","localAdjustments"]
        guard Set(object.keys).isSubset(of: allowed) else { throw RecipeError.invalid("Unknown recipe parameter") }
        if let locals = object["localAdjustments"] as? [[String: Any]] {
            for local in locals {
                guard Set(local.keys) == Set(["id","exposureEV","mask"]), let mask = local["mask"] as? [String:Any], mask.count == 1, let kind = mask.keys.first, let fields = mask[kind] as? [String:Any] else { throw RecipeError.invalid("Invalid local adjustment") }
                let keys: Set<String>
                switch kind {
                case "ellipse": keys = ["centerX","centerY","radiusX","radiusY","rotation","feather"]
                case "gradient": keys = ["anchorX","anchorY","rotation","compression"]
                case "raster": keys = ["pngBase64", "invert"]
                default: throw RecipeError.invalid("Unknown mask type")
                }
                guard Set(fields.keys) == keys else { throw RecipeError.invalid("Unknown or missing mask parameter") }
            }
        }
        let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ColorRecipe())) as! [String:Any]
        var merged = defaults; for (key,value) in object { merged[key] = value }
        let recipe = try JSONDecoder().decode(ColorRecipe.self, from: JSONSerialization.data(withJSONObject: merged))
        try recipe.validate(); return recipe
    }
    public static func apply(_ recipe: ColorRecipe, to baselineXMP: String, maskDirectory: URL? = nil, maskOrientation: Int = 1) throws -> String {
        try recipe.validate()
        let doc = try XMLDocument(xmlString: baselineXMP, options: [.nodePreserveAll])
        guard let description = try doc.nodes(forXPath: "//*[local-name()='Description']").first as? XMLElement,
              description.attribute(forName: "darktable:xmp_version")?.stringValue == "5",
              ["4", "5"].contains(description.attribute(forName: "darktable:iop_order_version")?.stringValue ?? ""),
              description.attribute(forName: "darktable:iop_order_list") == nil,
              let history = try doc.nodes(forXPath: "//*[local-name()='history']/*[local-name()='Seq']").first as? XMLElement,
              let masks = try doc.nodes(forXPath: "//*[local-name()='masks_history']/*[local-name()='Seq']").first as? XMLElement,
              masks.childCount == 0 else { throw RecipeError.invalid("Requires pristine darktable 5.6.2 baseline (XMP 5, order 4 or 5, no masks/custom order)") }
        if description.attribute(forName: "darktable:iop_order_version")?.stringValue == "5" {
            return try applyDisplayReferred(recipe, document: doc, description: description, history: history)
        }
        let items = history.children?.compactMap { $0 as? XMLElement } ?? []
        func module(_ operation: String, version: Int, size: Int) throws -> (XMLElement, [UInt8]) {
            let matches = items.filter { $0.attribute(forName: "darktable:operation")?.stringValue == operation }
            guard matches.count == 1, let node = matches.first,
                  node.attribute(forName: "darktable:modversion")?.stringValue == String(version),
                  node.attribute(forName: "darktable:multi_priority")?.stringValue == "0",
                  node.attribute(forName: "darktable:blendop_version")?.stringValue == "14",
                  let encoded = node.attribute(forName: "darktable:params")?.stringValue else { throw RecipeError.invalid("Unsupported \(operation) module version/instance") }
            let bytes = try unpack(encoded)
            guard bytes.count == size else { throw RecipeError.invalid("Invalid \(operation) parameter size") }
            return (node,bytes)
        }
        let (exposure, originalExposure) = try module("exposure", version: 7, size: 28)
        var exposureBytes = originalExposure
        put(0, into: &exposureBytes, at: 0); putFloat(recipe.exposureEV, into: &exposureBytes, at: 8)
        put(0, into: &exposureBytes, at: 20)
        set(exposure,"params",hex(exposureBytes))
        let (wb, initialWB) = try module("temperature", version: 4, size: 20)
        var wbBytes = initialWB
        for index in 0..<3 { putFloat(Double(readFloat(wbBytes,index*4))*recipe.whiteBalanceRGB[index], into: &wbBytes, at: index*4) }
        set(wb,"params",hex(wbBytes))
        let (sigmoid, initialSigmoid) = try module("sigmoid", version: 3, size: 56)
        var sigmoidBytes = initialSigmoid
        putFloat(recipe.contrast,into:&sigmoidBytes,at:0); putFloat(recipe.skew,into:&sigmoidBytes,at:4)
        set(sigmoid,"params",hex(sigmoidBytes))
        guard let blendText = exposure.attribute(forName:"darktable:blendop_params")?.stringValue else { throw RecipeError.invalid("Missing blend parameters") }
        let initialBlend = try unpack(blendText)
        guard initialBlend.count == 420 else { throw RecipeError.invalid("Unsupported blend v14 size") }
        var num = items.count
        if recipe.saturation != 1 {
            guard !items.contains(where: { $0.attribute(forName:"darktable:operation")?.stringValue == "colorbalancergb" }) else { throw RecipeError.invalid("Baseline already has color balance") }
            var params = [UInt8](repeating:0,count:132)
            for index in [12,14] { putFloat(1,into:&params,at:index*4) }
            for index in [28,30] { putFloat(0.1845,into:&params,at:index*4) }
            putFloat(recipe.saturation-1,into:&params,at:19*4); put(1,into:&params,at:128)
            let node = exposure.copy() as! XMLElement
            set(node,"num",String(num)); set(node,"operation","colorbalancergb"); set(node,"modversion","5"); set(node,"params",hex(params)); set(node,"multi_name","Keeps saturation")
            history.addChild(node); num += 1
        }
        var rasterInstances: [Int] = []
        for (index,local) in recipe.localAdjustments.enumerated() {
            let shapeID = 1000 + index*2, groupID = shapeID+1
            var shape = [UInt8](repeating:0,count:28)
            var blend = initialBlend
            let type: Int
            switch local.mask {
            case let .raster(pngBase64, invert):
                guard let maskDirectory else { throw RecipeError.invalid("Raster masks require a private mask directory") }
                let file = try materializeRaster(pngBase64, directory: maskDirectory, orientation: maskOrientation)
                let instance = index + 1
                rasterInstances.append(instance)
                var rasterParams = [UInt8](repeating: 0, count: 4100)
                put(7, into: &rasterParams, at: 0)
                try putCString(file.deletingLastPathComponent().path, into: &rasterParams, at: 4, capacity: 2048)
                try putCString(file.lastPathComponent, into: &rasterParams, at: 2052, capacity: 2048)
                let raster = exposure.copy() as! XMLElement
                set(raster, "num", String(num)); set(raster, "operation", "rasterfile")
                set(raster, "modversion", "1"); set(raster, "params", hex(rasterParams))
                set(raster, "multi_priority", String(instance)); set(raster, "multi_name", local.id + " mask")
                var rasterBlend = initialBlend; put(0, into: &rasterBlend, at: 0)
                set(raster, "blendop_params", hex(rasterBlend))
                history.addChild(raster); num += 1
                // blend v14 ends with source[20], instance, raster id and inversion.
                put(9, into: &blend, at: 0)
                try putCString("rasterfile", into: &blend, at: 388, capacity: 20)
                put(UInt32(instance), into: &blend, at: 408)
                put(0, into: &blend, at: 412)
                put(invert ? 1 : 0, into: &blend, at: 416)
                type = 0
            case let .ellipse(x,y,rx,ry,rotation,feather):
                type = 32
                for (i,v) in [x,y,rx,ry,rotation,feather].enumerated() { putFloat(v,into:&shape,at:i*4) }
                put(0,into:&shape,at:24)
            case let .gradient(x,y,rotation,compression):
                type = 16
                for (i,v) in [x,y,rotation,compression,0,0].enumerated() { putFloat(v,into:&shape,at:i*4) }
                put(1,into:&shape,at:24)
            }
            var group = [UInt8](repeating:0,count:16)
            put(UInt32(shapeID),into:&group,at:0); put(UInt32(groupID),into:&group,at:4); put(3,into:&group,at:8); putFloat(1,into:&group,at:12)
            if type != 0 {
                for (id,t,bytes,name) in [(shapeID,type,shape,local.id),(groupID,4,group,local.id+" group")] {
                    let node = XMLElement(name:"rdf:li")
                    for (key,value) in ["mask_num":String(num),"mask_id":String(id),"mask_type":String(t),"mask_name":name,"mask_version":"6","mask_points":hex(bytes),"mask_nb":"1","mask_src":"0000000000000000"] { set(node,key,value) }
                    masks.addChild(node)
                }
                put(3,into:&blend,at:0); put(UInt32(groupID),into:&blend,at:24)
            }
            var params = originalExposure
            put(0,into:&params,at:0); putFloat(0,into:&params,at:4); putFloat(local.exposureEV,into:&params,at:8); put(0,into:&params,at:20); put(0,into:&params,at:24)
            let node = exposure.copy() as! XMLElement
            set(node,"num",String(num)); set(node,"params",hex(params)); set(node,"blendop_params",hex(blend)); set(node,"multi_priority",String(index+1)); set(node,"multi_name",local.id)
            history.addChild(node); num += 1
        }
        set(description,"history_end",String(num))
        if !recipe.localAdjustments.isEmpty {
            var entries = rawOrder.map { "\($0),0" }
            let rasterPosition = entries.firstIndex(of: "rasterfile,0")! + 1
            entries.insert(contentsOf: rasterInstances.map { "rasterfile,\($0)" }, at: rasterPosition)
            let position = entries.firstIndex(of:"exposure,0")! + 1
            entries.insert(contentsOf: recipe.localAdjustments.indices.map { "exposure,\($0+1)" }, at: position)
            set(description,"iop_order_list",entries.joined(separator:","))
        }
        return doc.xmlString(options: [])
    }
    static func rasterPNG(_ base64: String) throws -> Data {
        guard base64.utf8.count <= 699_052, let data = Data(base64Encoded: base64), data.count <= 512 * 1024,
              data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...2048).contains(width), (1...2048).contains(height),
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            throw RecipeError.invalid("Raster mask must be a valid PNG, at most 512 KiB and 2048 pixels per edge")
        }
        return data
    }
    private static func materializeRaster(_ base64: String, directory: URL, orientation: Int) throws -> URL {
        let original = try rasterPNG(base64)
        guard (1...8).contains(orientation) else { throw RecipeError.invalid("Unsupported raster mask orientation") }
        let data: Data
        if orientation == 1 { data = original }
        else {
            // Segmentation uses the upright preview; rasterfile precedes darktable's flip module.
            let inverse: [Int32] = [1, 2, 3, 4, 5, 8, 7, 6]
            guard let image = CIImage(data: original, options: [.colorSpace: NSNull()]) else { throw RecipeError.invalid("Cannot decode raster mask") }
            let transformed = image.oriented(forExifOrientation: inverse[orientation - 1])
            // Coverage must remain numeric; a display transfer curve would change soft mask edges.
            let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
            let width = Int(transformed.extent.width), height = Int(transformed.extent.height)
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            pixels.withUnsafeMutableBytes { bytes in
                context.render(transformed, toBitmap: bytes.baseAddress!, rowBytes: width * 4,
                               bounds: transformed.extent, format: .RGBA8, colorSpace: nil)
            }
            guard let provider = CGDataProvider(data: Data(pixels) as CFData),
                  let cgImage = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
                throw RecipeError.invalid("Cannot orient raster mask")
            }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { throw RecipeError.invalid("Cannot encode raster mask") }
            CGImageDestinationAddImage(destination, cgImage, nil)
            guard CGImageDestinationFinalize(destination) else { throw RecipeError.invalid("Cannot finalize raster mask") }
            data = output as Data
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(digest + ".png")
        if !FileManager.default.fileExists(atPath: file.path) { try data.write(to: file, options: .atomic) }
        return file
    }
    private static func putCString(_ value: String, into data: inout [UInt8], at offset: Int, capacity: Int) throws {
        let bytes = Array(value.utf8)
        guard bytes.count < capacity, !bytes.contains(0) else { throw RecipeError.invalid("Raster mask path exceeds darktable limits") }
        data.replaceSubrange(offset..<(offset + capacity), with: bytes + Array(repeating: 0, count: capacity - bytes.count))
    }
    // The v5 pipeline is already display-referred: retain its color profile and
    // tone response rather than adding the RAW white balance and sigmoid stages.
    private static func applyDisplayReferred(_ recipe: ColorRecipe, document: XMLDocument, description: XMLElement, history: XMLElement) throws -> String {
        guard recipe.whiteBalanceRGB == [1, 1, 1], recipe.contrast == 1.5, recipe.skew == 0, recipe.localAdjustments.isEmpty else {
            throw RecipeError.invalid("Display-referred images support exposureEV and saturation only; RAW white balance, sigmoid and local masks are unavailable")
        }
        let items = history.children?.compactMap { $0 as? XMLElement } ?? []
        guard Set(items.compactMap { $0.attribute(forName: "darktable:operation")?.stringValue }) == Set(["colorin", "colorout", "gamma", "flip"]), items.count == 4,
              let template = items.first,
              template.attribute(forName: "darktable:blendop_version")?.stringValue == "14" else {
            throw RecipeError.invalid("Requires pristine darktable display-referred baseline")
        }
        var count = items.count
        func append(_ operation: String, version: Int, params: [UInt8]) {
            let node = template.copy() as! XMLElement
            for (key, value) in ["num": String(count), "operation": operation, "enabled": "1", "modversion": String(version), "params": hex(params), "multi_priority": "0", "multi_name": "Keeps " + operation] { set(node, key, value) }
            history.addChild(node)
            count += 1
        }
        var exposure = [UInt8](repeating: 0, count: 28)
        putFloat(recipe.exposureEV, into: &exposure, at: 8)
        putFloat(50, into: &exposure, at: 12)
        putFloat(-4, into: &exposure, at: 16)
        append("exposure", version: 7, params: exposure)
        if recipe.saturation != 1 {
            var params = [UInt8](repeating: 0, count: 132)
            for index in [12, 14] { putFloat(1, into: &params, at: index * 4) }
            for index in [28, 30] { putFloat(0.1845, into: &params, at: index * 4) }
            putFloat(recipe.saturation - 1, into: &params, at: 19 * 4)
            put(1, into: &params, at: 128)
            append("colorbalancergb", version: 5, params: params)
        }
        set(description, "history_end", String(count))
        return document.xmlString(options: [])
    }
    private static func set(_ node: XMLElement, _ key: String, _ value: String) {
        let name = "darktable:"+key
        if let attribute = node.attribute(forName:name) { attribute.stringValue = value }
        else { node.addAttribute(XMLNode.attribute(withName:name,stringValue:value) as! XMLNode) }
    }
    private static func put(_ value: UInt32, into bytes: inout [UInt8], at offset: Int) { for i in 0..<4 { bytes[offset+i] = UInt8(truncatingIfNeeded:value >> (i*8)) } }
    private static func putFloat(_ value: Double, into bytes: inout [UInt8], at offset: Int) { put(Float(value).bitPattern,into:&bytes,at:offset) }
    private static func readFloat(_ bytes: [UInt8], _ offset: Int) -> Float { Float(bitPattern:(0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset+$1]) << ($1*8) }) }
    private static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format:"%02x",$0) }.joined() }
    private static func unpack(_ text: String) throws -> [UInt8] {
        if text.hasPrefix("gz") {
            guard text.count >= 4, let compressed = Data(base64Encoded:String(text.dropFirst(4))) else { throw RecipeError.invalid("Invalid compressed blob") }
            var destination = [UInt8](repeating:0,count:65536); var length = uLongf(destination.count)
            let result = compressed.withUnsafeBytes { source in uncompress(&destination,&length,source.bindMemory(to:UInt8.self).baseAddress,uLong(compressed.count)) }
            guard result == Z_OK else { throw RecipeError.invalid("Invalid zlib blob") }; return Array(destination.prefix(Int(length)))
        }
        guard text.count % 2 == 0 else { throw RecipeError.invalid("Invalid hex blob") }
        let chars = Array(text); var result: [UInt8] = []
        for i in stride(from:0,to:chars.count,by:2) { guard let byte = UInt8(String(chars[i...i+1]),radix:16) else { throw RecipeError.invalid("Invalid hex blob") }; result.append(byte) }
        return result
    }
    // Include inactive modules because darktable validates the complete pipeline order.
    private static let rawOrder: [String] = ["rawprepare","invert","temperature","rasterfile","highlights","cacorrect","hotpixels","rawdenoise","demosaic","denoiseprofile","bilateral","rotatepixels","scalepixels","lens","cacorrectrgb","hazeremoval","ashift","flip","enlargecanvas","overlay","clipping","liquify","spots","retouch","exposure","mask_manager","tonemap","toneequal","crop","graduatednd","profile_gamma","equalizer","colorin","channelmixerrgb","diffuse","censorize","negadoctor","blurs","primaries","nlmeans","colorchecker","neutral","defringe","atrous","lowpass","highpass","sharpen","colortransfer","colormapping","channelmixer","basicadj","colorharmonizer","colorbalance","colorequal","colorbalancergb","rgbcurve","rgblevels","basecurve","filmic","sigmoid","agx","filmicrgb","lut3d","colisa","tonecurve","levels","shadhi","zonesystem","globaltonemap","relight","bilat","colorcorrection","colorcontrast","velvia","vibrance","colorzones","bloom","colorize","lowlight","monochrome","grain","soften","splittoning","vignette","colorreconstruct","finalscale","colorout","clahe","overexposed","rawoverexposed","dither","borders","watermark","gamma"]
}
