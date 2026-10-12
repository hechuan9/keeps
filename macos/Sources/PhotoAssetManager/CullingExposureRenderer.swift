import CoreImage
import Foundation

/// Screening previews stay in memory and never enter the photo's edit history.
actor CullingExposureRenderer {
    private let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .cacheIntermediates: false,
    ])
    private var cachedURL: URL?
    private var cachedImage: CIImage?
    private var automaticEV = 0.0
    private var automaticGamma = 1.0

    func render(sourceURL: URL, automatic: Bool, exposureEV: Double) throws -> CGImage {
        try Task.checkCancellation()
        guard exposureEV.isFinite else { throw ExposureRenderError.invalidImage }
        if cachedURL != sourceURL || cachedImage == nil {
            cachedURL = nil
            cachedImage = nil
            let image = try decode(sourceURL)
            try measure(image)
            cachedImage = image
            cachedURL = sourceURL
        }
        guard var image = cachedImage else { throw ExposureRenderError.invalidImage }
        if automatic {
            image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: automaticEV])
                .applyingFilter("CIGammaAdjust", parameters: ["inputPower": automaticGamma])
        }
        image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: min(4, max(-4, exposureEV))])
        try Task.checkCancellation()
        guard let result = context.createCGImage(image, from: image.extent, format: .RGBA8,
                                                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else {
            throw ExposureRenderError.invalidImage
        }
        try Task.checkCancellation()
        return result
    }

    private func decode(_ url: URL) throws -> CIImage {
        let rawExtensions: Set<String> = ["arw", "3fr", "dng", "cr2", "cr3", "nef", "nrw", "orf", "raf", "rw2", "pef", "srw"]
        let source: CIImage
        if rawExtensions.contains(url.pathExtension.lowercased()) {
            guard let raw = CIRAWFilter(imageURL: url) else { throw ExposureRenderError.unreadableSource(url) }
            // Remove the decoder's display contrast so shadow inspection starts from linear sensor data.
            raw.exposure = 0
            raw.baselineExposure = 0
            raw.boostAmount = 0
            raw.shadowBias = 0
            if raw.isLocalToneMapSupported { raw.localToneMapAmount = 0 }
            raw.scaleFactor = Float(min(1, 1600 / max(raw.nativeSize.width, raw.nativeSize.height)))
            guard let image = raw.outputImage else { throw ExposureRenderError.unreadableSource(url) }
            source = image
        } else {
            guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
                throw ExposureRenderError.unreadableSource(url)
            }
            source = image
        }
        guard !source.extent.isInfinite, !source.extent.isNull,
              source.extent.width > 0, source.extent.height > 0 else { throw ExposureRenderError.invalidImage }
        let scale = min(1, 1600 / max(source.extent.width, source.extent.height))
        let image = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let width = max(1, Int(image.extent.width)), height = max(1, Int(image.extent.height))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        var bytes = Data(count: width * height * 16)
        try Task.checkCancellation()
        bytes.withUnsafeMutableBytes {
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: width * 16,
                           bounds: bounds, format: .RGBAf, colorSpace: linear)
        }
        try Task.checkCancellation()
        // CIImage graphs are lazy; a float bitmap prevents each slider event from decoding RAW again.
        return CIImage(bitmapData: bytes, bytesPerRow: width * 16, size: bounds.size,
                       format: .RGBAf, colorSpace: linear)
    }

    private func measure(_ image: CIImage) throws {
        let scale = min(1, 128 / max(image.extent.width, image.extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let width = max(1, Int(small.extent.width)), height = max(1, Int(small.extent.height))
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes {
            context.render(small, toBitmap: $0.baseAddress!, rowBytes: width * 16,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAf, colorSpace: linear)
        }
        let values = stride(from: 0, to: pixels.count, by: 4).compactMap { index -> Double? in
            guard pixels[index + 3] > 0 else { return nil }
            let value = Double(0.2126 * pixels[index] + 0.7152 * pixels[index + 1] + 0.0722 * pixels[index + 2])
            return value.isFinite ? max(0, value) : nil
        }.sorted()
        try Task.checkCancellation()
        automaticEV = 0
        automaticGamma = 1
        guard !values.isEmpty else { return }
        let white = values[Int(Double(values.count - 1) * 0.995)]
        guard white > 0.000001 else { return }
        // Robust white placement and a monotonic power curve reveal shadows without sharpening or inventing detail.
        automaticEV = min(8, max(-8, log2(0.8 / white)))
        let median = values[values.count / 2] * pow(2, automaticEV)
        if median > 0.000001 && median < 0.25 {
            automaticGamma = min(1, max(0.25, log(0.25) / log(median)))
        }
    }
}
