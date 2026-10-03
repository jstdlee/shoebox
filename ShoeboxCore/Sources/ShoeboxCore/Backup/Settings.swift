import Foundation

/// User settings shared by the app and the upload extension (App Group
/// UserDefaults). Credentials are stored separately in the Keychain.
public struct BackupSettings: Codable, Equatable, Sendable {
    public var s3: S3Config?
    public var intervalDays: Int
    public var keepLatest: Int
    public var resources: ResourcePolicy
    /// How long each presigned upload URL stays valid. Jobs that wait longer
    /// fail with 403 and are re-created with a fresh URL.
    public var presignSeconds: Int
    public var maxAttemptsPerFile: Int
    /// Upper bound of DeleteObjects calls per engine run, so retention of a
    /// huge snapshot is spread over several runs.
    public var maxDeleteBatchesPerRun: Int

    public init(s3: S3Config? = nil, intervalDays: Int = 7, keepLatest: Int = 3,
                resources: ResourcePolicy = ResourcePolicy(),
                presignSeconds: Int = SigV4Signer.maxPresignSeconds,
                maxAttemptsPerFile: Int = 4, maxDeleteBatchesPerRun: Int = 20) {
        self.s3 = s3
        self.intervalDays = intervalDays
        self.keepLatest = keepLatest
        self.resources = resources
        self.presignSeconds = presignSeconds
        self.maxAttemptsPerFile = maxAttemptsPerFile
        self.maxDeleteBatchesPerRun = maxDeleteBatchesPerRun
    }

    public var schedule: BackupSchedule { BackupSchedule(intervalDays: intervalDays) }
    public var retention: RetentionPolicy { RetentionPolicy(keepLatest: keepLatest) }

    public func validate() -> [String] {
        var problems: [String] = []
        if let s3 { problems += s3.validate().map(\.rawValue) } else { problems.append("Storage is not configured") }
        if !BackupSchedule.dayRange.contains(intervalDays) { problems.append("Interval must be 1–365 days") }
        if !RetentionPolicy.keepRange.contains(keepLatest) { problems.append("Keep latest must be 1–100") }
        if !(60...SigV4Signer.maxPresignSeconds).contains(presignSeconds) { problems.append("Presign lifetime must be 1 minute to 7 days") }
        return problems
    }
}
