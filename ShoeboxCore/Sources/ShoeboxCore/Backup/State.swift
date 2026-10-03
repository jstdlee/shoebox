import Foundation

/// Everything the engine remembers between runs. Small; the big lists (asset
/// plan, uploaded keys) live in separate files.
public struct EngineState: Codable, Equatable, Sendable {
    public var lastCompleted: SnapshotSummary?
    public var active: ActiveSnapshot?
    public var history: [SnapshotSummary] = []
    public var forceBackupRequested = false
    /// Set after a snapshot finishes or settings change; cleared once retention
    /// has fully run.
    public var retentionPending = false
    public var lastRunAt: Date?
    public var lastError: String?

    public init() {}

    public static let historyLimit = 30

    mutating func record(_ summary: SnapshotSummary) {
        lastCompleted = summary
        history.insert(summary, at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
    }
}

public struct SnapshotSummary: Codable, Equatable, Sendable {
    public var id: SnapshotID
    public var startedAt: Date
    public var completedAt: Date
    public var assetCount: Int
    public var uploadedFiles: Int
    public var failedFiles: Int
    public var skippedAssets: Int

    public init(id: SnapshotID, startedAt: Date, completedAt: Date, assetCount: Int,
                uploadedFiles: Int, failedFiles: Int, skippedAssets: Int) {
        self.id = id
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.assetCount = assetCount
        self.uploadedFiles = uploadedFiles
        self.failedFiles = failedFiles
        self.skippedAssets = skippedAssets
    }
}

public struct PlanCursor: Codable, Equatable, Sendable {
    /// Index into the asset plan.
    public var asset: Int = 0
    /// Index into the selected resources of that asset.
    public var resource: Int = 0

    public init(asset: Int = 0, resource: Int = 0) {
        self.asset = asset
        self.resource = resource
    }
}

public struct InFlightJob: Codable, Equatable, Sendable {
    public var assetID: String
    public var resource: ResourceInfo
    public var attempts: Int

    public init(assetID: String, resource: ResourceInfo, attempts: Int) {
        self.assetID = assetID
        self.resource = resource
        self.attempts = attempts
    }
}

public struct PendingRetry: Codable, Equatable, Sendable {
    public var key: String
    public var assetID: String
    public var resource: ResourceInfo
    /// Failures so far.
    public var attempts: Int
}

public struct FailedFile: Codable, Equatable, Sendable {
    public var key: String
    public var reason: String
}

public struct ActiveSnapshot: Codable, Equatable, Sendable {
    public var id: SnapshotID
    public var startedAt: Date
    public var totalAssets: Int
    public var cursor = PlanCursor()
    /// Keyed by object key.
    public var inFlight: [String: InFlightJob] = [:]
    public var retries: [PendingRetry] = []
    public var uploadedCount = 0
    public var skippedAssets = 0
    public var failed: [FailedFile] = []

    public init(id: SnapshotID, startedAt: Date, totalAssets: Int) {
        self.id = id
        self.startedAt = startedAt
        self.totalAssets = totalAssets
    }

    public var planExhausted: Bool { cursor.asset >= totalAssets }
    public var isFinished: Bool { planExhausted && inFlight.isEmpty && retries.isEmpty }
}

/// What gets written next to the photos when a snapshot completes. Its
/// presence marks the snapshot as complete.
public struct Manifest: Codable, Equatable, Sendable {
    public var formatVersion = 1
    public var snapshotID: SnapshotID
    public var startedAt: Date
    public var completedAt: Date
    public var assetCount: Int
    public var skippedAssets: Int
    public var files: [String]
    public var failed: [FailedFile]

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> Manifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Manifest.self, from: data)
    }
}
