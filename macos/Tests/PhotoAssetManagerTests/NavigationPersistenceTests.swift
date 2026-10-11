import Foundation
import Testing
import KeepsAPI
@testable import PhotoAssetManager

@MainActor struct NavigationPersistenceTests {
    @Test func remembersLocationAndExpansionAcrossRestartAndReset() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let config = KeepsConfiguration(baseURL: URL(string: "http://localhost:2283")!, libraryID: "photos")
        let original = LibraryStore(configuration: config, loadSavedSettings: false, preferences: defaults)
        original.showLibrary(directory: "/photos/travel")
        original.setDirectoryExpanded("/photos", expanded: true)
        original.setDirectoryExpanded("/photos/travel", expanded: true)
        original.resetNavigation()
        let restored = LibraryStore(configuration: config, loadSavedSettings: false, preferences: defaults)
        #expect(restored.query.directory == "/photos/travel")
        #expect(restored.expandedPaths == ["/photos", "/photos/travel"])
        restored.setDirectoryExpanded("/photos/travel", expanded: false)
        restored.showLibrary(picked: true)
        let again = LibraryStore(configuration: config, loadSavedSettings: false, preferences: defaults)
        #expect(again.query.directory == nil)
        #expect(again.query.flagState == "picked")
        #expect(again.expandedPaths == ["/photos"])
    }

    @Test func isolatesLibrariesAndServersAndPersistsMovedPaths() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let config = KeepsConfiguration(baseURL: URL(string: "http://localhost:2283")!, libraryID: "photos")
        let original = LibraryStore(configuration: config, loadSavedSettings: false, preferences: defaults)
        original.showLibrary(directory: "/photos/old/child")
        original.setDirectoryExpanded("/photos/old", expanded: true)
        original.completeDirectoryMove(path: "/photos/old", parentPath: "/photos/new", destination: "/photos/new/old")
        let restored = LibraryStore(configuration: config, loadSavedSettings: false, preferences: defaults)
        #expect(restored.query.directory == "/photos/new/old/child")
        #expect(restored.expandedPaths.contains("/photos/new/old"))
        for other in [KeepsConfiguration(baseURL: config.baseURL, libraryID: "other"), KeepsConfiguration(baseURL: URL(string: "http://other:2283")!, libraryID: "photos")] {
            let separate = LibraryStore(configuration: other, loadSavedSettings: false, preferences: defaults)
            #expect(separate.query.directory == nil)
            #expect(separate.expandedPaths.isEmpty)
        }
    }
}
