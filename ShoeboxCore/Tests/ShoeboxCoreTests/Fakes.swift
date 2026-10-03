import Foundation
@testable import ShoeboxCore

/// Scripted HTTP transport: records requests, answers from a handler.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [HTTPRequest] = []
    var handler: (HTTPRequest) throws -> HTTPResponse

    init(handler: @escaping (HTTPRequest) throws -> HTTPResponse = { _ in HTTPResponse(status: 200) }) {
        self.handler = handler
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.lock()
        requests.append(request)
        let handler = self.handler
        lock.unlock()
        return try handler(request)
    }
}

final class FakeLibrary: PhotoLibrarySource {
    struct Asset {
        var info: AssetInfo
        var resources: [ResourceInfo]
    }

    var assets: [Asset] = []
    var allAssetIDsCalls = 0
    /// Simulates missing photo permission.
    var denyAccess = false

    /// Adds a photo asset with one resource (or a Live Photo with two).
    @discardableResult
    func addPhoto(_ id: String, date: Date = Date(timeIntervalSince1970: 1_780_000_000), live: Bool = false,
                  video: Bool = false, edited: Bool = false) -> String {
        var resources: [ResourceInfo] = []
        let base = String(id.prefix(8))
        if video {
            resources.append(ResourceInfo(kind: .video, originalFilename: "\(base).MOV", index: resources.count))
        } else {
            resources.append(ResourceInfo(kind: .photo, originalFilename: "\(base).HEIC", index: resources.count))
        }
        if live { resources.append(ResourceInfo(kind: .pairedVideo, originalFilename: "\(base).MOV", index: resources.count)) }
        if edited {
            resources.append(ResourceInfo(kind: .adjustmentData, originalFilename: "Adjustments.plist", index: resources.count))
            resources.append(ResourceInfo(kind: .fullSizePhoto, originalFilename: "FullSizeRender.heic", index: resources.count))
        }
        assets.append(Asset(info: AssetInfo(localIdentifier: id, creationDate: date), resources: resources))
        return id
    }

    func remove(_ id: String) {
        assets.removeAll { $0.info.localIdentifier == id }
    }

    func allAssetIDs(policy: ResourcePolicy) throws -> [String] {
        allAssetIDsCalls += 1
        if denyAccess { throw NSError(domain: "FakeLibrary", code: 1, userInfo: [NSLocalizedDescriptionKey: "No photo access"]) }
        return assets
            .filter { asset in policy.includeVideos || !asset.resources.contains { $0.kind == .video } }
            .map(\.info.localIdentifier)
    }

    func asset(id: String) -> AssetInfo? {
        assets.first { $0.info.localIdentifier == id }?.info
    }

    func resources(assetID: String) -> [ResourceInfo] {
        assets.first { $0.info.localIdentifier == assetID }?.resources ?? []
    }
}

/// Simulates PHAssetResourceUploadJob bookkeeping: a job limit that counts
/// every unacknowledged job, jobs that move from pending to succeeded/failed
/// when the test says so, atomic creation.
final class FakeJobQueue: UploadJobQueue {
    struct Job {
        var id: String
        var spec: NewUploadJob
        var state: UploadJobState
        var errorCode: Int?
    }

    var jobLimit: Int
    private(set) var jobs: [Job] = []
    private(set) var created: [NewUploadJob] = []
    private(set) var acknowledged: [String] = []
    private var nextID = 1
    /// Force the next create() to throw limitExceeded even if there is room.
    var failNextCreateWithLimit = false
    var createCalls = 0

    init(jobLimit: Int = 10) {
        self.jobLimit = jobLimit
    }

    func finishedJobs() throws -> [UploadJobInfo] {
        jobs.filter { $0.state == .succeeded || $0.state == .failed }.map(info)
    }

    /// Simulates iOS 26.1–26.4, where pending jobs can't be counted.
    var canCountProcessing = true

    func processingJobCount() throws -> Int? {
        guard canCountProcessing else { return nil }
        return jobs.filter { $0.state == .registered || $0.state == .pending }.count
    }

