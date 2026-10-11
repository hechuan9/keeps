import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

public enum PreviewAnalysis {
    public static func crop(_ url: URL, x: Double, y: Double, width: Double, height: Double) throws -> (Data, [String: Double]) {
        guard [x,y,width,height].allSatisfy(\.isFinite), x >= 0, y >= 0, width > 0, height > 0, x+width <= 1, y+height <= 1 else { throw ColorToolError("Region must fit inside normalized preview coordinates") }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil), let crop = image.cropping(to: CGRect(x: x*Double(image.width), y: y*Double(image.height), width: width*Double(image.width), height: height*Double(image.height)).integral) else { throw ColorToolError("Cannot decode/crop preview") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw ColorToolError("Cannot encode preview crop") }
        CGImageDestinationAddImage(destination, crop, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ColorToolError("Cannot finalize preview crop") }
        var pixels = [UInt8](repeating: 0, count: 128*128*4)
        try pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 512, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ColorToolError("Cannot analyze preview") }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 128, height: 128))
        }
        var luma: [Double] = []
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let red = 0.2126 * Double(pixels[offset])
            let green = 0.7152 * Double(pixels[offset + 1])
            let blue = 0.0722 * Double(pixels[offset + 2])
            luma.append((red + green + blue) / 255)
        }
        luma.sort()
        return (data as Data, ["sRGBLumaMedian": luma[luma.count/2], "sRGBLumaP05": luma[luma.count/20], "sRGBLumaP95": luma[luma.count*19/20]])
    }
}
