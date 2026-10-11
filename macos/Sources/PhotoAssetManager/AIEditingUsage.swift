import Foundation
import Combine

struct AIEditingTokenUsage: Codable, Equatable, Sendable {
    let input: Int
    let cachedInput: Int
    let cacheWriteInput: Int
    let output: Int
    var ordinaryInput: Int { max(0, input - cachedInput - cacheWriteInput) }
    var total: Int { input + output }
}

struct AIEditingPrice: Codable, Equatable, Sendable {
    let model: String
    let tier: String
    let verifiedDate: String
    let source: String
    let input: Double
    let cachedInput: Double
    let cacheWriteInput: Double
    let output: Double

    static func standardEstimate(model: String) -> Self? {
        guard model == "gpt-6-luna" else { return nil }
        return Self(model: model, tier: "Standard · 短上下文", verifiedDate: "2026-10-08",
                    source: "https://developers.openai.com/api/docs/pricing",
                    input: 0.10, cachedInput: 0.01, cacheWriteInput: 0.125, output: 0.50)
    }

    func dollars(for usage: AIEditingTokenUsage) -> Double {
        (Double(usage.ordinaryInput) * input + Double(usage.cachedInput) * cachedInput
         + Double(usage.cacheWriteInput) * cacheWriteInput + Double(usage.output) * output) / 1_000_000
    }
}

@MainActor final class AIEditingUsageStore: ObservableObject {
    struct Attempt: Codable, Identifiable {
        let id: UUID
        let startedAt: Date
        let day: String
        let timeZone: String
        let model: String
        let account: String?
        let job: String
        let price: AIEditingPrice?
        var events: [Int: AIEditingTokenUsage] = [:]
        var usage: AIEditingTokenUsage? {
            guard !events.isEmpty else { return nil }
            return AIEditingTokenUsage(input: events.values.reduce(0) { $0 + $1.input },
                cachedInput: events.values.reduce(0) { $0 + $1.cachedInput },
                cacheWriteInput: events.values.reduce(0) { $0 + $1.cacheWriteInput },
                output: events.values.reduce(0) { $0 + $1.output })
        }
        var finished = false
        var success: Bool?
        var estimatedUSD: Double? { usage.flatMap { price?.dollars(for: $0) } }
    }

    struct Day: Identifiable {
        let id: String
        let attempts: [Attempt]
        var tokens: Int { attempts.compactMap(\.usage).reduce(0) { $0 + $1.total } }
        var ordinaryInput: Int { attempts.compactMap(\.usage).reduce(0) { $0 + $1.ordinaryInput } }
        var cachedInput: Int { attempts.compactMap(\.usage).reduce(0) { $0 + $1.cachedInput } }
        var cacheWriteInput: Int { attempts.compactMap(\.usage).reduce(0) { $0 + $1.cacheWriteInput } }
        var output: Int { attempts.compactMap(\.usage).reduce(0) { $0 + $1.output } }
        var unknown: Int { attempts.filter { $0.usage == nil }.count }
        var estimatedUSD: Double { attempts.compactMap(\.estimatedUSD).reduce(0, +) }
        var unpriced: Int { attempts.filter { $0.usage != nil && $0.price == nil }.count }
    }

    @Published private(set) var attempts: [Attempt] = []
    @Published private(set) var errorMessage: String?
    private let file: URL
    private var loadFailed = false

    init(root: URL) {
        file = root.appendingPathComponent("usage.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            attempts = try JSONDecoder().decode([Attempt].self, from: Data(contentsOf: file))
            try recoverInterruptedAttempts()
        }
        catch { loadFailed = true; errorMessage = "无法读取 AI 用量记录：\(error)" }
    }

    var days: [Day] {
        Dictionary(grouping: attempts, by: \.day).map { Day(id: $0.key, attempts: $0.value) }
            .sorted { $0.id > $1.id }
    }

    static func dayKey(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    @discardableResult func begin(model: String, account: String?, job: URL, at: Date = Date()) throws -> UUID {
        let attempt = Attempt(id: UUID(), startedAt: at, day: Self.dayKey(at), timeZone: TimeZone.current.identifier,
                              model: model, account: account, job: job.path, price: .standardEstimate(model: model))
        try persist(attempts + [attempt])
        return attempt.id
    }

    func consume(_ line: String, attemptID: UUID, eventIndex: Int) throws {
        guard let data = line.data(using: .utf8),
              let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              event["type"] as? String == "turn.completed",
              let raw = event["usage"] as? [String: Any],
              let input = raw["input_tokens"] as? Int,
              let output = raw["output_tokens"] as? Int,
              let index = attempts.firstIndex(where: { $0.id == attemptID }) else { return }
        let cached = raw["cached_input_tokens"] as? Int ?? 0
        let writes = raw["cache_write_input_tokens"] as? Int ?? 0
        guard input >= 0, output >= 0, cached >= 0, writes >= 0, cached + writes <= input else {
            throw AIEditingFailure("AI 返回的用量数据无效，诊断日志已保留。")
        }
        // Stable JSONL line numbers make recovery replay idempotent.
        let usage = AIEditingTokenUsage(input: input, cachedInput: cached, cacheWriteInput: writes, output: output)
        guard attempts[index].events[eventIndex] != usage else { return }
        var updated = attempts
        updated[index].events[eventIndex] = usage
        try persist(updated)
    }

    func finish(attemptID: UUID, success: Bool) throws {
        guard let index = attempts.firstIndex(where: { $0.id == attemptID }) else { return }
        var updated = attempts
        updated[index].finished = true
        updated[index].success = success
        try persist(updated)
    }

    private func recoverInterruptedAttempts() throws {
        for attempt in attempts where !attempt.finished {
            let events = URL(fileURLWithPath: attempt.job).appendingPathComponent("events-\(attempt.id.uuidString).jsonl")
            if FileManager.default.fileExists(atPath: events.path) {
                let lines = try String(contentsOf: events, encoding: .utf8).components(separatedBy: "\n")
                for (index, line) in lines.enumerated() where !line.isEmpty {
                    try consume(line, attemptID: attempt.id, eventIndex: index)
                }
            }
            try finish(attemptID: attempt.id, success: false)
        }
    }

    private func persist(_ updated: [Attempt]) throws {
        guard !loadFailed else { throw AIEditingFailure(errorMessage ?? "AI 用量记录无法读取") }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(updated).write(to: file, options: .atomic)
            attempts = updated
            errorMessage = nil
        } catch {
            errorMessage = "无法保存 AI 用量记录：\(error)"
            throw error
        }
    }
}
