import Foundation
import Testing
@testable import PhotoAssetManager

@MainActor struct AIEditingUsageTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private let event = "{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":1000,\"cached_input_tokens\":600,\"cache_write_input_tokens\":100,\"output_tokens\":200,\"reasoning_output_tokens\":50}}"

    @Test func recordsFailedAttemptsAndReplaysWithoutDoubleCounting() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AIEditingUsageStore(root: root)
        let id = try store.begin(model: "gpt-6-luna", account: "test@example.com", job: root)
        try store.consume(event, attemptID: id, eventIndex: 12)
        try store.consume(event, attemptID: id, eventIndex: 12)
        try store.consume(event, attemptID: id, eventIndex: 24)
        try store.finish(attemptID: id, success: false)
        let restored = AIEditingUsageStore(root: root)
        #expect(restored.attempts[0].usage?.input == 2000)
        #expect(restored.attempts[0].usage?.ordinaryInput == 600)
        #expect(restored.attempts[0].usage?.output == 400)
        #expect(restored.attempts[0].success == false)
        #expect(abs((restored.attempts[0].estimatedUSD ?? 0) - 0.000297) < 0.000000001)
        #expect(restored.days[0].tokens == 2400)
    }

    @Test func missingUsageIsUnknownAndUnpricedModelDoesNotUseLunaPrice() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AIEditingUsageStore(root: root)
        let first = try store.begin(model: "unknown-model", account: nil, job: root)
        try store.finish(attemptID: first, success: false)
        #expect(store.days[0].unknown == 1)
        let second = try store.begin(model: "unknown-model", account: nil, job: root)
        try store.consume(event, attemptID: second, eventIndex: 0)
        #expect(store.days[0].unpriced == 1)
        #expect(store.days[0].estimatedUSD == 0)
    }

    @Test func corruptLedgerIsNotOverwritten() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("usage.json")
        let original = Data("invalid".utf8)
        try original.write(to: file)
        let store = AIEditingUsageStore(root: root)
        #expect(throws: (any Error).self) { try store.begin(model: "gpt-6-luna", account: nil, job: root) }
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func interruptionReplaysDurableEventsOnce() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AIEditingUsageStore(root: root)
        let id = try store.begin(model: "gpt-6-luna", account: nil, job: root)
        try store.consume("CLI diagnostic text", attemptID: id, eventIndex: 0)
        try store.consume(event, attemptID: id, eventIndex: 1)
        let log = "CLI diagnostic text\n" + event + "\n" + event + "\n"
        try Data(log.utf8).write(to: root.appendingPathComponent("events-\(id.uuidString).jsonl"))
        let restored = AIEditingUsageStore(root: root)
        #expect(restored.attempts[0].usage?.total == 2400)
        #expect(restored.attempts[0].finished)
        let again = AIEditingUsageStore(root: root)
        #expect(again.attempts[0].usage?.total == 2400)
    }

    @Test func limitsPersistAndClamp() throws {
        let name = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(AIEditingLimits.load(defaults: defaults).photos == 20)
        var limits = AIEditingLimits()
        limits.ai = 3
        limits.renders = 0
        limits.downloads = 100
        limits.save(defaults: defaults)
        let restored = AIEditingLimits.load(defaults: defaults)
        #expect(restored.ai == 3)
        #expect(restored.renders == 1)
        #expect(restored.downloads == 20)
    }
}
