import Foundation
import AppKit
import Testing
import KeepsAPI
@testable import PhotoAssetManager

@MainActor struct PhotoDragPayloadTests {
    @Test func doubleClickOpensPhotoWithoutRepeatingSelection() throws {
        let view = PhotoDragSource.SourceView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        var selections = 0
        var opens = 0
        view.select = { _ in selections += 1 }
        view.open = { opens += 1 }
        for count in 1...2 {
            let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
                location: NSPoint(x: 50, y: 50), modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: count, clickCount: count, pressure: 1))
            let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp,
                location: NSPoint(x: 50, y: 50), modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: count, clickCount: count, pressure: 0))
            view.mouseDown(with: down)
            view.mouseUp(with: up)
            view.mouseUp(with: up)
        }
        #expect(selections == 1)
        #expect(opens == 1)
    }

    @Test func photoDragTypeIsDeclaredAsDataForAppKitBridge() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Sources/PhotoAssetManager/Resources/Info.plist"))
        let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let declarations = plist["UTExportedTypeDeclarations"] as? [[String: Any]] ?? []
        let declaration = try #require(declarations.first { $0["UTTypeIdentifier"] as? String == PhotoDragPayload.pasteboardType })
        #expect((declaration["UTTypeConformsTo"] as? [String] ?? []).contains("public.data"))
    }

    @Test func draggingSelectedAssetIncludesGroupAndUnselectedAssetIncludesOnlyItself() async throws {
        let store = try await loadedStore()
        let ids = store.assets.map(\.id)
        store.select(ids[0])
        store.select(ids[2], extending: true)
        let selectedPayload = try #require(store.photoDragPayload(for: ids[0]))
        #expect(Set(selectedPayload.assetIDs) == [ids[0], ids[2]])
        let otherPayload = try #require(store.photoDragPayload(for: ids[1]))
        #expect(otherPayload.assetIDs == [ids[1]])
        #expect(store.canMovePhotos(selectedPayload, to: "/target"))
        #expect(!store.canMovePhotos(selectedPayload, to: "/source"))
        #expect(store.photoDragItem(for: ids[0])?.types.contains(.init(PhotoDragPayload.pasteboardType)) == true)
    }

    @Test func staleDirectoryQueryAndConnectionPayloadsAreRejected() async throws {
        let store = try await loadedStore()
        let payload = try #require(store.photoDragPayload(for: store.assets[0].id))
        let roundTrip = try JSONDecoder().decode(PhotoDragPayload.self, from: JSONEncoder().encode(payload))
        #expect(store.canMovePhotos(roundTrip, to: "/target"))
        store.query.directory = "/other"
        #expect(!store.canMovePhotos(payload, to: "/target"))
        store.query = payload.query
        store.query.minRating = 3
        #expect(!store.canMovePhotos(payload, to: "/target"))
        store.query = payload.query
        let staleConnection = PhotoDragPayload(assetIDs: payload.assetIDs, sourcePath: payload.sourcePath,
            baseURL: "https://other.invalid", libraryID: payload.libraryID, query: payload.query)
        #expect(!store.canMovePhotos(staleConnection, to: "/target"))
        let staleLibrary = PhotoDragPayload(assetIDs: payload.assetIDs, sourcePath: payload.sourcePath,
            baseURL: payload.baseURL, libraryID: "other", query: payload.query)
        #expect(!store.canMovePhotos(staleLibrary, to: "/target"))
    }

    @Test func selectAllPaginationBlocksDraggingUntilSelectionFinishes() async throws {
        let store = try await loadedStore(paginated: true)
        let id = store.assets[0].id
        let payload = try #require(store.photoDragPayload(for: id))
        store.selectAll()
        #expect(store.isSelectingAll)
        #expect(store.photoDragPayload(for: id) == nil)
        #expect(!store.canMovePhotos(payload, to: "/target"))
        try await waitUntil { !store.isLoading }
        #expect(store.photoDragPayload(for: id)?.assetIDs.count == 5)
        store.query.directory = nil
        store.refresh()
        try await waitUntil { !store.isLoading }
        let allPhotos = try #require(store.photoDragPayload(for: id))
        #expect(allPhotos.sourcePath == nil)
        #expect(store.canMovePhotos(allPhotos, to: "/target"))
    }

    @Test func startingDragSelectsUnselectedPhotoAndPreservesSelectedGroup() async throws {
        let store = try await loadedStore()
        let ids = store.assets.map(\.id)
        store.query.directory = nil
        store.refresh()
        try await waitUntil { !store.isLoading }
        _ = store.photoDragItem(for: ids[0])
        #expect(store.selectedIDs == [ids[0]])
        store.select(ids[1], extending: true)
        _ = store.photoDragItem(for: ids[0])
        #expect(store.selectedIDs == [ids[0], ids[1]])
        _ = store.photoDragItem(for: ids[2])
        #expect(store.selectedIDs == [ids[2]])
        #expect(store.photoDragItem(for: ids[2])?.types.contains(.init(PhotoDragPayload.pasteboardType)) == true)
        #expect(!store.isOperationBlocking)
    }

    @Test func backgroundRefreshKeepsSelectedPhotosDraggable() async throws {
        let store = try await loadedStore()
        let ids = store.assets.map(\.id)
        store.select(ids[0])
        store.select(ids[1], extending: true)
        store.refresh()
        #expect(store.isLoading)
        #expect(store.isCheckingRevision)
        let item = try #require(store.photoDragItem(for: ids[0]))
        let data = try #require(item.data(forType: .init(PhotoDragPayload.pasteboardType)))
        let payload = try JSONDecoder().decode(PhotoDragPayload.self, from: data)
        #expect(Set(payload.assetIDs) == [ids[0], ids[1]])
        #expect(store.canMovePhotos(payload, to: "/target"))
        try await waitUntil { !store.isLoading }
    }

    private func loadedStore(paginated: Bool = false) async throws -> LibraryStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PhotoDragProtocol.self]
        let store = LibraryStore(configuration: KeepsConfiguration(baseURL: URL(string: paginated ? "https://pages.invalid" : "https://all.invalid")!, libraryID: "selection"), session: URLSession(configuration: configuration), loadSavedSettings: false, preferences: UserDefaults(suiteName: UUID().uuidString)!, persistConfiguration: { _ in })
        store.query.directory = "/source"
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

private final class PhotoDragProtocol: URLProtocol, @unchecked Sendable {
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
