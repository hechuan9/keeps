import Foundation
import Darwin

/// Separate file descriptions let flock coordinate all photo workers, including after a restart.
public final class RenderSlots {
    private let handles: [FileHandle]
    private let directory: URL
    private let priority: Int
    private let coordinator: FileHandle

    private struct Request: Codable {
        let id: String
        let priority: Int
        let created: TimeInterval
    }

    private static func precedes(_ a: Request, _ b: Request) -> Bool {
        if a.priority != b.priority { return a.priority < b.priority }
        if a.created != b.created { return a.created < b.created }
        return a.id < b.id
    }

    private func coordinated<T>(_ operation: () throws -> T) throws -> T {
        while flock(coordinator.fileDescriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        defer { flock(coordinator.fileDescriptor, LOCK_UN) }
        return try operation()
    }

    private func register() throws -> (Request, FileHandle) {
        try coordinated {
            let request = Request(id: UUID().uuidString, priority: priority, created: Date().timeIntervalSince1970)
            let path = directory.appendingPathComponent("pending-\(request.id).lock").path
            let descriptor = open(path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            do {
                guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                try handle.write(contentsOf: JSONEncoder().encode(request))
                return (request, handle)
            } catch {
                unlink(path)
                throw error
            }
        }
    }

    private func remove(_ request: Request) {
        // The lifecycle lock remains held until its record is removed.
        try? coordinated { unlink(directory.appendingPathComponent("pending-\(request.id).lock").path) }
    }

    private func firstWaitingRequest() throws -> Request? {
        var heap: [Request] = []
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url.lastPathComponent.hasPrefix("pending-") && url.pathExtension == "lock" {
            let descriptor = open(url.path, O_RDWR | O_CLOEXEC)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                // A cancelled or terminated worker no longer owns this record.
                unlink(url.path)
                try handle.close()
                continue
            }
            guard errno == EWOULDBLOCK else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let request = try JSONDecoder().decode(Request.self, from: handle.readToEnd() ?? Data())
            heap.append(request)
            var index = heap.count - 1
            while index > 0 {
                let parent = (index - 1) / 2
                guard Self.precedes(heap[index], heap[parent]) else { break }
                heap.swapAt(index, parent)
                index = parent
            }
        }
        return heap.first
    }

    public init(directory: URL, limit: Int, priority: Int = Int.max) throws {
        guard (1...20).contains(limit) else { throw NSError(domain: "KeepsRenderSlots", code: 1, userInfo: [NSLocalizedDescriptionKey: "KEEPS_RENDER_LIMIT must be between 1 and 20"]) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        self.priority = priority
        let descriptor = open(directory.appendingPathComponent("queue.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        coordinator = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        handles = try (0..<limit).map { index in
            let path = directory.appendingPathComponent("render-\(index).lock").path
            let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        }
    }

    public static func configured(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> RenderSlots? {
        guard environment["KEEPS_RENDER_LIMIT"] != nil || environment["KEEPS_RENDER_SLOTS"] != nil else { return nil }
        guard let rawLimit = environment["KEEPS_RENDER_LIMIT"], let limit = Int(rawLimit),
              let path = environment["KEEPS_RENDER_SLOTS"], path.hasPrefix("/") else {
            throw NSError(domain: "KeepsRenderSlots", code: 2, userInfo: [NSLocalizedDescriptionKey: "Set KEEPS_RENDER_LIMIT and an absolute KEEPS_RENDER_SLOTS directory together"])
        }
        let priority: Int
        if let raw = environment["KEEPS_RENDER_PRIORITY"] {
            guard let value = Int(raw) else { throw NSError(domain: "KeepsRenderSlots", code: 3, userInfo: [NSLocalizedDescriptionKey: "KEEPS_RENDER_PRIORITY must be an integer"]) }
            priority = value
        } else { priority = Int.max }
        return try RenderSlots(directory: URL(fileURLWithPath: path), limit: limit, priority: priority)
    }

    public func acquire(cancelled: () -> Bool = { false }) throws -> FileHandle {
        let (request, lifetime) = try register()
        defer { remove(request); try? lifetime.close() }
        while true {
            if cancelled() { throw CancellationError() }
            if let handle = try acquireAvailable(request: request) { return handle }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private func acquireAvailable(request: Request) throws -> FileHandle? {
        try coordinated {
            guard try firstWaitingRequest()?.id == request.id else { return nil }
            for handle in handles {
                if flock(handle.fileDescriptor, LOCK_EX | LOCK_NB) == 0 {
                    unlink(directory.appendingPathComponent("pending-\(request.id).lock").path)
                    return handle
                }
                guard errno == EWOULDBLOCK || errno == EINTR else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            return nil
        }
    }

    public static func withSlot<T: Sendable>(directory: URL, limit: Int, priority: Int = Int.max,
                                             operation: @Sendable () async throws -> T) async throws -> T {
        let slots = try RenderSlots(directory: directory, limit: limit, priority: priority)
        let (request, lifetime) = try slots.register()
        defer { slots.remove(request); try? lifetime.close() }
        while true {
            try Task.checkCancellation()
            if let handle = try slots.acquireAvailable(request: request) {
                defer { release(handle) }
                return try await operation()
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    public static func release(_ handle: FileHandle) { flock(handle.fileDescriptor, LOCK_UN) }
}
