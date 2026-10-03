import XCTest
@testable import ShoeboxCore

final class ScheduleTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    let day: TimeInterval = 86_400

    func testNeverBackedUpIsDue() {
        XCTAssertTrue(BackupSchedule(intervalDays: 7).isDue(lastCompletedStart: nil, now: t0))
        XCTAssertNil(BackupSchedule(intervalDays: 7).nextDue(lastCompletedStart: nil))
    }

    func testDueExactlyAtInterval() {
        let s = BackupSchedule(intervalDays: 7)
        XCTAssertFalse(s.isDue(lastCompletedStart: t0, now: t0.addingTimeInterval(7 * day - 1)))
        XCTAssertTrue(s.isDue(lastCompletedStart: t0, now: t0.addingTimeInterval(7 * day)))
        XCTAssertTrue(s.isDue(lastCompletedStart: t0, now: t0.addingTimeInterval(30 * day)))
        XCTAssertEqual(s.nextDue(lastCompletedStart: t0), t0.addingTimeInterval(7 * day))
    }

    func testDailyInterval() {
        let s = BackupSchedule(intervalDays: 1)
        XCTAssertFalse(s.isDue(lastCompletedStart: t0, now: t0.addingTimeInterval(23 * 3600)))
        XCTAssertTrue(s.isDue(lastCompletedStart: t0, now: t0.addingTimeInterval(day)))
    }

    func testIntervalIsClamped() {
        XCTAssertEqual(BackupSchedule(intervalDays: 0).intervalDays, 1)
        XCTAssertEqual(BackupSchedule(intervalDays: -3).intervalDays, 1)
        XCTAssertEqual(BackupSchedule(intervalDays: 10_000).intervalDays, 365)
    }

    func testClockMovedBackwards() {
        let s = BackupSchedule(intervalDays: 7)
        // Last backup "in the future" by a few hours: small skew, not due.
        XCTAssertFalse(s.isDue(lastCompletedStart: t0.addingTimeInterval(3600), now: t0))
        // More than a day in the future: the clock was wrong, back up.
        XCTAssertTrue(s.isDue(lastCompletedStart: t0.addingTimeInterval(2 * day), now: t0))
    }
}

final class RetentionTests: XCTestCase {
    func id(_ day: Int) -> SnapshotID { SnapshotID(String(format: "202601%02dT000000Z", day))! }
    func done(_ day: Int) -> RemoteSnapshot { RemoteSnapshot(id: id(day), isComplete: true) }
    func partial(_ day: Int) -> RemoteSnapshot { RemoteSnapshot(id: id(day), isComplete: false) }

    func testKeepsLatestN() {
        let r = RetentionPolicy(keepLatest: 2)
        XCTAssertEqual(r.snapshotsToDelete([done(1), done(2), done(3), done(4)], active: nil), [id(1), id(2)])
    }

    func testNothingToDeleteWhenUnderLimit() {
        let r = RetentionPolicy(keepLatest: 5)
        XCTAssertEqual(r.snapshotsToDelete([done(1), done(2)], active: nil), [])
        XCTAssertEqual(r.snapshotsToDelete([], active: nil), [])
    }

    func testUnsortedInput() {
        let r = RetentionPolicy(keepLatest: 1)
        XCTAssertEqual(r.snapshotsToDelete([done(3), done(1), done(2)], active: nil), [id(1), id(2)])
    }

    func testActiveSnapshotIsNeverDeletedOrCounted() {
        let r = RetentionPolicy(keepLatest: 1)
        XCTAssertEqual(r.snapshotsToDelete([done(1), done(2), partial(3)], active: id(3)), [id(1)])
    }

    func testAbandonedPartialOlderThanNewestCompleteIsDeleted() {
        let r = RetentionPolicy(keepLatest: 3)
        XCTAssertEqual(r.snapshotsToDelete([partial(1), done(2)], active: nil), [id(1)])
    }

    func testPartialNewerThanAllCompleteIsKept() {
        // It might be the only copy of recent photos; wait for a newer complete one.
        let r = RetentionPolicy(keepLatest: 3)
        XCTAssertEqual(r.snapshotsToDelete([done(1), partial(2)], active: nil), [])
    }

    func testPartialsKeptWhenNoCompleteSnapshotExists() {
        let r = RetentionPolicy(keepLatest: 1)
        XCTAssertEqual(r.snapshotsToDelete([partial(1), partial(2)], active: nil), [])
    }

    func testPartialsDoNotCountTowardKeep() {
        let r = RetentionPolicy(keepLatest: 2)
        let result = r.snapshotsToDelete([done(1), partial(2), done(3), partial(4), done(5)], active: nil)
        // Keeps 5 and 3; 1 is beyond the limit; 2 and 4 are abandoned partials
        // older than the newest complete snapshot.
        XCTAssertEqual(result, [id(1), id(2), id(4)])
    }

    func testKeepIsClamped() {
        XCTAssertEqual(RetentionPolicy(keepLatest: 0).keepLatest, 1)
        XCTAssertEqual(RetentionPolicy(keepLatest: 1000).keepLatest, 100)
        // keep 0 would delete everything; clamped to 1 keeps the newest.
        XCTAssertEqual(RetentionPolicy(keepLatest: 0).snapshotsToDelete([done(1), done(2)], active: nil), [id(1)])
    }
}

