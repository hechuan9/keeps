import Combine
import Foundation
import KeepsAPI

private actor IOSDirectoryReader {
    private let configuration: KeepsConfiguration
    private let rootDirectory: URL?
    private var database: KeepsLibraryDatabase?

    init(configuration: KeepsConfiguration, rootDirectory: URL?) {
        self.configuration = configuration
        self.rootDirectory = rootDirectory
    }

    func directories(at path: String?) throws -> [KeepsNavigationDirectory]? {
        if database == nil {
            database = try KeepsLibraryDatabase(configuration: configuration, rootDirectory: rootDirectory)
        }
        return try database?.navigation(path: path)?.directories
    }
}

@MainActor
final class IOSDirectoryStore: ObservableObject {
    struct Entry {
        var directories: [KeepsNavigationDirectory]?
        var loading = false
        var error: String?
    }

    @Published private var entries: [String?: Entry] = [:]
    private var configuration: KeepsConfiguration?
    private var rootDirectory: URL?
    private var reader: IOSDirectoryReader?
    private var requests: [String?: UUID] = [:]
    var synchronize: (() async -> Void)?

    func configure(_ configuration: KeepsConfiguration?, rootDirectory: URL? = nil) {
        guard self.configuration != configuration || self.rootDirectory != rootDirectory else { return }
        self.configuration = configuration
        self.rootDirectory = rootDirectory
        reader = configuration.map { IOSDirectoryReader(configuration: $0, rootDirectory: rootDirectory) }
        requests = [:]
        entries = [:]
    }

    func state(for path: String?, configuration: KeepsConfiguration?) -> Entry {
        guard self.configuration == configuration else { return Entry() }
        return entries[path] ?? Entry(loading: reader != nil)
    }

    func load(configuration: KeepsConfiguration?, path: String?, force: Bool = false) async {
        guard self.configuration == configuration, let reader else { return }
        let request = UUID()
        requests[path] = request
        var entry = entries[path] ?? Entry()
        entry.loading = true
        entry.error = nil
        entries[path] = entry
        if force { await synchronize?() }
        guard requests[path] == request else { return }
        do {
            let directories = try await reader.directories(at: path)
            guard requests[path] == request else { return }
            entries[path] = Entry(directories: directories)
        } catch {
            guard requests[path] == request else { return }
            entry.loading = false
            entry.error = String(reflecting: error)
            entries[path] = entry
        }
    }

    func reload() {
        let configuration = configuration
        let reader = reader
        for path in Array(entries.keys) {
            Task {
                guard self.reader === reader else { return }
                await load(configuration: configuration, path: path)
            }
        }
    }
}
