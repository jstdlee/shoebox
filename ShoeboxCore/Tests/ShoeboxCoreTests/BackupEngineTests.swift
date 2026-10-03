import XCTest
@testable import ShoeboxCore

/// End-to-end scenarios for the backup state machine, with PhotoKit, the job
/// system and the bucket replaced by fakes.
final class BackupEngineTests: XCTestCase {
    let day: TimeInterval = 86_400
    let s3 = S3Config(endpoint: URL(string: "https://acct.r2.cloudflarestorage.com")!, region: "auto", bucket: "photos", prefix: "phone")
    let creds = S3Credentials(accessKeyID: "AK", secretAccessKey: "SK")

    var dir: TempDir!
    var library: FakeLibrary!
    var queue: FakeJobQueue!
    var remote: FakeSnapshotStore!
    var store: FileStateStore!
    var clock: FixedClock!
    var settings: BackupSettings!

    override func setUpWithError() throws {
        dir = TempDir()
        library = FakeLibrary()
        queue = FakeJobQueue(jobLimit: 10)
        remote = FakeSnapshotStore(layout: KeyLayout(prefix: "phone"))
        store = try FileStateStore(directory: dir.url)
        clock = FixedClock(Date(timeIntervalSince1970: 1_790_000_000))
        settings = BackupSettings(s3: s3, intervalDays: 7, keepLatest: 2)
    }

    func engine(credentials: S3Credentials? = nil, lock: FileLock? = nil) -> BackupEngine {
        BackupEngine(settings: settings, credentials: credentials ?? creds, library: library, queue: queue,
                     remote: remote, store: store, clock: clock, lock: lock, timeZone: TimeZone(identifier: "UTC")!,
                     transport: MockTransport())
    }

    func state() throws -> EngineState { try store.load() }

    /// Run passes, completing all uploads in between, until the engine is idle.
    @discardableResult
    func runToCompletion(maxPasses: Int = 100, fail: (NewUploadJob) -> Bool = { _ in false }) async -> [EngineOutcome] {
        var outcomes: [EngineOutcome] = []
        for _ in 0..<maxPasses {
            let outcome = await engine().run()
            outcomes.append(outcome)
            if outcome != .processing { return outcomes }
            queue.completeAll(fail: fail)
        }
        XCTFail("engine did not settle in \(maxPasses) passes")
        return outcomes
    }

    func onlyManifest() throws -> Manifest {
        XCTAssertEqual(remote.manifests.count, 1)
        return try XCTUnwrap(remote.manifests.values.first)
    }

    // MARK: Configuration

    func testNotConfiguredDoesNothing() async throws {
        settings.s3 = nil
        library.addPhoto("A")
        let outcome = await engine().run()
        XCTAssertEqual(outcome, .completed)
        XCTAssertTrue(queue.created.isEmpty)
        XCTAssertEqual(try state().lastError, "Storage is not configured")
        XCTAssertEqual(library.allAssetIDsCalls, 0)
    }

    func testMissingCredentialsDoesNothing() async throws {
        library.addPhoto("A")
        let outcome = await engine(credentials: S3Credentials(accessKeyID: "", secretAccessKey: "")).run()
        XCTAssertEqual(outcome, .completed)
        XCTAssertTrue(queue.created.isEmpty)
        XCTAssertEqual(try state().lastError, "Access keys are missing")
    }

    func testInvalidBucketReported() async throws {
        settings.s3?.bucket = "Bad_Bucket"
        _ = await engine().run()
        XCTAssertEqual(try state().lastError, S3ConfigError.invalidBucketName.rawValue)
    }

    func testEndpointOutsideUploadURLBaseIsRefused() async throws {
        library.addPhoto("a")
        let e = BackupEngine(settings: settings, credentials: creds, library: library, queue: queue, remote: remote,
                             store: store, clock: clock, uploadURLBase: URL(string: "https://other.r2.cloudflarestorage.com")!,
                             transport: MockTransport())
        let outcome = await e.run()
        XCTAssertEqual(outcome, .completed)
        XCTAssertTrue(queue.created.isEmpty)
        XCTAssertTrue(try state().lastError?.contains("upload URL base") == true)
    }

