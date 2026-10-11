import Foundation
import CoreML
import CoreVideo
import Vision

public enum SkySegmentation {
    public static var isAvailable: Bool { FileManager.default.fileExists(atPath: modelURL.path) }

    private static var modelURL: URL {
        if let configured = ProcessInfo.processInfo.environment["KEEPS_SKY_MODEL"], !configured.isEmpty {
            return URL(fileURLWithPath: configured)
        }
        return URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/AIEditing/SkySegSmall.mlmodelc")
    }

    static func mask(image: CGImage) throws -> CVPixelBuffer {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw ColorToolError("Sky segmentation model is missing: \(modelURL.path)")
        }
        let model = try VNCoreMLModel(for: MLModel(contentsOf: modelURL))
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        guard let result = request.results?.first as? VNPixelBufferObservation else {
            throw ColorToolError("Sky segmentation did not return a coverage image")
        }
        let output = result.pixelBuffer
        guard CVPixelBufferGetWidth(output) == 384, CVPixelBufferGetHeight(output) == 384,
              CVPixelBufferGetPixelFormatType(output) == kCVPixelFormatType_OneComponent16Half else {
            throw ColorToolError("Sky segmentation returned an unexpected mask format")
        }
        CVPixelBufferLockBaseAddress(output, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(output) else { throw ColorToolError("Cannot access sky mask") }
        let rowBytes = CVPixelBufferGetBytesPerRow(output)
        var peak: Float = 0
        for y in 0..<384 {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt16.self)
            for x in 0..<384 {
                let coverage = Float(Float16(bitPattern: row[x]))
                guard coverage.isFinite, coverage >= 0, coverage <= 1 else {
                    throw ColorToolError("Sky segmentation returned invalid coverage")
                }
                peak = max(peak, coverage)
            }
        }
        guard peak >= 0.5 else { throw ColorToolError("No sky detected; no sky mask was created") }
        return output
    }

}
