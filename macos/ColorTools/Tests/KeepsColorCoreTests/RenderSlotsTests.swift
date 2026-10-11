import Foundation
import Darwin
import XCTest
@testable import KeepsColorCore

final class RenderSlotsTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("render-slots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testLimitAndReleaseAcrossIndependentWorkers() throws {
        let directory = try temporaryDirectory()
        let first = try RenderSlots(directory: directory, limit: 2)
        let second = try RenderSlots(directory: directory, limit: 2)
        let third = try RenderSlots(directory: directory, limit: 2)
        let firstHandle = try first.acquire()
        let secondHandle = try second.acquire()
        var checks = 0
        XCTAssertThrowsError(try third.acquire(cancelled: { checks += 1; return checks > 1 })) { error in
            XCTAssertTrue(error is CancellationError)
        }
        RenderSlots.release(firstHandle)
        let thirdHandle = try third.acquire()
        RenderSlots.release(thirdHandle)
        RenderSlots.release(secondHandle)
    }

    func testKilledProcessReleasesSlot() throws {
        let directory = try temporaryDirectory()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", "import fcntl,sys,time; f=open(sys.argv[1], 'a'); fcntl.flock(f,fcntl.LOCK_EX); print('locked',flush=True); time.sleep(30)", directory.appendingPathComponent("render-0.lock").path]
        let pipe = Pipe()
        child.standardOutput = pipe
        try child.run()
        defer { if child.isRunning { kill(child.processIdentifier, SIGKILL); child.waitUntilExit() } }
        XCTAssertEqual(String(data: pipe.fileHandleForReading.availableData, encoding: .utf8), "locked\n")
        let worker = try RenderSlots(directory: directory, limit: 1)
        var checks = 0
        XCTAssertThrowsError(try worker.acquire(cancelled: { checks += 1; return checks > 1 }))
        kill(child.processIdentifier, SIGKILL)
        child.waitUntilExit()
        let handle = try worker.acquire()
        RenderSlots.release(handle)
    }

    func testAsyncWaitingCanBeCancelledAndFailureReleasesSlot() async throws {
        let directory = try temporaryDirectory()
        let occupied = try RenderSlots(directory: directory, limit: 1)
        let handle = try occupied.acquire()
        let waiting = Task {
            try await RenderSlots.withSlot(directory: directory, limit: 1) { 42 }
        }
        try await Task.sleep(for: .milliseconds(150))
        waiting.cancel()
        do {
            _ = try await waiting.value
            XCTFail("Waiting task must observe cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        RenderSlots.release(handle)
        do {
            let _: Int = try await RenderSlots.withSlot(directory: directory, limit: 1) {
                throw ColorToolError("render failed")
            }
            XCTFail("Failure must propagate")
        } catch { XCTAssertTrue(error is ColorToolError) }
        let result = try await RenderSlots.withSlot(directory: directory, limit: 1) { 42 }
        XCTAssertEqual(result, 42)
    }

    private actor StartOrder {
        var values: [Int] = []
        func append(_ value: Int) { values.append(value) }
    }

    private func waitForRequests(_ count: Int, directory: URL) async throws {
        for _ in 0..<100 {
            let pending = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { $0.hasPrefix("pending-") }
            if pending.count == count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Waiting requests were not registered")
    }

    func testHigherPhotoWinsDespiteReverseRegistrationOrder() async throws {
        let directory = try temporaryDirectory()
        let occupied = try RenderSlots(directory: directory, limit: 1)
        let handle = try occupied.acquire()
        let order = StartOrder()
        let lower = Task {
            try await RenderSlots.withSlot(directory: directory, limit: 1, priority: 9) {
                await order.append(9)
            }
        }
        try await waitForRequests(1, directory: directory)
        let upper = Task {
            try await RenderSlots.withSlot(directory: directory, limit: 1, priority: 1) {
                await order.append(1)
            }
        }
        try await waitForRequests(2, directory: directory)
        RenderSlots.release(handle)
        try await upper.value
        try await lower.value
        let actual = await order.values
        XCTAssertEqual(actual, [1, 9])
    }

    func testTerminatedWaitingProcessDoesNotBlockQueue() throws {
        let directory = try temporaryDirectory()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", "import fcntl,sys,time,json; f=open(sys.argv[1], 'w+'); fcntl.flock(f,fcntl.LOCK_EX); json.dump({'id':'dead','priority':0,'created':0},f); f.flush(); print('waiting',flush=True); time.sleep(30)", directory.appendingPathComponent("pending-dead.lock").path]
        let pipe = Pipe()
        child.standardOutput = pipe
        try child.run()
        defer { if child.isRunning { kill(child.processIdentifier, SIGKILL); child.waitUntilExit() } }
        XCTAssertEqual(String(data: pipe.fileHandleForReading.availableData, encoding: .utf8), "waiting\n")
        let worker = try RenderSlots(directory: directory, limit: 1, priority: 1)
        var checks = 0
        XCTAssertThrowsError(try worker.acquire(cancelled: { checks += 1; return checks > 1 }))
        kill(child.processIdentifier, SIGKILL)
        child.waitUntilExit()
        let handle = try worker.acquire()
        RenderSlots.release(handle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("pending-dead.lock").path))
    }

    func testEnvironmentRequiresCompleteValidConfiguration() throws {
        XCTAssertNil(try RenderSlots.configured(environment: [:]))
        XCTAssertThrowsError(try RenderSlots.configured(environment: ["KEEPS_RENDER_LIMIT": "2"]))
        XCTAssertThrowsError(try RenderSlots.configured(environment: ["KEEPS_RENDER_LIMIT": "0", "KEEPS_RENDER_SLOTS": "/tmp/unused"]))
        XCTAssertThrowsError(try RenderSlots.configured(environment: ["KEEPS_RENDER_LIMIT": "2", "KEEPS_RENDER_SLOTS": "relative"]))
    }

    func testTimingsPersistSuccessfulAndFailedExecution() throws {
        let directory = try temporaryDirectory()
        XCTAssertEqual(try measuredRender(directory: directory, operation: "preview") { 42 }, 42)
        XCTAssertThrowsError(try measuredRender(directory: directory, operation: "full") { throw ColorToolError("failed") })
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let timings = try decoder.decode(RenderTimings.self, from: Data(contentsOf: directory.appendingPathComponent("render-timings.json")))
        XCTAssertEqual(timings.records.map(\.operation), ["preview", "full"])
        XCTAssertEqual(timings.records.map(\.succeeded), [true, false])
        XCTAssertTrue(timings.records.allSatisfy { $0.queuedSeconds >= 0 && $0.executionSeconds >= 0 })
    }
}
