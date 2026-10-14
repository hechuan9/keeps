import Foundation

struct PhotoTagSuggestions: Decodable {
    let tags: [String]

    static func decode(_ data: Data) throws -> [String] {
        let response = try JSONDecoder().decode(Self.self, from: data)
        guard response.tags.count <= 12 else { throw AIEditingFailure("AI 返回的标签超过 12 个。") }
        let tags = response.tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard tags.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 && !$0.contains(where: { $0.isNewline }) }) else {
            throw AIEditingFailure("AI 返回的标签为空、过长或包含换行。")
        }
        return merging([], tags)
    }

    static func merging(_ existing: [String], _ additions: [String]) -> [String] {
        var seen = Set<String>()
        return (existing + additions).filter { seen.insert($0.folding(options: [.caseInsensitive], locale: .current)).inserted }
    }
}