    func acknowledge(jobIDs: [String]) throws {
        acknowledged += jobIDs
        jobs.removeAll { jobIDs.contains($0.id) }
    }

    func create(_ newJobs: [NewUploadJob]) throws {
        createCalls += 1
        if failNextCreateWithLimit {
            failNextCreateWithLimit = false
            throw UploadJobQueueError.limitExceeded
        }
        guard jobs.count + newJobs.count <= jobLimit else { throw UploadJobQueueError.limitExceeded }
        for spec in newJobs {
            jobs.append(Job(id: "job-\(nextID)", spec: spec, state: .pending))
            nextID += 1
            created.append(spec)
        }
    }

    // MARK: Test controls

    var pendingKeys: [String] {
        jobs.filter { $0.state == .pending }.map { key(of: $0) }
    }

    func key(of job: Job) -> String {
        job.spec.destination.url.path
    }

    /// Complete every pending job, failing the ones `fail` returns true for.
    func completeAll(fail: (NewUploadJob) -> Bool = { _ in false }, errorCode: Int = -1001) {
        for i in jobs.indices where jobs[i].state == .pending {
            if fail(jobs[i].spec) {
                jobs[i].state = .failed
                jobs[i].errorCode = errorCode
            } else {
                jobs[i].state = .succeeded
            }
        }
    }

    /// Simulates the system losing all jobs (e.g. extension disabled/re-enabled).
    func dropAll() { jobs.removeAll() }

    /// Inject a job the engine did not create.
    func injectForeignFinishedJob(url: URL) {
        let spec = NewUploadJob(assetID: "?", resource: ResourceInfo(kind: .photo, originalFilename: "x", index: 0),
                                destination: HTTPRequest(method: "PUT", url: url))
        jobs.append(Job(id: "foreign-\(nextID)", spec: spec, state: .succeeded))
        nextID += 1
    }

    private func info(_ job: Job) -> UploadJobInfo {
        UploadJobInfo(id: job.id, destination: job.spec.destination.url, state: job.state,
                      errorDomain: job.errorCode == nil ? nil : "NSURLErrorDomain", errorCode: job.errorCode)
    }
}

final class FakeSnapshotStore: SnapshotStore {
    var manifests: [String: Manifest] = [:]
    /// Snapshots present in the bucket (besides ones with a manifest).
    var extraSnapshots: [RemoteSnapshot] = []
    var deleted: [SnapshotID] = []
    var failPutManifest = false
    var failList = false
    /// Batches needed to delete each snapshot (default 1).
    var batchesPerSnapshot: [SnapshotID: Int] = [:]
    private var batchesDone: [SnapshotID: Int] = [:]
    let layout: KeyLayout

    init(layout: KeyLayout) {
        self.layout = layout
    }

    func putManifest(_ manifest: Manifest, key: String) async throws {
        if failPutManifest { throw S3Error(status: 500, code: "InternalError", message: "boom") }
        manifests[key] = manifest
    }

    func listSnapshots() async throws -> [RemoteSnapshot] {
        if failList { throw S3Error(status: 503, code: "SlowDown", message: "") }
        var all = extraSnapshots.filter { !deleted.contains($0.id) }
        for manifest in manifests.values where !deleted.contains(manifest.snapshotID) {
            all.removeAll { $0.id == manifest.snapshotID }
            all.append(RemoteSnapshot(id: manifest.snapshotID, isComplete: true))
        }
        return all.sorted { $0.id < $1.id }
    }

    func deleteSnapshot(_ id: SnapshotID, maxBatches: Int) async throws -> (done: Bool, batchesUsed: Int) {
        let needed = batchesPerSnapshot[id, default: 1] - batchesDone[id, default: 0]
        let used = min(needed, maxBatches)
        batchesDone[id, default: 0] += used
        if used == needed {
            deleted.append(id)
            manifests = manifests.filter { $0.value.snapshotID != id }
            return (true, used)
        }
        return (false, used)
    }
}

final class TempDir {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("shoebox-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
