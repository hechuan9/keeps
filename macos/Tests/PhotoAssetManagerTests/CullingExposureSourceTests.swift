import Foundation
import Testing
import KeepsAPI
@testable import PhotoAssetManager

@MainActor
struct CullingExposureSourceTests {
    @Test func selectsHasselbladRAWWithoutNegativeFlag() throws {
        let raw = try version("capture.3FR", priority: 1, isNegative: false)

        let selected = try CullingExposureView.exposureSource(in: [raw])

        #expect(selected.id == raw.id)
    }

    @Test(arguments: ["heif", "HEIC", "hif"])
    func prefersCameraHEIFOverHasselbladRAW(extensionName: String) throws {
        let heif = try version("capture." + extensionName, priority: 2, isNegative: false)
        let raw = try version("capture.3FR", priority: 1, isNegative: true)

        let selected = try CullingExposureView.exposureSource(in: [raw, heif])

        #expect(selected.id == heif.id)
    }

    @Test func ignoresGeneratedHEIFAndUsesHasselbladRAW() throws {
        let generated = try version("edited.heif", priority: 1, generatedFrom: "capture.3FR")
        let raw = try version("capture.3FR", priority: 1)

        #expect(try CullingExposureView.exposureSource(in: [generated, raw]).id == raw.id)
        #expect(throws: AIEditingFailure.self) {
            try CullingExposureView.exposureSource(in: [generated])
        }
    }

    @Test func fallsBackToHasselbladRAWWhenHEIFIsUnavailable() throws {
        let missing = try version("capture.heif", priority: 2, available: false)
        let offline = try version("capture.heic", priority: 2, pathAvailable: false)
        let raw = try version("capture.3FR", priority: 1)

        #expect(try CullingExposureView.exposureSource(in: [missing, offline, raw]).id == raw.id)
    }

    @Test func skipsUnavailableRAWVersionsAndPaths() throws {
        let missingVersion = try version("missing.3FR", priority: 1, available: false)
        let missingPath = try version("offline.3FR", priority: 1, pathAvailable: false)
        let original = try version("capture.heif", priority: 2, isNegative: true)

        let selected = try CullingExposureView.exposureSource(in: [missingVersion, missingPath, original])

        #expect(selected.id == original.id)
        #expect(throws: AIEditingFailure.self) {
            try CullingExposureView.exposureSource(in: [missingVersion, missingPath])
        }
    }

    @Test func preservesSelectedOriginalForOtherCameras() throws {
        let raw = try version("capture.arw", priority: 1)
        let selected = try version("capture.jpeg", priority: 2, isNegative: true)

        #expect(try CullingExposureView.exposureSource(in: [raw, selected]).id == selected.id)
    }

    @Test func doesNotTreatPriorityOneHEIFAsRAW() throws {
        let heif = try version("capture.heif", priority: 1)
        let raw = try version("capture.arw", priority: 1)

        #expect(try CullingExposureView.exposureSource(in: [heif, raw]).id == raw.id)
    }

    @Test func rejectsEditedOutputsAsExposureSources() throws {
        let edited = try version("edited.tiff", priority: 3, isNegative: false)

        #expect(throws: AIEditingFailure.self) {
            try CullingExposureView.exposureSource(in: [edited])
        }
    }

    private func version(_ filename: String, priority: Int, isNegative: Bool = false,
                         available: Bool = true, pathAvailable: Bool = true,
                         generatedFrom: String? = nil) throws -> KeepsAssetVersion {
        let data = try JSONSerialization.data(withJSONObject: [
            "contentHash": filename, "width": 4000, "height": 3000, "priority": priority,
            "isDefault": false, "userSelected": false, "isNegative": isNegative,
            "available": available, "evidence": generatedFrom.map { ["generatedFrom": $0] } ?? [:],
            "paths": [["path": "/synthetic/" + filename, "available": pathAvailable]]
        ])
        return try JSONDecoder().decode(KeepsAssetVersion.self, from: data)
    }
}
