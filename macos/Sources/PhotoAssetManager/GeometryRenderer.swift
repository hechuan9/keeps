import CoreImage
import Foundation
import ImageIO

struct GeometryRender: Codable, Sendable {
    let width: Int
    let height: Int
    let standard: URL
    let thumbnail: URL
    let browse: URL
}

struct GeometryRenderer: Sendable {
    func render(sourceURL: URL, outputDirectory: URL, quarterTurns: Int, crop: CGRect?) async throws -> GeometryRender {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let files = try await AIEditingImages.derivatives(from: sourceURL, directory: outputDirectory,
                                                        quarterTurns: quarterTurns, crop: crop)
        let info = try await AIEditingImages.inspect(files["standard"]!, image: true)
        return GeometryRender(width: info.width, height: info.height, standard: files["standard"]!,
                              thumbnail: files["thumbnail"]!, browse: files["browse"]!)
    }

    static func geometry(_ image: CIImage, quarterTurns: Int, crop: CGRect?) throws -> CIImage {
        let orientation: CGImagePropertyOrientation = switch ((quarterTurns % 4) + 4) % 4 {
        case 1: .right
        case 2: .down
        case 3: .left
        default: .up
        }
        var result = image.oriented(orientation)
        result = result.transformed(by: CGAffineTransform(translationX: -result.extent.minX, y: -result.extent.minY))
        if let crop {
            guard [crop.origin.x, crop.origin.y, crop.width, crop.height].allSatisfy({ $0.isFinite }),
                  crop.minX >= 0, crop.minY >= 0, crop.width > 0, crop.height > 0,
                  crop.maxX <= 1, crop.maxY <= 1 else { throw AIEditingFailure("裁剪范围必须位于照片内。") }
            let bounds = result.extent
            let rect = CGRect(x: crop.minX * bounds.width, y: crop.minY * bounds.height,
                              width: crop.width * bounds.width, height: crop.height * bounds.height)
                .integral.intersection(bounds)
            guard rect.width >= 1, rect.height >= 1 else { throw AIEditingFailure("裁剪范围过小。") }
            result = result.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        }
        return result
    }
}
