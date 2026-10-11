import CryptoKit
import Foundation

struct ImportSourceFile: Codable, Sendable {
    let url: URL
    let sourcePath: String
    let size: Int64
    let modifiedAt: Date
    let sha256: String?
}

enum ImportSource {
    private static let photoExtensions: Set<String> = [
        "3fr", "ari", "arw", "bay", "cr2", "cr3", "crw", "dcr", "dng", "erf", "fff", "iiq", "k25",
        "kdc", "mef", "mos", "mrw", "nef", "nrw", "orf", "pef", "raf", "raw", "rw2", "rwl", "sr2",
        "srf", "srw", "heif", "heic", "hif", "jpg", "jpeg",
    ]

    static func scan(_ root: URL, calculateHashes: Bool = false) throws -> [ImportSourceFile] {
        try Task.checkCancellation()
        let root = root.standardizedFileURL
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ScanError.invalidDirectory(root.path)
        }
        var files: [ImportSourceFile] = []
        try scanDirectory(root, relativePath: "", calculateHashes: calculateHashes, files: &files)
        return files.sorted { $0.sourcePath < $1.sourcePath }
    }

    private static func scanDirectory(_ directory: URL, relativePath: String, calculateHashes: Bool, files: inout [ImportSourceFile]) throws {
        try Task.checkCancellation()
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey]
        let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
        var regularFiles: [URL] = []
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            try Task.checkCancellation()
            let values = try child.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true, values.isHidden != true,
                  !child.lastPathComponent.hasPrefix("."),
                  !["@eadir", "#recycle"].contains(child.lastPathComponent.lowercased()) else { continue }
            if values.isDirectory == true {
                try scanDirectory(child, relativePath: relativePath + child.lastPathComponent + "/", calculateHashes: calculateHashes, files: &files)
            } else if values.isRegularFile == true {
                regularFiles.append(child)
            }
        }
        let photos = regularFiles.filter { photoExtensions.contains($0.pathExtension.lowercased()) }
        let sidecarNames = Set(photos.flatMap {
            [$0.deletingPathExtension().lastPathComponent.lowercased() + ".xmp", $0.lastPathComponent.lowercased() + ".xmp"]
        })
        for file in regularFiles where photoExtensions.contains(file.pathExtension.lowercased()) || sidecarNames.contains(file.lastPathComponent.lowercased()) {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard let size = attributes[.size] as? NSNumber,
                  let modifiedAt = attributes[.modificationDate] as? Date else {
                throw ScanError.changedDuringRead(file.path)
            }
            let digest = calculateHashes ? try hash(file).1 : nil
            files.append(ImportSourceFile(url: file, sourcePath: relativePath + file.lastPathComponent,
                                          size: size.int64Value, modifiedAt: modifiedAt, sha256: digest))
        }
    }

    private static func hash(_ url: URL) throws -> (Int64, String) {
        try Task.checkCancellation()
        let before = try FileManager.default.attributesOfItem(atPath: url.path)
        let handle = try FileHandle(forReadingFrom: url)
        var hasher = SHA256()
        var bytesRead: Int64 = 0
        // FileHandle buffers can otherwise survive until the detached task finishes.
        while try autoreleasepool(invoking: { () throws -> Bool in
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty else { return false }
            bytesRead += Int64(chunk.count)
            hasher.update(data: chunk)
            return true
        }) {}
        try handle.close()
        let after = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = before[.size] as? NSNumber,
              let modified = before[.modificationDate] as? Date,
              size == after[.size] as? NSNumber,
              modified == after[.modificationDate] as? Date,
              bytesRead == size.int64Value else {
            throw ScanError.changedDuringRead(url.path)
        }
        return (bytesRead, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private enum ScanError: LocalizedError {
        case invalidDirectory(String)
        case changedDuringRead(String)

        var errorDescription: String? {
            switch self {
            case .invalidDirectory(let path): "导入来源必须是实际文件夹：\(path)"
            case .changedDuringRead(let path): "读取期间文件发生变化，请重试：\(path)"
            }
        }
    }
}
