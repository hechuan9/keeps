import Foundation
import Testing
@testable import PhotoAssetManager

struct ImportSourceTests {
    @Test func recursivelyFindsPhotosAndAssociatedSidecarsWithoutChangingSources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = [
            "one/IMG.ARW", "one/IMG.xmp", "one/IMG.ARW.XMP", "one/unrelated.xmp",
            "two/IMG.ARW", "two/IMG.HEIC", "two/IMG.HEIC.xmp", "third/photo.heif", "photo.hif",
            "deep/nested/IMG.JPG", "deep/nested/IMG.xmp", "deep/nested/IMG.JPG.XMP",
            "deep/nested/other.JpEg", "deep/nested/other.jpeg.xmp", "two/ignored.mov", "notes.txt", ".hidden/file.arw",
            "@eaDir/thumb.heic", "#recycle/old.nef", "two/.hidden.heif",
        ]
        for path in paths {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("abc".utf8).write(to: file)
        }

        let files = try ImportSource.scan(root)

        #expect(files.map(\.sourcePath) == [
            "deep/nested/IMG.JPG", "deep/nested/IMG.JPG.XMP", "deep/nested/IMG.xmp",
            "deep/nested/other.JpEg", "deep/nested/other.jpeg.xmp",
            "one/IMG.ARW", "one/IMG.ARW.XMP", "one/IMG.xmp", "photo.hif", "third/photo.heif",
            "two/IMG.ARW", "two/IMG.HEIC", "two/IMG.HEIC.xmp",
        ])
        #expect(files.allSatisfy { $0.size == 3 })
        let hashed = try ImportSource.hash(root.appendingPathComponent("one/IMG.ARW"))
        #expect(hashed.0 == 3)
        #expect(hashed.1 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        for path in paths {
            #expect(try Data(contentsOf: root.appendingPathComponent(path)) == Data("abc".utf8))
        }
    }

    @Test func excludesSymbolicLinksAndDoesNotAssociateSidecarsAcrossDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("actual")
        let other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let photo = source.appendingPathComponent("photo.nef")
        try Data([1, 2, 3]).write(to: photo)
        try Data([4]).write(to: other.appendingPathComponent("photo.xmp"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: source)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("linked.nef"), withDestinationURL: photo)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("photo.xmp"), withDestinationURL: photo)

        #expect(try ImportSource.scan(root).map(\.sourcePath) == ["actual/photo.nef"])
        #expect(throws: (any Error).self) { try ImportSource.scan(root.appendingPathComponent("linked")) }
    }

    @Test func photoGroupsKeepDirectoryScopeAndAllSidecarForms() {
        let group = ImportSource.groupKey("Trip/IMG.NEF")
        for path in ["Trip/img.jpg", "Trip/IMG.HEIC", "Trip/img.xmp", "Trip/IMG.NEF.xmp"] {
            #expect(ImportSource.groupKey(path) == group)
        }
        #expect(ImportSource.groupKey("Elsewhere/IMG.NEF") != group)
        #expect(ImportSource.groupKey("trip/IMG.NEF") != group)
    }

    @Test func missingSourceFailsInsteadOfReportingEmptySuccess() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(throws: (any Error).self) { try ImportSource.scan(missing) }
    }

    @Test func cancelledScanThrows() async {
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ImportSource.scan(FileManager.default.temporaryDirectory)
        }
        do {
            _ = try await task.value
            Issue.record("取消后的导入扫描不应成功")
        } catch {
            #expect(error is CancellationError)
        }
    }
}
