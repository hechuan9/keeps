import Foundation
import Testing
import KeepsAPI
@testable import KeepsIOSState

@MainActor struct IOSTrashCleanupTests {
    @Test func offlinePreviewNeverAllowsCleanup() async {
        let configuration = KeepsConfiguration(baseURL: URL(string: "https://offline-trash.invalid")!, libraryID: UUID().uuidString)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [OfflineTrashProtocol.self]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = IOSLibraryStore(configuration: configuration, session: URLSession(configuration: sessionConfiguration), loadSettings: false, databaseDirectory: root)
        await store.previewTrashCleanup()
        #expect(store.trashCleanup == nil)
        #expect(store.trashCleanupError != nil)
        #expect(!store.canConfirmTrashCleanup("1"))
        store.submitTrashCleanup("1")
        #expect(!store.hasPendingTrashCleanup)
        store.configure(nil)
        try? FileManager.default.removeItem(at: root)
    }
}

private final class OfflineTrashProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path.hasSuffix("/trash/preview") == true)
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
}
