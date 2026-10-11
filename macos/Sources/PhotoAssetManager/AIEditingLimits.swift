import Foundation

struct AIEditingLimits: Codable, Equatable, Sendable {
    var photos = 20
    var ai = 20
    var renders = 2
    var downloads = 2
    var uploads = 2

    var bounded: Self {
        var result = self
        result.photos = min(20, max(1, photos))
        result.ai = min(20, max(1, ai))
        result.renders = min(20, max(1, renders))
        result.downloads = min(20, max(1, downloads))
        result.uploads = min(20, max(1, uploads))
        return result
    }

    static func load(defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: "aiEditing.limits"),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value.bounded
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(bounded), forKey: "aiEditing.limits")
    }
}

struct AIEditingPriorityQueue {
    private struct Entry {
        let id: UUID
        var position: Int
    }
    private var heap: [Entry] = []
    var first: UUID? { heap.first?.id }

    mutating func insert(_ id: UUID, position: Int) {
        guard !heap.contains(where: { $0.id == id }) else { return }
        heap.append(.init(id: id, position: position))
        var index = heap.count - 1
        while index > 0 {
            let parent = (index - 1) / 2
            guard precedes(heap[index], heap[parent]) else { break }
            heap.swapAt(index, parent)
            index = parent
        }
    }

    @discardableResult mutating func pop() -> UUID? {
        guard let id = first else { return nil }
        remove(id)
        return id
    }

    mutating func remove(_ id: UUID) {
        guard let index = heap.firstIndex(where: { $0.id == id }) else { return }
        heap.remove(at: index)
        rebuild()
    }

    mutating func updateOrder(_ ids: [UUID]) {
        let positions = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
        for index in heap.indices { heap[index].position = positions[heap[index].id] ?? Int.max }
        rebuild()
    }

    private func precedes(_ lhs: Entry, _ rhs: Entry) -> Bool {
        lhs.position == rhs.position ? lhs.id.uuidString < rhs.id.uuidString : lhs.position < rhs.position
    }

    private mutating func rebuild() {
        guard heap.count > 1 else { return }
        for root in stride(from: heap.count / 2 - 1, through: 0, by: -1) {
            var index = root
            while index * 2 + 1 < heap.count {
                let left = index * 2 + 1, right = left + 1
                let child = right < heap.count && precedes(heap[right], heap[left]) ? right : left
                guard precedes(heap[child], heap[index]) else { break }
                heap.swapAt(index, child)
                index = child
            }
        }
    }
}
