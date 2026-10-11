import Foundation
import Testing
import KeepsAPI
@testable import PhotoAssetManager

@MainActor struct RejectedTrashTests {
    private func store(_ host: String, preferences: UserDefaults) -> LibraryStore {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RejectedProtocol.self]
        let store = LibraryStore(configuration: KeepsConfiguration(baseURL: URL(string: "https://\(host)")!, libraryID: "test"),
            session: URLSession(configuration: config), loadSavedSettings: false, preferences: preferences)
        store.rejectedTrashPollInterval = .milliseconds(1)
        return store
    }

    @Test func strictConfirmationAndLostResponseUseOneTask() async {
        let preferences = UserDefaults(suiteName: UUID().uuidString)!
        let store = store("lost.invalid", preferences: preferences)
        await store.previewRejectedTrash()
        #expect(store.canConfirmRejectedTrash("2"))
        for text in ["", "02", "2 ", " 2", "2.0", "3"] { #expect(!store.canConfirmRejectedTrash(text)) }
        await store.submitRejectedTrash(confirmation: "02")
        #expect(store.rejectedTrash == nil)
        await store.submitRejectedTrash(confirmation: "2")
        #expect(store.rejectedTrashPreview?.status == "completed")
        #expect(store.rejectedTrash == nil)
        #expect(RejectedProtocol.count("lost.invalidPOST") == 1)
        #expect(RejectedProtocol.count("lost.invalidGET") == 1)
        #expect(preferences.data(forKey: "keeps.pendingRejectedTrash") == nil)
    }

    @Test func restartResubmitsOnlyConfirmedDraftIdentity() async throws {
        let preferences = UserDefaults(suiteName: UUID().uuidString)!
        let pending = PendingRejectedTrash(id: RejectedProtocol.id, count: 2, baseURL: "https://restart.invalid", libraryID: "test")
        preferences.set(try JSONEncoder().encode(pending), forKey: "keeps.pendingRejectedTrash")
        let store = store("restart.invalid", preferences: preferences)
        #expect(store.isDirectoryOperationBlocking)
        await store.rejectedTrashTracking?.value
        #expect(store.rejectedTrashPreview?.status == "completed")
        #expect(RejectedProtocol.count("restart.invalidPOST") == 1)
        #expect(RejectedProtocol.count("restart.invalidGET") == 1)
    }

    @Test func zeroCountCannotSubmit() async {
        let store = store("zero.invalid", preferences: UserDefaults(suiteName: UUID().uuidString)!)
        await store.previewRejectedTrash()
        #expect(store.rejectedTrashPreview?.count == 0)
        #expect(!store.canConfirmRejectedTrash("0"))
        await store.submitRejectedTrash(confirmation: "0")
        #expect(RejectedProtocol.count("zero.invalidPOST") == 0)
    }

    @Test func aiAndImportOperationsBlockRecyclingConfirmation() async {
        let store = store("conflicts.invalid", preferences: UserDefaults(suiteName: UUID().uuidString)!)
        await store.previewRejectedTrash()
        #expect(store.canConfirmRejectedTrash("2"))
        store.isAIEditingBlocking = true
        #expect(!store.canConfirmRejectedTrash("2"))
        store.isAIEditingBlocking = false
        store.isAISettingsBusy = true
        #expect(!store.canConfirmRejectedTrash("2"))
        store.isAISettingsBusy = false
        store.openImportWindows = [UUID()]
        #expect(!store.canConfirmRejectedTrash("2"))
        await store.submitRejectedTrash(confirmation: "2")
        #expect(RejectedProtocol.count("conflicts.invalidPOST") == 0)
    }

    @Test func changedManifestRequiresFreshConfirmation() async {
        let store = store("changed.invalid", preferences: UserDefaults(suiteName: UUID().uuidString)!)
        await store.previewRejectedTrash()
        await store.submitRejectedTrash(confirmation: "2")
        #expect(store.rejectedTrashFinished)
        #expect(store.rejectedTrashMessage?.contains("重新预览") == true)
        #expect(!store.canConfirmRejectedTrash("2"))
        #expect(RejectedProtocol.count("changed.invalidGET") == 0)
        store.closeRejectedTrash()
        #expect(!store.isDirectoryOperationBlocking)
    }

    @Test func differentConnectionNeverSubmitsOrPolls() async throws {
        let preferences = UserDefaults(suiteName: UUID().uuidString)!
        preferences.set(try JSONEncoder().encode(PendingRejectedTrash(id: RejectedProtocol.id, count: 2,
            baseURL: "https://original.invalid", libraryID: "test")), forKey: "keeps.pendingRejectedTrash")
        let store = store("different.invalid", preferences: preferences)
        #expect(store.rejectedTrashFinished)
        #expect(store.rejectedTrashTracking == nil)
        #expect(RejectedProtocol.count("different.invalidGET") == 0)
    }
}

private final class RejectedProtocol: URLProtocol, @unchecked Sendable {
    static let id = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    static func count(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[key, default: 0] }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let url = request.url!
        guard url.path.contains("rejected-trash") else {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled)); return
        }
        let preview = url.path.hasSuffix("preview")
        let method = request.httpMethod!
        let host = url.host!
        if !preview {
            #expect(url.path.hasSuffix(Self.id.uuidString.lowercased()))
            Self.lock.lock(); Self.counts[host + method, default: 0] += 1; Self.lock.unlock()
        }
        if host == "lost.invalid" && method == "POST" && !preview {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return
        }
        let draft = preview || (host == "restart.invalid" && method == "GET")
        let status = host == "changed.invalid" && !preview ? 409 : 200
        let body = """
        {"id":"\(Self.id)","count":\(host == "zero.invalid" ? 0 : 2),"status":"\(draft ? "draft" : "completed")","phase":"\(draft ? "confirmation" : "completed")","completedFiles":0,"totalFiles":3,"createdAt":1,"updatedAt":1}
        """
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