final class ResourcePolicyTests: XCTestCase {
    let all: [ResourceInfo] = ResourceKind.allCases.enumerated().map {
        ResourceInfo(kind: $0.element, originalFilename: "f\($0.offset)", index: $0.offset)
    }

    func kinds(_ policy: ResourcePolicy) -> Set<ResourceKind> {
        Set(policy.select(all).map(\.kind))
    }

    func testDefaultKeepsEverythingUserVisible() {
        XCTAssertEqual(kinds(ResourcePolicy()), [.photo, .video, .audio, .alternatePhoto, .fullSizePhoto,
                                                  .fullSizeVideo, .pairedVideo, .fullSizePairedVideo])
    }

    func testInternalResourcesNeverUploaded() {
        let k = kinds(ResourcePolicy())
        for kind in [ResourceKind.adjustmentData, .adjustmentBasePhoto, .adjustmentBaseVideo, .adjustmentBasePairedVideo, .photoProxy, .other] {
            XCTAssertFalse(k.contains(kind), kind.rawValue)
        }
    }

    func testExcludeVideos() {
        let k = kinds(ResourcePolicy(includeVideos: false))
        XCTAssertFalse(k.contains(.video))
        XCTAssertFalse(k.contains(.fullSizeVideo))
        XCTAssertTrue(k.contains(.pairedVideo), "Live Photo motion is controlled separately")
    }

    func testExcludeLivePhotoVideo() {
        let k = kinds(ResourcePolicy(includeLivePhotoVideos: false))
        XCTAssertFalse(k.contains(.pairedVideo))
        XCTAssertFalse(k.contains(.fullSizePairedVideo))
        XCTAssertTrue(k.contains(.video))
    }

    func testExcludeEdits() {
        let k = kinds(ResourcePolicy(includeEdits: false))
        XCTAssertFalse(k.contains(.fullSizePhoto))
        XCTAssertFalse(k.contains(.fullSizeVideo))
        XCTAssertFalse(k.contains(.fullSizePairedVideo))
        XCTAssertTrue(k.contains(.photo))
    }

    func testPreservesOrder() {
        let selected = ResourcePolicy().select(all)
        XCTAssertEqual(selected.map(\.index), selected.map(\.index).sorted())
    }
}

final class FailureClassifierTests: XCTestCase {
    func testRetriesUntilMaxAttempts() {
        let c = FailureClassifier(maxAttempts: 3)
        XCTAssertEqual(c.decide(errorDomain: "NSURLErrorDomain", errorCode: -1001, attempts: 1), .retry)
        XCTAssertEqual(c.decide(errorDomain: "NSURLErrorDomain", errorCode: -1001, attempts: 2), .retry)
        guard case .giveUp(let reason) = c.decide(errorDomain: "NSURLErrorDomain", errorCode: -1001, attempts: 3) else {
            return XCTFail("should give up")
        }
        XCTAssertTrue(reason.contains("3 times"))
        XCTAssertTrue(reason.contains("-1001"))
    }

    func testPermanentErrorsGiveUpImmediately() {
        let c = FailureClassifier(maxAttempts: 10)
        for code in [-1100, -1102, -1103] {
            XCTAssertNotEqual(c.decide(errorDomain: "NSURLErrorDomain", errorCode: code, attempts: 1), .retry, "\(code)")
        }
    }

    func testUnknownErrorIsRetried() {
        let c = FailureClassifier(maxAttempts: 2)
        XCTAssertEqual(c.decide(errorDomain: nil, errorCode: nil, attempts: 1), .retry)
        XCTAssertEqual(c.decide(errorDomain: "PHPhotosErrorDomain", errorCode: 3300, attempts: 1), .retry)
    }

    func testMaxAttemptsAtLeastOne() {
        XCTAssertEqual(FailureClassifier(maxAttempts: 0).maxAttempts, 1)
    }
}

final class SettingsTests: XCTestCase {
    let s3 = S3Config(endpoint: URL(string: "https://a.r2.cloudflarestorage.com")!, region: "auto", bucket: "photos")

    func testDefaults() {
        let s = BackupSettings(s3: s3)
        XCTAssertEqual(s.intervalDays, 7)
        XCTAssertEqual(s.keepLatest, 3)
        XCTAssertEqual(s.presignSeconds, 604_800)
        XCTAssertEqual(s.validate(), [])
    }

    func testMissingStorage() {
        XCTAssertEqual(BackupSettings().validate(), ["Storage is not configured"])
    }

    func testRangeValidation() {
        var s = BackupSettings(s3: s3)
        s.intervalDays = 0
        s.keepLatest = 0
        s.presignSeconds = 10
        XCTAssertEqual(s.validate().count, 3)
    }

    func testSettingsCodableRoundTrip() throws {
        var s = BackupSettings(s3: s3, intervalDays: 3, keepLatest: 5)
        s.resources.includeVideos = false
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(BackupSettings.self, from: data), s)
    }
}
