import CoreImage
import CryptoKit
import Foundation
import ImageIO

struct AIEditingImageInfo: Sendable {
    let hash: String
    let size: Int64
    let width: Int
    let height: Int
}

enum AIEditingImages {
    static func comparisonPreview(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 2560
              ] as CFDictionary) else {
            throw AIEditingFailure("无法读取调色预览：\(url.lastPathComponent)")
        }
        return image
    }

    static func inspect(_ url: URL, image: Bool) async throws -> AIEditingImageInfo {
        let task = Task.detached(priority: .utility) {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var hash = SHA256(), size: Int64 = 0
            while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty {
                try Task.checkCancellation()
                hash.update(data: data); size += Int64(data.count)
            }
            var width = 0, height = 0
            if image {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let w = properties[kCGImagePropertyPixelWidth] as? Int,
                      let h = properties[kCGImagePropertyPixelHeight] as? Int else { throw AIEditingFailure("无法读取调色输出。") }
                width = w; height = h
            }
            return AIEditingImageInfo(hash: hash.finalize().map { String(format: "%02x", $0) }.joined(), size: size, width: width, height: height)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    static func derivatives(from source: URL, directory: URL, quarterTurns: Int = 0, crop: CGRect? = nil) async throws -> [String: URL] {
        let task = Task.detached(priority: .utility) {
            guard let original = CIImage(contentsOf: source, options: [.applyOrientationProperty: true]),
                  original.extent.width > 0, original.extent.height > 0, !original.extent.isInfinite,
                  let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { throw AIEditingFailure("无法生成调色展示图。") }
            let image = try GeometryRenderer.geometry(original, quarterTurns: quarterTurns, crop: crop)
            let context = CIContext()
            var outputs: [String: URL] = [:]
            for (role, limit) in [("standard", 0.0), ("thumbnail", 512.0), ("browse", 64.0)] {
                try Task.checkCancellation()
                let scale = limit == 0 ? 1 : min(1, limit / max(image.extent.width, image.extent.height))
                let normalized = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
                let scaled = normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                // HEVC pads odd dimensions; an explicit even canvas keeps ImageIO's display
                // dimensions equal to the encoded dimensions validated by the NAS.
                let maximum = limit == 0 ? Int.max : Int(limit)
                let width = min(maximum, max(2, Int((scaled.extent.width / 2).rounded(.up)) * 2))
                let height = min(maximum, max(2, Int((scaled.extent.height / 2).rounded(.up)) * 2))
                let resized = scaled.clampedToExtent().cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
                let url = directory.appendingPathComponent(role + ".heic")
                let pending = directory.appendingPathComponent(UUID().uuidString + ".heic")
                defer { try? FileManager.default.removeItem(at: pending) }
                try context.writeHEIFRepresentation(of: resized, to: pending, format: .RGBA8, colorSpace: colorSpace, options: [:])
                try Data(contentsOf: pending, options: .mappedIfSafe).write(to: url, options: .atomic)
                outputs[role] = url
            }
            return outputs
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