    func testEndpointInsideUploadURLBaseRuns() async throws {
        library.addPhoto("a")
        let e = BackupEngine(settings: settings, credentials: creds, library: library, queue: queue, remote: remote,
                             store: store, clock: clock, uploadURLBase: URL(string: "https://acct.r2.cloudflarestorage.com")!,
                             transport: MockTransport())
        _ = await e.run()
        XCTAssertEqual(queue.created.count, 1)
    }

    func testNoPhotoAccessDoesNotCreateEmptySnapshot() async throws {
        library.addPhoto("a")
        library.denyAccess = true
        let outcome = await engine().run()
        guard case .failure = outcome else { return XCTFail("expected failure, got \(outcome)") }
        XCTAssertNil(try state().active)
        XCTAssertNil(try state().lastCompleted)
        XCTAssertTrue(remote.manifests.isEmpty, "no empty 'complete' snapshot that could trigger retention")
        library.denyAccess = false
        await runToCompletion()
        XCTAssertEqual(try onlyManifest().files.count, 1)
    }

    // MARK: Happy path

    func testFirstRunStartsSnapshotAndCreatesJobs() async throws {
        for i in 0..<3 { library.addPhoto("asset-\(i)") }
        let outcome = await engine().run()
        XCTAssertEqual(outcome, .processing)
        XCTAssertEqual(queue.created.count, 3)
        let s = try state()
        let active = try XCTUnwrap(s.active)
        XCTAssertEqual(active.id, SnapshotID(date: clock.now()))
        XCTAssertEqual(active.totalAssets, 3)
        XCTAssertEqual(active.inFlight.count, 3)
        XCTAssertNotNil(s.lastRunAt)
        XCTAssertNil(s.lastError)
    }

    func testJobDestinationsArePresignedPutsIntoSnapshotFolder() async throws {
        library.addPhoto("asset-1")
        _ = await engine().run()
        let job = try XCTUnwrap(queue.created.first)
        XCTAssertEqual(job.destination.method, "PUT")
        XCTAssertEqual(job.destination.headers["Content-Type"], "image/heic")
        let url = job.destination.url.absoluteString
        let snap = SnapshotID(date: clock.now()).rawValue
        XCTAssertTrue(url.hasPrefix("https://acct.r2.cloudflarestorage.com/photos/phone/snapshots/\(snap)/"), url)
        XCTAssertTrue(url.contains("X-Amz-Expires=604800"))
        XCTAssertTrue(url.contains("X-Amz-Signature="))
        XCTAssertEqual(job.assetID, "asset-1")
    }

    func testFullLifecycleWritesManifestAndRecordsHistory() async throws {
        library.addPhoto("a", live: true)
        library.addPhoto("b", edited: true)
        library.addPhoto("c")
        let outcomes = await runToCompletion()
        XCTAssertEqual(outcomes.last, .completed)

        let manifest = try onlyManifest()
        XCTAssertEqual(manifest.assetCount, 3)
        // a: photo + live video, b: photo + edited (adjustment data skipped), c: photo.
        XCTAssertEqual(manifest.files.count, 5)
        XCTAssertEqual(Set(manifest.files).count, 5)
        XCTAssertTrue(manifest.failed.isEmpty)
        XCTAssertTrue(manifest.files.allSatisfy { $0.hasPrefix("phone/snapshots/\(manifest.snapshotID.rawValue)/") })

        let s = try state()
        XCTAssertNil(s.active)
        XCTAssertEqual(s.lastCompleted?.uploadedFiles, 5)
        XCTAssertEqual(s.history.count, 1)
        XCTAssertFalse(s.retentionPending)
        XCTAssertTrue(queue.jobs.isEmpty, "every job acknowledged")
    }

