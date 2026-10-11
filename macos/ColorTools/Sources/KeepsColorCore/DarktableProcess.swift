import Foundation
import Darwin
import ImageIO

public final class DarktableProcess {
    public let directory: URL
    public let input: URL
    public let baseline: String
    public let sourceOrientation: Int?
    public let supportsSemanticMasks: Bool
    public let sourcePixelWidth: Int?
    public let sourcePixelHeight: Int?
    public let supportsLocalMasks: Bool
    public let isDisplayReferred: Bool
    public let store: CandidateStore
    private let executable: URL
    private let lock: FileHandle

    public init(executable: URL, source: URL, directory: URL) throws {
        self.executable = executable
        self.directory = directory
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockURL = directory.appendingPathComponent("worker.lock")
        if !fm.fileExists(atPath: lockURL.path) { fm.createFile(atPath: lockURL.path, contents: nil) }
        lock = try FileHandle(forUpdating: lockURL)
        guard flock(lock.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else { throw ColorToolError("Task already has an active worker") }
        let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil)
        let properties = imageSource.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
        sourceOrientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue
        sourcePixelWidth = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        sourcePixelHeight = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        let digest = try contentHash(source)
        store = try CandidateStore(directory: directory, sourceHash: digest)
        input = directory.appendingPathComponent("input." + source.pathExtension.lowercased())
        guard source.standardizedFileURL.resolvingSymlinksInPath() != input.standardizedFileURL.resolvingSymlinksInPath() else {
            throw ColorToolError("Source must be outside the private task input")
        }
        if fm.fileExists(atPath: input.path) {
            guard try contentHash(input) == digest else { throw ColorToolError("Task input hash mismatch") }
        } else {
            let pendingInput = directory.appendingPathComponent("input-\(UUID().uuidString).pending")
            try fm.copyItem(at: source, to: pendingInput)
            guard try contentHash(pendingInput) == digest else { throw ColorToolError("Source changed during copy") }
            try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: pendingInput.path)
            try fm.moveItem(at: pendingInput, to: input)
        }
        let version = try Self.run(executable, arguments: ["--version"], log: directory.appendingPathComponent("version.log"))
        guard version.split(separator: "\n").contains(where: { $0 == "darktable 5.6.2" }) else {
            throw ColorToolError("Requires darktable 5.6.2; got \(version)")
        }
        for name in ["config", "cache", "tmp"] {
            try fm.createDirectory(at: directory.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let baselineURL = directory.appendingPathComponent("baseline.xmp")
        if !fm.fileExists(atPath: baselineURL.path) {
            let output = directory.appendingPathComponent("initial-\(UUID().uuidString).jpg")
            let args = Self.arguments(input: input, xmp: nil, output: output, directory: directory, size: 1600, writeSidecar: true)
            _ = try measuredRender(directory: directory, operation: "initial") {
                try Self.run(executable, arguments: args, log: directory.appendingPathComponent("initial.log"))
            }
            let generated = URL(fileURLWithPath: input.path + ".xmp")
            try Data(contentsOf: generated).write(to: baselineURL, options: .atomic)
        }
        baseline = try String(contentsOf: baselineURL, encoding: .utf8)
        let document = try XMLDocument(xmlString: baseline)
        let description = try document.nodes(forXPath: "//*[local-name()='Description']").first as? XMLElement
        isDisplayReferred = description?.attribute(forName: "darktable:iop_order_version")?.stringValue == "5"
        supportsLocalMasks = !isDisplayReferred && sourceOrientation == 1
        supportsSemanticMasks = !isDisplayReferred && (1...8).contains(sourceOrientation ?? 0)
    }

    public func render(xmp: String, candidateID: String, full: Bool = false) throws -> URL {
        _ = try store.candidate(candidateID)
        let stem = candidateID + (full ? "-full" : "-preview")
        let output = directory.appendingPathComponent(stem + ".jpg")
        if FileManager.default.fileExists(atPath: output.path) { return output }
        let sidecar = directory.appendingPathComponent(stem + ".xmp")
        try xmp.write(to: sidecar, atomically: true, encoding: .utf8)
        let pending = directory.appendingPathComponent(stem + "-\(UUID().uuidString).jpg")
        _ = try measuredRender(directory: directory, operation: stem) {
            try Self.run(executable, arguments: Self.arguments(input: input, xmp: sidecar, output: pending, directory: directory, size: full ? 0 : 1600, writeSidecar: false), log: directory.appendingPathComponent(stem + ".log"))
        }
        guard FileManager.default.fileExists(atPath: pending.path) else { throw ColorToolError("Renderer returned no output") }
        try FileManager.default.moveItem(at: pending, to: output)
        return output
    }

    private static func arguments(input: URL, xmp: URL?, output: URL, directory: URL, size: Int, writeSidecar: Bool) -> [String] {
        [input.path] + (xmp.map { [$0.path] } ?? []) + [output.path,
            "--width", "\(size)", "--height", "\(size)", "--hq", "true", "--apply-custom-presets", "false", "--icc-type", "sRGB",
            "--core", "--configdir", directory.appendingPathComponent("config").path,
            "--cachedir", directory.appendingPathComponent("cache").path, "--tmpdir", directory.appendingPathComponent("tmp").path,
            "--library", ":memory:", "--conf", "write_sidecar_files=\(writeSidecar ? "on import" : "never")",
            "--conf", "plugins/imageio/format/jpeg/quality=95", "--conf", "plugins/darkroom/workflow=scene-referred (sigmoid)"]
    }

    private static func run(_ executable: URL, arguments: [String], log: URL) throws -> String {
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        let deadline = Date().addingTimeInterval(180)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        let text = try String(contentsOf: log, encoding: .utf8)
        guard process.terminationStatus == 0 else { throw ColorToolError("darktable exit \(process.terminationStatus); log=\(log.path)\n\(text)") }
        return text
    }
}
