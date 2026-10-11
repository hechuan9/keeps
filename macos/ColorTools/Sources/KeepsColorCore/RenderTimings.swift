import Foundation

struct RenderTiming: Codable {
    let id: UUID
    let operation: String
    let startedAt: Date
    let queuedSeconds: Double
    let executionSeconds: Double
    let succeeded: Bool
}

struct RenderTimings: Codable {
    var records: [RenderTiming] = []
}

private struct RenderStatus: Codable {
    let phase: String
    let operation: String
    let startedAt: Date
}

func measuredRender<T>(directory: URL, operation: String, _ body: () throws -> T) throws -> T {
    let slots = try RenderSlots.configured()
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    func status(_ phase: String) throws {
        try encoder.encode(RenderStatus(phase: phase, operation: operation, startedAt: Date()))
            .write(to: directory.appendingPathComponent("render-status.json"), options: .atomic)
    }
    try status("waiting")
    let startedAt = Date()
    let queuedAt = ProcessInfo.processInfo.systemUptime
    let handle = try slots?.acquire()
    defer { if let handle { RenderSlots.release(handle) } }
    let executingAt = ProcessInfo.processInfo.systemUptime
    try status("rendering")
    let result = Result { try body() }
    let finishedAt = ProcessInfo.processInfo.systemUptime
    let succeeded: Bool
    switch result { case .success: succeeded = true; case .failure: succeeded = false }
    let timing = RenderTiming(id: UUID(), operation: operation, startedAt: startedAt,
                              queuedSeconds: executingAt - queuedAt,
                              executionSeconds: finishedAt - executingAt, succeeded: succeeded)
    let timingURL = directory.appendingPathComponent("render-timings.json")
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var timings = FileManager.default.fileExists(atPath: timingURL.path)
        ? try decoder.decode(RenderTimings.self, from: Data(contentsOf: timingURL)) : RenderTimings()
    timings.records.append(timing)
    try encoder.encode(timings).write(to: timingURL, options: .atomic)
    try status(succeeded ? "finished" : "failed")
    return try result.get()
}
