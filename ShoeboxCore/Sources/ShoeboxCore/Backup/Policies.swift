import Foundation

/// "Back up every N days".
public struct BackupSchedule: Equatable, Sendable {
    public static let dayRange = 1...365
    public var intervalDays: Int

    public init(intervalDays: Int) {
        self.intervalDays = min(max(intervalDays, Self.dayRange.lowerBound), Self.dayRange.upperBound)
    }

    public var interval: TimeInterval { TimeInterval(intervalDays) * 86_400 }

    /// When the next snapshot should start, measured from the start of the
    /// last completed one. nil = never backed up = due now.
    public func nextDue(lastCompletedStart: Date?) -> Date? {
        lastCompletedStart.map { $0.addingTimeInterval(interval) }
    }

    public func isDue(lastCompletedStart: Date?, now: Date) -> Bool {
        guard let last = lastCompletedStart else { return true }
        // Clock moved backwards by more than a day: don't wait for the future.
        if last.timeIntervalSince(now) > 86_400 { return true }
        return now >= last.addingTimeInterval(interval)
    }
}

public struct RemoteSnapshot: Equatable, Sendable {
    public var id: SnapshotID
    /// Has a manifest.json, i.e. finished uploading.
    public var isComplete: Bool

    public init(id: SnapshotID, isComplete: Bool) {
        self.id = id
        self.isComplete = isComplete
    }
}

/// "Keep the latest X backups".
public struct RetentionPolicy: Equatable, Sendable {
    public static let keepRange = 1...100
    public var keepLatest: Int

    public init(keepLatest: Int) {
        self.keepLatest = min(max(keepLatest, Self.keepRange.lowerBound), Self.keepRange.upperBound)
    }

    /// Rules:
    /// - Only complete snapshots count toward `keepLatest`; the newest ones are kept.
    /// - The active (in-progress) snapshot is never deleted.
    /// - An incomplete, inactive snapshot is abandoned. It is deleted only when
    ///   a newer complete snapshot exists, so partial data is never the only copy.
    /// Result is oldest first.
    public func snapshotsToDelete(_ snapshots: [RemoteSnapshot], active: SnapshotID?) -> [SnapshotID] {
        let candidates = snapshots.filter { $0.id != active }
        let complete = candidates.filter(\.isComplete).map(\.id).sorted(by: >)
        var doomed = Set(complete.dropFirst(keepLatest))
        if let newestComplete = complete.first {
            for s in candidates where !s.isComplete && s.id < newestComplete {
                doomed.insert(s.id)
            }
        }
        return doomed.sorted()
    }
}

/// What to do with a failed upload job.
public enum FailureDecision: Equatable, Sendable {
    case retry
    case giveUp(reason: String)
}

public struct FailureClassifier: Sendable {
    public var maxAttempts: Int

    public init(maxAttempts: Int) {
        self.maxAttempts = max(1, maxAttempts)
    }

    /// URL error codes that will not get better by trying again.
    static let permanentURLErrorCodes: Set<Int> = [
        -1100, // fileDoesNotExist
        -1102, // noPermissionsToReadFile
        -1103, // dataLengthExceedsMaximum
    ]

    /// `attempts` counts the failure being classified.
    public func decide(errorDomain: String?, errorCode: Int?, attempts: Int) -> FailureDecision {
        let description = [errorDomain, errorCode.map(String.init)].compactMap { $0 }.joined(separator: " ")
        if errorDomain == "NSURLErrorDomain", let code = errorCode, Self.permanentURLErrorCodes.contains(code) {
            return .giveUp(reason: "Permanent error \(description)")
        }
        if attempts >= maxAttempts {
            return .giveUp(reason: "Failed \(attempts) times" + (description.isEmpty ? "" : " (last: \(description))"))
        }
        return .retry
    }
}
