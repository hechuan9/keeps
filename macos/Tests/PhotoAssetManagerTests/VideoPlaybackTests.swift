import Foundation
import Testing
import KeepsAPI
@testable import PhotoAssetManager

@MainActor
struct VideoPlaybackTests {
    private func version(_ hash: String, path: String, available: Bool = true, isDefault: Bool = false) throws -> KeepsAssetVersion {
        let data = try JSONSerialization.data(withJSONObject: [
            "contentHash": hash, "width": 1920, "height": 1080, "priority": 2,
            "isDefault": isDefault, "userSelected": false, "available": available,
            "paths": [["path": path, "available": available]]
        ])
        return try JSONDecoder().decode(KeepsAssetVersion.self, from: data)
    }

    @Test func selectsDefaultVideoInsteadOfPosterOrUnavailableOriginal() throws {
        let poster = try version("poster", path: "/photos/poster.jpg", isDefault: true)
        let missing = try version("missing", path: "/photos/missing.mov", available: false)
        let first = try version("first", path: "/photos/first.mp4")
        let selected = try version("selected", path: "/photos/selected.MOV", isDefault: true)
        #expect(VideoPlaybackStore.playableVersion([poster, missing, first, selected])?.contentHash == "selected")
        #expect(VideoPlaybackStore.playableVersion([poster, missing, first])?.contentHash == "first")
        #expect(VideoPlaybackStore.playableVersion([poster, missing]) == nil)
    }
}
