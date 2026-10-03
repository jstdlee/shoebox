import XCTest
@testable import ShoeboxCore

final class StateStoreTests: XCTestCase {
    let id = SnapshotID("20260101T000000Z")!

    func testFreshStoreReturnsEmptyState() throws {
        let dir = TempDir()
        XCTAssertEqual(try FileStateStore(directory: dir.url).load(), EngineState())
    }

    func testStateRoundTrip() throws {
        let dir = TempDir()
        let store = try FileStateStore(directory: dir.url)
        var state = EngineState()
        state.forceBackupRequested = true
        var active = ActiveSnapshot(id: id, startedAt: id.date, totalAssets: 3)
        active.inFlight["k"] = InFlightJob(assetID: "a", resource: ResourceInfo(kind: .photo, originalFilename: "a.jpg", index: 0), attempts: 1)
        active.failed = [FailedFile(key: "f", reason: "r")]
        state.active = active
        try store.save(state)
        XCTAssertEqual(try FileStateStore(directory: dir.url).load(), state)
    }

    func testCorruptStateIsMovedAsideAndReset() throws {
        let dir = TempDir()
        try Data("{not json".utf8).write(to: dir.url.appendingPathComponent("state.json"))
        let state = try FileStateStore(directory: dir.url).load()
        XCTAssertNil(state.active)
        XCTAssertNotNil(state.lastError)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.url.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("state.corrupt-") })
    }

    func testPlanRoundTrip() throws {
        let dir = TempDir()
        let store = try FileStateStore(directory: dir.url)
        let plan = (0..<5000).map { "asset-\($0)/L0/001" }
        try store.savePlan(plan, for: id)
        XCTAssertEqual(try store.loadPlan(for: id), plan)
    }

    func testUploadedLogAppends() throws {
        let dir = TempDir()
        let store = try FileStateStore(directory: dir.url)
        XCTAssertEqual(try store.loadUploaded(for: id), [])
        try store.appendUploaded(["a", "b"], for: id)
        try store.appendUploaded([], for: id)
        try store.appendUploaded(["c"], for: id)
        XCTAssertEqual(try store.loadUploaded(for: id), ["a", "b", "c"])
    }

    func testRemoveSnapshotFiles() throws {
        let dir = TempDir()
        let store = try FileStateStore(directory: dir.url)
        try store.savePlan(["x"], for: id)
        try store.appendUploaded(["a"], for: id)
        try store.removeSnapshotFiles(for: id)
        XCTAssertThrowsError(try store.loadPlan(for: id))
        XCTAssertEqual(try store.loadUploaded(for: id), [])
        // Removing again is fine.
        XCTAssertNoThrow(try store.removeSnapshotFiles(for: id))
    }

    func testHistoryIsCapped() {
        var state = EngineState()
        for i in 0..<(EngineState.historyLimit + 5) {
            let sid = SnapshotID(date: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + i)))
            state.record(SnapshotSummary(id: sid, startedAt: sid.date, completedAt: sid.date, assetCount: 0,
                                         uploadedFiles: 0, failedFiles: 0, skippedAssets: 0))
        }
        XCTAssertEqual(state.history.count, EngineState.historyLimit)
        XCTAssertEqual(state.history.first?.id, state.lastCompleted?.id, "newest first")
    }

    func testSnapshotIDDecodingRejectsGarbage() {
        XCTAssertThrowsError(try JSONDecoder().decode([SnapshotID].self, from: Data("[\"nope\"]".utf8)))
        XCTAssertEqual(try JSONDecoder().decode([SnapshotID].self, from: Data("[\"20260101T000000Z\"]".utf8)), [id])
    }

    func testManifestRoundTrip() throws {
        let m = Manifest(snapshotID: id, startedAt: id.date, completedAt: id.date.addingTimeInterval(60),
                         assetCount: 2, skippedAssets: 1, files: ["a", "b"], failed: [FailedFile(key: "c", reason: "x")])
        XCTAssertEqual(try Manifest.decode(m.encoded()), m)
        let json = String(decoding: try m.encoded(), as: UTF8.self)
        XCTAssertTrue(json.contains("\"snapshotID\" : \"20260101T000000Z\""))
        XCTAssertTrue(json.contains("\"formatVersion\" : 1"))
    }
}

final class FileLockTests: XCTestCase {
    func testSecondLockFailsUntilFirstReleases() {
        let dir = TempDir()
        let url = dir.url.appendingPathComponent("engine.lock")
        let a = FileLock(url: url)
        let b = FileLock(url: url)
        XCTAssertTrue(a.tryLock())
        XCTAssertTrue(a.tryLock(), "re-entrant for the same instance")
        XCTAssertFalse(b.tryLock())
        a.unlock()
        XCTAssertTrue(b.tryLock())
        b.unlock()
    }

    func testLockReleasedOnDeinit() {
        let dir = TempDir()
        let url = dir.url.appendingPathComponent("engine.lock")
        do {
            let a = FileLock(url: url)
            XCTAssertTrue(a.tryLock())
        }
        XCTAssertTrue(FileLock(url: url).tryLock())
    }

    func testLockInMissingDirectoryFails() {
        let lock = FileLock(url: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/x.lock"))
        XCTAssertFalse(lock.tryLock())
    }
}
