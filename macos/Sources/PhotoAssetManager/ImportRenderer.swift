import CoreImage
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import KeepsAPI

enum ImportRenderer {
    static func process(_ task: KeepsWorkerTask, client: KeepsClient) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeepsImport-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent(URL(fileURLWithPath: task.filename).lastPathComponent)
        try await client.downloadWorkerSource(taskID: task.taskID, to: input)
        let rendering = Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: input)
            defer { try? handle.close() }
            var digest = SHA256()
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation()
                digest.update(data: data)
            }
            guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == task.inputHash else {
                throw NSError(domain: "KeepsImport", code: 4, userInfo: [NSLocalizedDescriptionKey: "NAS 来源校验失败"])
            }
            try render(input: input, root: root, task: task)
        }
        try await withTaskCancellationHandler { try await rendering.value } onCancel: { rendering.cancel() }
        try await client.uploadWorkerMedia(taskID: task.taskID, role: "thumbnail", source: root.appendingPathComponent("thumbnail.heic"))
        if task.generateBrowse == true {
            try await client.uploadWorkerMedia(taskID: task.taskID, role: "browse", source: root.appendingPathComponent("browse.heic"))
        }
        if task.generateStandard {
            try await client.uploadWorkerMedia(taskID: task.taskID, role: "standard", source: root.appendingPathComponent("standard.heic"))
        }
        try await client.completeWorker(taskID: task.taskID)
    }

    static func render(input: URL, root: URL, task: KeepsWorkerTask) throws {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: task.thumbnailEdge,
              ] as CFDictionary),
              let output = CGImageDestinationCreateWithURL(root.appendingPathComponent("thumbnail.heic") as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            throw NSError(domain: "KeepsImport", code: 5, userInfo: [NSLocalizedDescriptionKey: "Mac 无法解码此照片"])
        }
        CGImageDestinationAddImage(output, thumbnail, [kCGImageDestinationLossyCompressionQuality: Double(task.thumbnailQuality) / 100] as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw NSError(domain: "KeepsImportRenderer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mac 图片编码失败"]) }
        if task.generateBrowse == true {
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 64] as CFDictionary),
                  let destination = CGImageDestinationCreateWithURL(root.appendingPathComponent("browse.heic") as CFURL, UTType.heic.identifier as CFString, 1, nil) else { throw NSError(domain: "KeepsImportRenderer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mac 图片编码失败"]) }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.5] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "KeepsImportRenderer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mac 图片编码失败"]) }
        }
        if task.generateStandard {
            guard let image = CIRAWFilter(imageURL: input)?.outputImage ?? CIImage(contentsOf: input, options: [.applyOrientationProperty: true]),
                  let space = CGColorSpace(name: CGColorSpace.displayP3) else { throw NSError(domain: "KeepsImportRenderer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mac 图片编码失败"]) }
            let context = CIContext()
            guard let pixels = context.createCGImage(image, from: image.extent, format: .RGBA16, colorSpace: space),
                  let destination = CGImageDestinationCreateWithURL(root.appendingPathComponent("standard.heic") as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
                throw NSError(domain: "KeepsImportRenderer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Mac 标准图编码失败"])
            }
            let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
            var properties: [String: Any] = [kCGImagePropertyOrientation as String: 1, kCGImageDestinationLossyCompressionQuality as String: 0.9]
            let exifKeys: Set<String> = ["DateTimeOriginal", "SubsecTimeOriginal", "OffsetTimeOriginal", "DateTimeDigitized", "SubsecTimeDigitized", "OffsetTimeDigitized", "LensMake", "LensModel", "LensSpecification", "BodySerialNumber", "LensSerialNumber", "ExposureTime", "FNumber", "ISOSpeedRatings", "FocalLength", "ExposureBiasValue"]
            if let exif = original[kCGImagePropertyExifDictionary as String] as? [String: Any] {
                var values = exif.filter { exifKeys.contains($0.key) }
                values[kCGImagePropertyExifPixelXDimension as String] = pixels.width
                values[kCGImagePropertyExifPixelYDimension as String] = pixels.height
                properties[kCGImagePropertyExifDictionary as String] = values
            }
            if let tiff = original[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
                var values = tiff.filter { ["Make", "Model", "DateTime", "Artist", "Copyright", "ImageDescription"].contains($0.key) }
                values[kCGImagePropertyTIFFSoftware as String] = "Keeps"
                values[kCGImagePropertyTIFFOrientation as String] = 1
                properties[kCGImagePropertyTIFFDictionary as String] = values
            }
            properties[kCGImagePropertyGPSDictionary as String] = original[kCGImagePropertyGPSDictionary as String]
            CGImageDestinationAddImage(destination, pixels, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw NSError(domain: "KeepsImportRenderer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Mac 标准图编码失败"])
            }
        }
    }
}
