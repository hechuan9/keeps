import Foundation
import Testing
import KeepsAPI
@testable import KeepsIOSState

@MainActor
struct IOSDirectoryStoreTests {
    @Test func directoryBrowsingReadsPersistentDatabaseAndOnlyExplicitRefreshSynchronizes() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = KeepsConfiguration(baseURL: URL(string: "https://example.invalid")!, libraryID: "test")
        let db = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: root)
        let navigation = try JSONDecoder().decode(KeepsNavigation.self, from: Data(#"{"directories":[{"path":"/photos","name":"photos","photoCount":10,"hasChildren":false}]}"#.utf8))
        try db.saveNavigation(navigation)
        let store = IOSDirectoryStore()
        store.configure(configuration, rootDirectory: root)
        var syncs = 0
        store.synchronize = { syncs += 1 }
        #expect(store.state(for: nil, configuration: configuration).loading)
        #expect(store.state(for: nil, configuration: configuration).directories == nil)
        await store.load(configuration: configuration, path: nil)
        #expect(store.state(for: nil, configuration: configuration).directories?.first?.path == "/photos")
        #expect(!store.state(for: nil, configuration: configuration).loading)
        #expect(syncs == 0)
        await store.load(configuration: configuration, path: nil, force: true)
        #expect(syncs == 1)
        store.configure(nil)
        #expect(store.state(for: nil, configuration: nil).directories == nil)
    }

    @Test func configurationSwitchDiscardsAnInFlightRefresh() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = KeepsConfiguration(baseURL: URL(string: "https://example.invalid")!, libraryID: "first")
        let second = KeepsConfiguration(baseURL: URL(string: "https://example.invalid")!, libraryID: "second")
        let db = try KeepsLibraryDatabase(configuration: first, rootDirectory: root)
        let navigation = try JSONDecoder().decode(KeepsNavigation.self, from: Data(#"{"directories":[{"path":"/old","name":"old","photoCount":1,"hasChildren":false}]}"#.utf8))
        try db.saveNavigation(navigation)
        let store = IOSDirectoryStore()
        store.configure(first, rootDirectory: root)
        store.synchronize = { store.configure(second, rootDirectory: root) }
        await store.load(configuration: first, path: nil, force: true)
        #expect(store.state(for: nil, configuration: second).directories == nil)
        #expect(store.state(for: nil, configuration: second).loading)
        await store.load(configuration: second, path: nil)
        #expect(store.state(for: nil, configuration: second).directories == nil)
        #expect(!store.state(for: nil, configuration: second).loading)
        #expect(store.state(for: nil, configuration: second).error == nil)
    }


    @Test func configurationDoesNotOpenDatabaseUntilAsynchronousLoad() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not a directory".utf8).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = KeepsConfiguration(baseURL: URL(string: "https://example.invalid")!, libraryID: "test")
        let store = IOSDirectoryStore()
        store.configure(configuration, rootDirectory: root)
        #expect(store.state(for: nil, configuration: configuration).loading)
        #expect(store.state(for: nil, configuration: configuration).error == nil)
        await store.load(configuration: configuration, path: nil)
        #expect(!store.state(for: nil, configuration: configuration).loading)
        #expect(store.state(for: nil, configuration: configuration).error != nil)
    }

}
