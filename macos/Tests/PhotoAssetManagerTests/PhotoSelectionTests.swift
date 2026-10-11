import Foundation
import Testing
import KeepsAPI
@testable import PhotoAssetManager

@MainActor struct PhotoSelectionTests {
    @Test func rangeSelectionKeepsAnchorAndKeyboardFocus() async throws {
        let store = try await loadedStore()
        let ids = store.assets.map(\.id)
        store.select(ids[1])
        store.select(ids[4], range: true)
        #expect(store.selectedIDs == Set(ids[1...4]))
        store.selectAdjacent(-1, extending: true)
        #expect(store.selectedIDs == Set(ids[1...3]))
        store.selectAdjacent(-1, extending: true)
        #expect(store.selectedIDs == Set(ids[1...2]))
        store.select(ids[0], extending: true)
        #expect(store.selectedIDs == Set(ids[0...2]))
        store.select(ids[0], extending: true)
        #expect(store.selectedIDs == Set(ids[1...2]))
        store.select(ids[4], extending: true, range: true)
        #expect(store.selectedIDs == Set(ids))
        store.deselectAll()
        store.selectAdjacent(1)
        #expect(store.selectedIDs == [ids[0]])
    }

    @Test func selectAllIncludesUnloadedPages() async throws {
        let store = try await loadedStore(paginated: true)
        #expect(store.assets.count == 2)
        store.selectAll()
        try await waitUntil { !store.isLoading }
        #expect(store.lastError == nil)
        #expect(store.selectedIDs.count == 5)
        #expect(!store.isSelectingAll)
    }

    @Test func deselectDuringPaginationDoesNotReselectLaterPage() async throws {
        let store = try await loadedStore(paginated: true)
        store.selectAll()
        store.deselectAll()
        try await waitUntil { !store.isLoading }
        #expect(store.assets.count == 5)
        #expect(store.selectedIDs.isEmpty)
    }

    @Test func changingDirectoryCancelsPendingSelectAll() async throws {
        let store = try await loadedStore(paginated: true)
        store.selectAll()
        store.showLibrary(directory: "/other")
        try await waitUntil { !store.isLoading }
        #expect(store.query.directory == "/other")
        #expect(store.selectedIDs.isEmpty)
        #expect(!store.isSelectingAll)
    }

    @Test func changingConnectionClearsSelectionAndPendingSelectAll() async throws {
        let store = try await loadedStore(paginated: true)
        store.selectAll()
        let connected = await store.checkConnection(baseURL: "https://all.invalid", libraryID: "new", accessCredential: "", save: true)
        #expect(connected)
        try await waitUntil { !store.isLoading }
        #expect(store.configuration?.libraryID == "new")
        #expect(store.selectedIDs.isEmpty)
        #expect(!store.isSelectingAll)
    }

    @Test(arguments: [false, true]) func aiActivityBlocksSelectionNavigationAndMutations(settingsTest: Bool) async throws {
        let store = try await loadedStore()
        let originalID = store.assets[0].id
        store.select(originalID)
        store.isAIEditingBlocking = !settingsTest
        store.isAISettingsBusy = settingsTest
        store.pauseLibraryForDirectoryOperation()

        store.select(store.assets[1].id)
        store.selectAdjacent(1)
        store.selectAll()
        store.deselectAll()
        store.showLibrary(directory: "/other")
        store.updateSelected(KeepsAssetPatch(rating: 5))
        store.refresh(force: true)
        let connected = await store.checkConnection(baseURL: "https://all.invalid", libraryID: "new", accessCredential: "", save: true)

        #expect(store.selectedIDs == [originalID])
        #expect(store.query.directory == nil)
        #expect(!store.isMutating)
        #expect(!store.isLoading)
        #expect(!connected)
        #expect(store.configuration?.libraryID == "selection")
        store.isAIEditingBlocking = false
        store.isAISettingsBusy = false
        store.select(store.assets[1].id)
        #expect(store.selectedIDs == [store.assets[1].id])
    }

    @Test func finishingSettingsWorkDoesNotUnlockPhotoBatch() {
        let store = LibraryStore(loadSavedSettings: false, preferences: UserDefaults(suiteName: UUID().uuidString)!)
        store.isAIEditingBlocking = true
        store.isAISettingsBusy = true
        store.isAISettingsBusy = false
        #expect(store.isOperationBlocking)
        #expect(!store.isDirectoryOperationBlocking)
    }

    private func loadedStore(paginated: Bool = false) async throws -> LibraryStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SelectionProtocol.self]
        let store = LibraryStore(configuration: KeepsConfiguration(baseURL: URL(string: paginated ? "https://pages.invalid" : "https://all.invalid")!, libraryID: "selection"), session: URLSession(configuration: configuration), loadSavedSettings: false, preferences: UserDefaults(suiteName: UUID().uuidString)!, persistConfiguration: { _ in })
        store.refresh()
        try await waitUntil { !store.isLoading }
        try #require(store.lastError == nil)
        return store
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("selection request did not complete")
    }
}

private final class SelectionProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let body: String
        if url.path.hasSuffix("/assets") {
            let paginated = url.host == "pages.invalid"
            let cursor = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "cursor" } == true
            let numbers = paginated ? (cursor ? Array(3...5) : Array(1...2)) : Array(1...5)
            let items = numbers.map { number in
                """
                {"id":"00000000-0000-0000-0000-00000000000\(number)","cameraMake":"","cameraModel":"","lensModel":"","originalFilename":"photo.jpg","contentFingerprint":"hash","metadataFingerprint":"meta","rating":0,"flagState":"unflagged","tags":[],"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","trashed":false}
                """
            }.joined(separator: ",")
            body = "{\"items\":[\(items)],\"total\":5,\"revision\":1,\"isUpdating\":false" + (paginated && !cursor ? ",\"nextCursor\":\"next\"}" : "}")
        } else if url.path.hasSuffix("/revision") { body = "{\"revision\":1,\"isUpdating\":false}" }
        else { body = "{\"all\":5,\"picked\":0,\"trashed\":0}" }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
