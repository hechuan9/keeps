import Foundation
import XCTest
@testable import KeepsColorCore

final class ColorJobTests: XCTestCase {
    func testCandidateIdentityAndReload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CandidateStore(directory: root, sourceHash: "fixture-hash")
        let first = try store.add(operationID: "one", parentID: nil, recipe: Data("one".utf8))
        let retry = try store.add(operationID: "one", parentID: nil, recipe: Data("one".utf8))
        XCTAssertEqual(first.id, retry.id)
        XCTAssertThrowsError(try store.add(operationID: "one", parentID: nil, recipe: Data("two".utf8)))
        let loaded = try CandidateStore(directory: root, sourceHash: "fixture-hash")
        XCTAssertEqual(try loaded.candidate(first.id).recipe, Data("one".utf8))
        XCTAssertThrowsError(try CandidateStore(directory: root, sourceHash: "changed"))
        XCTAssertThrowsError(try loaded.add(operationID: "two", parentID: "missing", recipe: Data()))
    }
    func testCandidatesAreImmutable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CandidateStore(directory: root, sourceHash: "fixture")
        let a = try store.add(operationID: "a", parentID: nil, recipe: Data("one".utf8))
        let b = try store.add(operationID: "b", parentID: a.id, recipe: Data("two".utf8))
        XCTAssertEqual(b.recipe, Data("two".utf8))
        XCTAssertEqual(try store.candidate(a.id).recipe, Data("one".utf8))
        XCTAssertThrowsError(try store.candidate("../../elsewhere"))
    }
}
