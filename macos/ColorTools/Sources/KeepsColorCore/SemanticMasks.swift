import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision

public enum SemanticMasks {
    public static func generate(kind: String, imageURL: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ColorToolError("Cannot decode semantic mask input")
        }
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        let buffer: CVPixelBuffer
        let inverted: Bool
        switch kind {
        case "person":
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = .accurate
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            try handler.perform([request])
            guard let result = request.results?.first else {
                throw ColorToolError("No person segmentation result; no mask was created")
            }
            buffer = result.pixelBuffer
            inverted = false
        case "background":
            let request = VNGenerateForegroundInstanceMaskRequest()
            try handler.perform([request])
            guard let result = request.results?.first, !result.allInstances.isEmpty else {
                throw ColorToolError("No foreground instance detected; cannot determine background")
            }
            buffer = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
            inverted = true
        case "sky":
            buffer = try SkySegmentation.mask(image: image)
            inverted = false
        default:
            throw ColorToolError("Unsupported semantic mask kind: \(kind)")
        }
        return try render(buffer: buffer, width: image.width, height: image.height, inverted: inverted)
    }

    public static func pngData(kind: String, imageURL: URL) throws -> Data {
        let image = try generate(kind: kind, imageURL: imageURL)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ColorToolError("Cannot create semantic mask PNG")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ColorToolError("Cannot encode semantic mask PNG") }
        return data as Data
    }

    private static func render(buffer: CVPixelBuffer, width: Int, height: Int, inverted: Bool) throws -> CGImage {
        let mask = CIImage(cvPixelBuffer: buffer)
        let scaled = mask.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / mask.extent.width,
                                                          y: CGFloat(height) / mask.extent.height))
        // Masks are coverage values, so color management must not apply a display transfer curve.
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            context.render(scaled, toBitmap: bytes.baseAddress!, rowBytes: width * 4,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8, colorSpace: nil)
        }
        var peak: UInt8 = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let coverage = pixels[index]
            peak = max(peak, coverage)
            let value = inverted ? 255 - coverage : coverage
            pixels[index] = value
            pixels[index + 1] = value
            pixels[index + 2] = value
            pixels[index + 3] = 255
        }
        guard peak >= 32 else {
            throw ColorToolError(inverted ? "No reliable foreground detected; no background mask was created"
                                 : "No person detected; no person mask was created")
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw ColorToolError("Cannot construct semantic mask image")
        }
        return image
    }
}
