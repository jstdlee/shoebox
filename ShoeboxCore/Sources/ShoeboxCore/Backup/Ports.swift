import Foundation

/// The photo library, as the engine sees it. Implemented with PhotoKit on iOS
/// and with fakes in tests.
public protocol PhotoLibrarySource: AnyObject {
    /// Every asset to include in a new snapshot, oldest first.
    func allAssetIDs(policy: ResourcePolicy) throws -> [String]
    /// nil if the asset was deleted.
    func asset(id: String) -> AssetInfo?
    func resources(assetID: String) -> [ResourceInfo]
}

public enum UploadJobState: String, Codable, Sendable {
    case registered, pending, succeeded, failed, cancelled
}

/// A PHAssetResourceUploadJob, flattened.
public struct UploadJobInfo: Equatable, Sendable {
    public var id: String
    public var destination: URL?
    public var state: UploadJobState
    public var errorDomain: String?
    public var errorCode: Int?

    public init(id: String, destination: URL?, state: UploadJobState, errorDomain: String? = nil, errorCode: Int? = nil) {
        self.id = id
        self.destination = destination
        self.state = state
        self.errorDomain = errorDomain
        self.errorCode = errorCode
    }
}

public struct NewUploadJob: Equatable, Sendable {
    public var assetID: String
    public var resource: ResourceInfo
    public var destination: HTTPRequest

    public init(assetID: String, resource: ResourceInfo, destination: HTTPRequest) {
        self.assetID = assetID
        self.resource = resource
        self.destination = destination
    }
}

public enum UploadJobQueueError: Error, Equatable {
    /// PHPhotosError.limitExceeded
    case limitExceeded
}

/// PhotoKit's background upload job system.
public protocol UploadJobQueue: AnyObject {
    /// PHAssetResourceUploadJob.jobLimit — unacknowledged jobs, in flight or finished.
    var jobLimit: Int { get }
    /// Jobs that finished (succeeded or failed) and wait for acknowledgement.
    func finishedJobs() throws -> [UploadJobInfo]
    /// Registered or pending jobs.
    func processingJobCount() throws -> Int
    func acknowledge(jobIDs: [String]) throws
    /// Creates all jobs atomically (one change block). Throws
    /// `.limitExceeded` if they don't fit. A job whose resource vanished may be
    /// skipped silently; the engine notices it never ran and retries/fails it.
    func create(_ jobs: [NewUploadJob]) throws
}

/// Snapshot-level operations on the bucket.
public protocol SnapshotStore: AnyObject {
    func putManifest(_ manifest: Manifest, key: String) async throws
    func listSnapshots() async throws -> [RemoteSnapshot]
    /// Deletes up to `maxBatches` × 1000 objects of a snapshot. Returns true
    /// when nothing is left under its prefix.
    func deleteSnapshot(_ id: SnapshotID, maxBatches: Int) async throws -> (done: Bool, batchesUsed: Int)
}

/// SnapshotStore backed by S3Client.
public final class S3SnapshotStore: SnapshotStore {
    public let client: S3Client
    public let layout: KeyLayout

    public init(client: S3Client, layout: KeyLayout) {
        self.client = client
        self.layout = layout
    }

    public func putManifest(_ manifest: Manifest, key: String) async throws {
        try await client.putObject(key: key, body: manifest.encoded(), contentType: "application/json")
    }

    public func listSnapshots() async throws -> [RemoteSnapshot] {
        var prefixes: [String] = []
        var token: String?
        repeat {
            let page = try await client.listObjects(prefix: layout.snapshotsRoot, delimiter: "/", continuationToken: token)
            prefixes += page.commonPrefixes
            token = page.isTruncated ? page.nextContinuationToken : nil
        } while token != nil

        var result: [RemoteSnapshot] = []
        for prefix in prefixes {
            guard let id = layout.snapshotID(fromCommonPrefix: prefix) else { continue }
            let complete = try await client.headObject(key: layout.manifestKey(id))
            result.append(RemoteSnapshot(id: id, isComplete: complete))
        }
        return result.sorted { $0.id < $1.id }
    }

    public func deleteSnapshot(_ id: SnapshotID, maxBatches: Int) async throws -> (done: Bool, batchesUsed: Int) {
        let prefix = layout.snapshotPrefix(id)
        let manifest = layout.manifestKey(id)
        var used = 0
        while used < maxBatches {
            let page = try await client.listObjects(prefix: prefix, maxKeys: S3Client.maxDeleteBatch)
            // Delete the manifest last so a half-deleted snapshot reads as
            // incomplete, never as a complete-but-broken backup.
            var keys = page.objects.map(\.key)
            let onlyManifestLeft = keys == [manifest]
            if !onlyManifestLeft { keys.removeAll { $0 == manifest } }
            if keys.isEmpty { return (true, used) }
            let result = try await client.deleteObjects(keys: keys)
            used += 1
            if let failure = result.errors.first {
                throw S3Error(status: 200, code: failure.code, message: "Delete \(failure.key): \(failure.message)")
            }
            if onlyManifestLeft { return (true, used) }
        }
        let remaining = try await client.listObjects(prefix: prefix, maxKeys: 1)
        return (remaining.objects.isEmpty, used)
    }
}
