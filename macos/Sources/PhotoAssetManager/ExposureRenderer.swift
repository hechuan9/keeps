import CoreImage
import Foundation

struct ExposureRender: Codable, Sendable {
    let exposureEV: Double
    let width: Int
    let height: Int
    let standard: URL
    let thumbnail: URL
    let browse: URL
}

enum ExposureRenderError: Error {
    case unreadableSource(URL)
    case invalidImage
}

struct ExposureRenderer: Sendable {
    static let algorithmVersion = "median-highlight-v1"

    func render(sourceURL: URL, outputDirectory: URL) async throws -> ExposureRender {
        let work = Task.detached(priority: .userInitiated) {
            try Self.renderSynchronously(sourceURL: sourceURL, outputDirectory: outputDirectory)
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    private static func renderSynchronously(sourceURL: URL, outputDirectory: URL) throws -> ExposureRender {
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let context = CIContext(options: [.workingColorSpace: linear])
        let rawExtensions: Set<String> = ["arw", "3fr", "dng", "cr2", "cr3", "nef", "nrw", "orf", "raf", "rw2", "pef", "srw"]
        let raw: CIRAWFilter?
        let original: CIImage
        if rawExtensions.contains(sourceURL.pathExtension.lowercased()) {
            guard let filter = CIRAWFilter(imageURL: sourceURL) else { throw ExposureRenderError.unreadableSource(sourceURL) }
            raw = filter
            filter.exposure = 0
            let longestEdge = max(filter.nativeSize.width, filter.nativeSize.height)
            if longestEdge > 1024 { filter.scaleFactor = Float(1024 / longestEdge) }
            guard let image = filter.outputImage else { throw ExposureRenderError.unreadableSource(sourceURL) }
            original = image
        } else {
            raw = nil
            guard let image = CIImage(contentsOf: sourceURL, options: [.applyOrientationProperty: true]) else {
                throw ExposureRenderError.unreadableSource(sourceURL)
            }
            original = image
        }
        guard original.extent.width > 0, original.extent.height > 0, !original.extent.isInfinite else {
            throw ExposureRenderError.invalidImage
        }
        let baseline = pixels(original, context: context, colorSpace: linear)
        let luminances = stride(from: 0, to: baseline.count, by: 4).map {
            max(0, 0.2126 * baseline[$0] + 0.7152 * baseline[$0 + 1] + 0.0722 * baseline[$0 + 2])
        }.sorted()
        let median = Double(luminances[luminances.count / 2])
        var ev = min(2, max(-2, log2(0.18 / max(median, 0.000001))))
        func adjusted(_ exposure: Double) throws -> CIImage {
            if let raw {
                raw.exposure = Float(exposure)
                guard let output = raw.outputImage else { throw ExposureRenderError.invalidImage }
                return output
            }
            return original.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: exposure])
        }
        // RAW decoding can include a nonlinear tone curve, so evaluate actual candidate output.
        if ev > 0 {
            var low = 0.0
            var high = ev
            for _ in 0..<9 {
                try Task.checkCancellation()
                let candidate = (low + high) / 2
                let rendered = pixels(try adjusted(candidate), context: context, colorSpace: linear)
                var newlyClipped = 0
                for index in stride(from: 0, to: baseline.count, by: 4) {
                    let wasClipped = max(baseline[index], baseline[index + 1], baseline[index + 2]) >= 1
                    let isClipped = max(rendered[index], rendered[index + 1], rendered[index + 2]) >= 1
                    if isClipped && !wasClipped { newlyClipped += 1 }
                }
                if Double(newlyClipped) / Double(baseline.count / 4) <= 0.005 { low = candidate }
                else { high = candidate }
            }
            ev = low
        }
        try Task.checkCancellation()
        raw?.scaleFactor = 1
        let image = try adjusted(ev)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let standard = outputDirectory.appendingPathComponent("standard.heic")
        let thumbnail = outputDirectory.appendingPathComponent("thumbnail.heic")
        let browse = outputDirectory.appendingPathComponent("browse.heic")
        // Embed a known output profile; CI converts the source ICC into this color space.
        let outputSpace = CGColorSpace(name: CGColorSpace.displayP3)!
        try write(image, to: standard, context: context, colorSpace: outputSpace)
        try write(resize(image, longestEdge: 512), to: thumbnail, context: context, colorSpace: outputSpace)
        try write(resize(image, longestEdge: 64), to: browse, context: context, colorSpace: outputSpace)
        return ExposureRender(exposureEV: ev, width: Int(image.extent.width), height: Int(image.extent.height),
                              standard: standard, thumbnail: thumbnail, browse: browse)
    }

    private static func resize(_ image: CIImage, longestEdge: CGFloat) -> CIImage {
        let scale = min(1, longestEdge / max(image.extent.width, image.extent.height))
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    private static func pixels(_ image: CIImage, context: CIContext, colorSpace: CGColorSpace) -> [Float] {
        let reduced = resize(image, longestEdge: 1024)
        let bounds = reduced.extent.integral
        let width = Int(bounds.width)
        let height = Int(bounds.height)
        var result = [Float](repeating: 0, count: width * height * 4)
        result.withUnsafeMutableBytes { buffer in
            context.render(reduced, toBitmap: buffer.baseAddress!, rowBytes: width * 16,
                           bounds: bounds, format: .RGBAf, colorSpace: colorSpace)
        }
        return result
    }

    private static func write(_ image: CIImage, to url: URL, context: CIContext, colorSpace: CGColorSpace) throws {
        try Task.checkCancellation()
        try context.writeHEIF10Representation(of: image, to: url, colorSpace: colorSpace, options: [:])
    }
}
