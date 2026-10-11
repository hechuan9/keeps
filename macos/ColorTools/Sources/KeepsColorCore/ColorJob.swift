import Foundation
import CryptoKit

public struct ColorToolError: Error, CustomStringConvertible {
    public let description: String
    public init(_ message: String) { description = message }
}

public struct ColorCandidate: Codable, Equatable {
    public let id: String
    public let operationID: String
    public let parentID: String?
    public let recipe: Data
}

public final class CandidateStore {
    private struct State: Codable {
        var schemaVersion = 1
        var engineVersion = "5.6.2"
        var sourceHash: String
        var candidates: [ColorCandidate] = []
    }
    public let directory: URL
    private var state: State
    private var stateURL: URL { directory.appendingPathComponent("candidates.json") }
    public var candidates: [ColorCandidate] { state.candidates }

    public init(directory: URL, sourceHash: String) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("candidates.json")
        if FileManager.default.fileExists(atPath: path.path) {
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: path))
            guard state.schemaVersion == 1, state.engineVersion == "5.6.2", state.sourceHash == sourceHash else {
                throw ColorToolError("Task source or recipe version changed")
            }
        } else {
            state = State(sourceHash: sourceHash)
            try persist(state)
        }
    }

    public func candidate(_ id: String) throws -> ColorCandidate {
        guard let candidate = state.candidates.first(where: { $0.id == id }) else {
            throw ColorToolError("Unknown candidate: \(id)")
        }
        return candidate
    }

    public func add(operationID: String, parentID: String?, recipe: Data) throws -> ColorCandidate {
        guard !operationID.isEmpty, operationID.count <= 128 else { throw ColorToolError("Invalid operationID") }
        if let previous = state.candidates.first(where: { $0.operationID == operationID }) {
            guard previous.parentID == parentID, previous.recipe == recipe else {
                throw ColorToolError("operationID reused with different parameters")
            }
            return previous
        }
        if let parentID { _ = try candidate(parentID) }
        let candidate = ColorCandidate(id: UUID().uuidString, operationID: operationID, parentID: parentID, recipe: recipe)
        var next = state
        next.candidates.append(candidate)
        try persist(next)
        state = next
        return candidate
    }

    private func persist(_ value: State) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: stateURL, options: .atomic)
    }
}

public func contentHash(_ url: URL) throws -> String {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var hash = SHA256()
    while let block = try file.read(upToCount: 1024 * 1024), !block.isEmpty { hash.update(data: block) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}