    func testTempFilesRemovedAfterSnapshot() async throws {
        library.addPhoto("a")
        await runToCompletion()
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.url.path)
        XCTAssertEqual(files, ["state.json"])
    }

    func testEmptyLibraryProducesEmptySnapshot() async throws {
        let outcome = await engine().run()
        XCTAssertEqual(outcome, .completed)
        let manifest = try onlyManifest()
        XCTAssertEqual(manifest.files, [])
        XCTAssertEqual(manifest.assetCount, 0)
    }

    // MARK: Schedule

    func testNotDueDoesNotStartSnapshot() async throws {
        library.addPhoto("a")
        await runToCompletion()
        let created = queue.created.count
        clock.advance(by: 6 * day)
        let outcome = await engine().run()
        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(queue.created.count, created)
        XCTAssertNil(try state().active)
    }

    func testDueAfterIntervalStartsNewFullSnapshot() async throws {
        library.addPhoto("a")
        library.addPhoto("b")
        await runToCompletion()
        clock.advance(by: 7 * day)
        await runToCompletion()
        XCTAssertEqual(remote.manifests.count, 2)
        // Full backup: every photo uploaded again.
        XCTAssertEqual(queue.created.count, 4)
    }

    func testIntervalMeasuredFromSnapshotStartNotEnd() async throws {
        library.addPhoto("a")
        let start = clock.now()
        _ = await engine().run()
        clock.advance(by: 2 * day) // Uploads take two days.
        queue.completeAll()
        await runToCompletion()
        XCTAssertEqual(try state().lastCompleted?.startedAt, start)
        clock.set(start.addingTimeInterval(7 * day))
        _ = await engine().run()
        XCTAssertNotNil(try state().active, "due 7 days after the previous start")
    }

    func testBackupNowOverridesSchedule() async throws {
        library.addPhoto("a")
        await runToCompletion()
        clock.advance(by: 60)
        try engine().requestBackupNow()
        XCTAssertTrue(try state().forceBackupRequested)
        await runToCompletion()
        XCTAssertEqual(remote.manifests.count, 2)
        XCTAssertFalse(try state().forceBackupRequested)
    }

    func testBackupNowDuringActiveSnapshotDoesNotStartSecond() async throws {
        for i in 0..<20 { library.addPhoto("a\(i)") }
        _ = await engine().run()
        let active = try XCTUnwrap(state().active?.id)
        try engine().requestBackupNow()
        _ = await engine().run()
        XCTAssertEqual(try state().active?.id, active)
    }

    func testSnapshotIDsStayUniqueWithinSameSecond() async throws {
        await runToCompletion() // empty library: completes instantly
        try engine().requestBackupNow()
        await runToCompletion()
        XCTAssertEqual(remote.manifests.count, 2)
        let ids = try state().history.map(\.id)
        XCTAssertEqual(Set(ids).count, 2)
        XCTAssertGreaterThan(ids[0], ids[1])
    }

    // MARK: Job limit & batching

    func testRespectsJobLimitAcrossPasses() async throws {
        queue.jobLimit = 4
        for i in 0..<10 { library.addPhoto("a\(i)") }
        _ = await engine().run()
        XCTAssertEqual(queue.created.count, 4)
        // No completions yet: nothing more fits.
        _ = await engine().run()
        XCTAssertEqual(queue.created.count, 4)
        queue.completeAll()
        _ = await engine().run()
        XCTAssertEqual(queue.created.count, 8)
        await runToCompletion()
        XCTAssertEqual(try onlyManifest().files.count, 10)
    }

    func testAssetResourcesCanSpanBatches() async throws {
        queue.jobLimit = 3
        library.addPhoto("a", live: true, edited: true) // 3 uploadable resources
        library.addPhoto("b", live: true)             // 2
        _ = await engine().run()
        XCTAssertEqual(queue.created.count, 3)
        let cursor = try XCTUnwrap(state().active?.cursor)
        XCTAssertEqual(cursor, PlanCursor(asset: 1, resource: 0))
        await runToCompletion()
        XCTAssertEqual(try onlyManifest().files.count, 5)
    }

    func testPartialAssetCursorResumes() async throws {
        queue.jobLimit = 2
        library.addPhoto("a", live: true, edited: true) // 3 resources
        _ = await engine().run()
        XCTAssertEqual(try state().active?.cursor, PlanCursor(asset: 0, resource: 2))
        queue.completeAll()
        _ = await engine().run()
        XCTAssertEqual(queue.created.count, 3)
        XCTAssertEqual(Set(queue.created.map(\.resource.kind)), [.photo, .pairedVideo, .fullSizePhoto])
    }

    func testLimitExceededLeavesCursorUntouched() async throws {
        for i in 0..<3 { library.addPhoto("a\(i)") }
        queue.failNextCreateWithLimit = true
        let outcome = await engine().run()
        XCTAssertEqual(outcome, .processing)
        XCTAssertTrue(queue.created.isEmpty)
        let active = try XCTUnwrap(state().active, "snapshot start is kept")
        XCTAssertEqual(active.cursor, PlanCursor())
        XCTAssertTrue(active.inFlight.isEmpty)
        await runToCompletion()
        XCTAssertEqual(queue.created.count, 3)
        XCTAssertEqual(try onlyManifest().files.count, 3)
    }

    func testShouldStopPreventsJobCreation() async throws {
        library.addPhoto("a")
        let outcome = await engine().run(shouldStop: { true })
        XCTAssertEqual(outcome, .processing)
        XCTAssertTrue(queue.created.isEmpty)
        XCTAssertNotNil(try state().active, "snapshot started, work resumes next pass")
    }

    // MARK: Library changes

    func testPhotosAddedDuringSnapshotWaitForNextOne() async throws {
        queue.jobLimit = 1
        library.addPhoto("a")
        library.addPhoto("b")
        _ = await engine().run()
        library.addPhoto("new")
        await runToCompletion()
        XCTAssertEqual(try onlyManifest().assetCount, 2)
        XCTAssertFalse(queue.created.contains { $0.assetID == "new" })
    }

    func testAssetDeletedDuringSnapshotIsSkipped() async throws {
        queue.jobLimit = 1
        library.addPhoto("a")
        library.addPhoto("b")
        _ = await engine().run()
        library.remove("b")
        await runToCompletion()
        let manifest = try onlyManifest()
        XCTAssertEqual(manifest.skippedAssets, 1)
        XCTAssertEqual(manifest.files.count, 1)
        XCTAssertEqual(try state().lastCompleted?.skippedAssets, 1)
    }

    func testVideosExcludedWhenDisabled() async throws {
        settings.resources.includeVideos = false
        library.addPhoto("photo")
        library.addPhoto("movie", video: true)
        await runToCompletion()
        XCTAssertEqual(try onlyManifest().assetCount, 1)
        XCTAssertFalse(queue.created.contains { $0.resource.kind == .video })
    }

    func testLivePhotoMotionExcludedWhenDisabled() async throws {
        settings.resources.includeLivePhotoVideos = false
        library.addPhoto("a", live: true)
        await runToCompletion()
        XCTAssertEqual(queue.created.map(\.resource.kind), [.photo])
    }

    func testAssetWithNoUploadableResourcesAdvances() async throws {
        library.assets.append(.init(info: AssetInfo(localIdentifier: "odd", creationDate: nil),
                                    resources: [ResourceInfo(kind: .adjustmentData, originalFilename: "x.plist", index: 0)]))
        library.addPhoto("a")
        await runToCompletion()
        XCTAssertEqual(try onlyManifest().files.count, 1)
    }

    // MARK: Failures

    func testFailedUploadIsRetriedWithFreshURL() async throws {
        library.addPhoto("a")
        _ = await engine().run()
        let firstURL = try XCTUnwrap(queue.created.first?.destination.url)
        queue.completeAll(fail: { _ in true })
        clock.advance(by: 3600)
        _ = await engine().run()
        XCTAssertEqual(queue.created.count, 2)
        let secondURL = try XCTUnwrap(queue.created.last?.destination.url)
        XCTAssertEqual(firstURL.path, secondURL.path, "same object key")
        XCTAssertNotEqual(firstURL, secondURL, "re-signed with a new date")
        XCTAssertEqual(try state().active?.inFlight.values.first?.attempts, 1)
        await runToCompletion()
        let manifest = try onlyManifest()
        XCTAssertEqual(manifest.files.count, 1)
        XCTAssertTrue(manifest.failed.isEmpty)
    }

    func testGivesUpAfterMaxAttempts() async throws {
        settings.maxAttemptsPerFile = 3
        library.addPhoto("bad")
        library.addPhoto("good")
        await runToCompletion(fail: { $0.assetID == "bad" })
        let manifest = try onlyManifest()
        XCTAssertEqual(manifest.files.count, 1)
        XCTAssertEqual(manifest.failed.count, 1)
        XCTAssertTrue(manifest.failed[0].reason.contains("3 times"))
        XCTAssertEqual(queue.created.filter { $0.assetID == "bad" }.count, 3)
        XCTAssertEqual(try state().lastCompleted?.failedFiles, 1)
    }

    func testPermanentErrorGivesUpImmediately() async throws {
        library.addPhoto("a")
        _ = await engine().run()
        queue.completeAll(fail: { _ in true }, errorCode: -1100)
        await runToCompletion()
        XCTAssertEqual(queue.created.count, 1)
        XCTAssertEqual(try onlyManifest().failed.count, 1)
    }

    func testRetryOfDeletedAssetIsRecordedAsFailed() async throws {
        library.addPhoto("a")
        _ = await engine().run()
        queue.completeAll(fail: { _ in true })
        library.remove("a")
        await runToCompletion()
        let manifest = try onlyManifest()
        XCTAssertEqual(manifest.failed.map(\.reason), ["Asset was deleted"])
    }

    func testManifestUploadFailureKeepsSnapshotActiveAndRetries() async throws {
        library.addPhoto("a")
        _ = await engine().run()
        queue.completeAll()
        remote.failPutManifest = true
        let outcome = await engine().run()
        guard case .failure = outcome else { return XCTFail("expected failure, got \(outcome)") }
        XCTAssertNotNil(try state().active)
        XCTAssertNotNil(try state().lastError)
        remote.failPutManifest = false
        await runToCompletion()
        XCTAssertEqual(try onlyManifest().files.count, 1)
        XCTAssertNil(try state().lastError)
    }

    func testLostJobsAreRequeued() async throws {
        library.addPhoto("a")
        library.addPhoto("b")
        _ = await engine().run()
        queue.dropAll() // system forgot everything
        _ = await engine().run()
        XCTAssertEqual(queue.created.count, 4)
        await runToCompletion()
        XCTAssertEqual(try onlyManifest().files.count, 2)
    }

    func testForeignJobsAreAcknowledgedAndIgnored() async throws {
        library.addPhoto("a")
        _ = await engine().run()
        queue.injectForeignFinishedJob(url: URL(string: "https://elsewhere.example.com/x.jpg")!)
        queue.injectForeignFinishedJob(url: s3.objectURL(key: "phone/snapshots/19990101T000000Z/old.jpg"))
        await runToCompletion()
        XCTAssertEqual(try onlyManifest().files.count, 1)
        XCTAssertTrue(queue.acknowledged.contains { $0.hasPrefix("foreign-") })
    }

    func testDuplicateSuccessIsCountedOnce() async throws {
        // A crash between writing the uploaded log and saving state can log a
        // key twice; the manifest must still list it once.
        library.addPhoto("a")
        _ = await engine().run()
        let active = try XCTUnwrap(state().active)
        let key = try XCTUnwrap(active.inFlight.keys.first)
        try store.appendUploaded([key], for: active.id)
        await runToCompletion()
        XCTAssertEqual(try onlyManifest().files, [key])
    }

    // MARK: Retention

    func testRetentionKeepsLatestN() async throws {
        settings.keepLatest = 2
        library.addPhoto("a")
        for _ in 0..<4 {
            await runToCompletion()
            clock.advance(by: 7 * day)
        }
        XCTAssertEqual(remote.deleted.count, 2)
        XCTAssertEqual(remote.manifests.count, 2)
        let kept = remote.manifests.values.map(\.snapshotID).sorted()
        XCTAssertTrue(remote.deleted.allSatisfy { d in kept.allSatisfy { d < $0 } }, "oldest deleted")
    }

    func testRetentionDeletesAbandonedPartialSnapshots() async throws {
        remote.extraSnapshots = [RemoteSnapshot(id: SnapshotID("20200101T000000Z")!, isComplete: false)]
        library.addPhoto("a")
        await runToCompletion()
        XCTAssertEqual(remote.deleted, [SnapshotID("20200101T000000Z")!])
    }

    func testRetentionSpreadsLargeDeletesOverPasses() async throws {
        settings.keepLatest = 1
        settings.maxDeleteBatchesPerRun = 2
        let old = SnapshotID("20200101T000000Z")!
        remote.extraSnapshots = [RemoteSnapshot(id: old, isComplete: true)]
        remote.batchesPerSnapshot[old] = 5
        library.addPhoto("a")
        let outcomes = await runToCompletion()
        XCTAssertEqual(remote.deleted, [old])
        XCTAssertGreaterThanOrEqual(outcomes.filter { $0 == .processing }.count, 3)
        XCTAssertFalse(try state().retentionPending)
    }

    func testRetentionListFailureIsRetriedLater() async throws {
        remote.failList = true
        library.addPhoto("a")
        _ = await engine().run()
        queue.completeAll()
        let outcome = await engine().run()
        guard case .failure = outcome else { return XCTFail("expected failure, got \(outcome)") }
        XCTAssertEqual(remote.manifests.count, 1, "manifest was written before retention failed")
        XCTAssertTrue(try state().retentionPending)
        remote.failList = false
        let retried = await engine().run()
        XCTAssertEqual(retried, .completed)
        XCTAssertFalse(try state().retentionPending)
    }

    func testRequestRetentionRunsWithoutNewSnapshot() async throws {
        settings.keepLatest = 3
        library.addPhoto("a")
        for _ in 0..<3 {
            await runToCompletion()
            clock.advance(by: 7 * day)
        }
        XCTAssertEqual(remote.manifests.count, 3)
        clock.advance(by: -7 * day) // not due
        settings.keepLatest = 1
        try engine().requestRetention()
        await runToCompletion()
        XCTAssertEqual(remote.manifests.count, 1)
    }

    // MARK: Concurrency & persistence

    func testLockHeldElsewhereSkipsPass() async throws {
        library.addPhoto("a")
        let lockURL = dir.url.appendingPathComponent("engine.lock")
        let other = FileLock(url: lockURL)
        XCTAssertTrue(other.tryLock())
        let outcome = await engine(lock: FileLock(url: lockURL)).run()
        XCTAssertEqual(outcome, .processing)
        XCTAssertTrue(queue.created.isEmpty)
        XCTAssertNil(try state().lastRunAt)
        other.unlock()
        let second = await engine(lock: FileLock(url: lockURL)).run()
        XCTAssertEqual(second, .processing)
        XCTAssertEqual(queue.created.count, 1)
    }

    func testStateSurvivesProcessRestart() async throws {
        queue.jobLimit = 2
        for i in 0..<5 { library.addPhoto("a\(i)") }
        _ = await engine().run()
        // A brand-new engine (extension relaunched) picks up where it left off.
        queue.completeAll()
        let fresh = BackupEngine(settings: settings, credentials: creds, library: library, queue: queue, remote: remote,
                                 store: try FileStateStore(directory: dir.url), clock: clock,
                                 timeZone: TimeZone(identifier: "UTC")!, transport: MockTransport())
        _ = await fresh.run()
        XCTAssertEqual(try state().active?.uploadedCount, 2)
        XCTAssertEqual(queue.created.count, 4)
        XCTAssertEqual(library.allAssetIDsCalls, 1, "plan is not rebuilt")
    }
}
