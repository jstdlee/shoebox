import Foundation
import Photos
import ShoeboxCore

/// PhotoLibrarySource over PHAsset / PHAssetResource.
final class PhotoKitLibrarySource: PhotoLibrarySource {
    /// Small cache: the engine asks for the same asset several times per pass.
    private var assetCache: [String: PHAsset] = [:]

    struct NoFullPhotoAccess: Error, CustomStringConvertible {
        var description: String { "Shoebox needs Full Access to the photo library" }
    }

    func allAssetIDs(policy: ResourcePolicy) throws -> [String] {
        // Without full access PhotoKit returns an empty or partial library. A
        // snapshot built from that would look complete and let retention
        // delete real backups, so refuse to start one.
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw NoFullPhotoAccess()
        }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.includeHiddenAssets = true
        if !policy.includeVideos {
            options.predicate = NSPredicate(format: "mediaType != %d", PHAssetMediaType.video.rawValue)
        }
        let result = PHAsset.fetchAssets(with: options)
        var ids: [String] = []
        ids.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in ids.append(asset.localIdentifier) }
        return ids
    }

    func asset(id: String) -> AssetInfo? {
        fetch(id).map { AssetInfo(localIdentifier: $0.localIdentifier, creationDate: $0.creationDate) }
    }

    func resources(assetID: String) -> [ResourceInfo] {
        guard let asset = fetch(assetID) else { return [] }
        return PHAssetResource.assetResources(for: asset).enumerated().map { index, resource in
            ResourceInfo(kind: Self.kind(resource.type), originalFilename: resource.originalFilename, index: index)
        }
    }

    func phResource(assetID: String, index: Int) -> PHAssetResource? {
        guard let asset = fetch(assetID) else { return nil }
        let resources = PHAssetResource.assetResources(for: asset)
        return resources.indices.contains(index) ? resources[index] : nil
    }

    private func fetch(_ id: String) -> PHAsset? {
        if let cached = assetCache[id] { return cached }
        let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
        if assetCache.count > 500 { assetCache.removeAll() }
        assetCache[id] = asset
        return asset
    }

    static func kind(_ type: PHAssetResourceType) -> ResourceKind {
        switch type {
        case .photo: return .photo
        case .video: return .video
        case .audio: return .audio
        case .alternatePhoto: return .alternatePhoto
        case .fullSizePhoto: return .fullSizePhoto
        case .fullSizeVideo: return .fullSizeVideo
        case .adjustmentData: return .adjustmentData
        case .adjustmentBasePhoto: return .adjustmentBasePhoto
        case .pairedVideo: return .pairedVideo
        case .fullSizePairedVideo: return .fullSizePairedVideo
        case .adjustmentBasePairedVideo: return .adjustmentBasePairedVideo
        case .adjustmentBaseVideo: return .adjustmentBaseVideo
        case .photoProxy: return .photoProxy
        @unknown default: return .other
        }
    }
}

/// UploadJobQueue over PHAssetResourceUploadJob (iOS 26.1+).
final class PhotoKitJobQueue: UploadJobQueue {
    private let library: PhotoKitLibrarySource
    /// Jobs seen by the last fetch, so acknowledge() can find them by id.
    private var seen: [String: PHAssetResourceUploadJob] = [:]

    init(library: PhotoKitLibrarySource) {
        self.library = library
    }

    var jobLimit: Int { PHAssetResourceUploadJob.jobLimit }

    func finishedJobs() throws -> [UploadJobInfo] {
        let result = PHAssetResourceUploadJob.fetchJobs(action: .acknowledge, options: nil)
        var jobs: [UploadJobInfo] = []
        for i in 0..<result.count {
            let job = result.object(at: i)
            seen[job.localIdentifier] = job
            let error = job.error as NSError?
            jobs.append(UploadJobInfo(id: job.localIdentifier, destination: job.destination.url,
                                      state: Self.state(job.state), errorDomain: error?.domain, errorCode: error?.code))
        }
        return jobs
    }

    func processingJobCount() throws -> Int {
        PHAssetResourceUploadJob.fetchJobs(action: .process, options: nil).count
    }

    func acknowledge(jobIDs: [String]) throws {
        let jobs = jobIDs.compactMap { seen[$0] }
        guard !jobs.isEmpty else { return }
        try PHPhotoLibrary.shared().performChangesAndWait {
            for job in jobs {
                PHAssetResourceUploadJobChangeRequest(for: job)?.acknowledge()
            }
        }
        for id in jobIDs { seen[id] = nil }
    }

    func create(_ jobs: [NewUploadJob]) throws {
        // Resolve outside the change block. Resources that vanished are
        // skipped; the engine sees those jobs never ran and handles it.
        let pairs: [(URLRequest, PHAssetResource)] = jobs.compactMap { job in
            library.phResource(assetID: job.assetID, index: job.resource.index).map { (job.destination.urlRequest, $0) }
        }
        guard !pairs.isEmpty else { return }
        do {
            try PHPhotoLibrary.shared().performChangesAndWait {
                for (request, resource) in pairs {
                    if #available(iOS 26.4, *) {
                        _ = PHAssetResourceUploadJobChangeRequest.creationRequestForJob(destination: request, resource: resource)
                    } else {
                        PHAssetResourceUploadJobChangeRequest.createJob(destination: request, resource: resource)
                    }
                }
            }
        } catch let error as PHPhotosError where error.code == .limitExceeded {
            throw UploadJobQueueError.limitExceeded
        }
    }

    static func state(_ state: PHAssetResourceUploadJob.State) -> UploadJobState {
        switch state {
        case .registered: return .registered
        case .pending: return .pending
        case .succeeded: return .succeeded
        case .failed: return .failed
        case .cancelled: return .cancelled
        @unknown default: return .failed
        }
    }
}

/// Runs async work from a synchronous context (the iOS 26.1 extension
/// protocol's `process()` is synchronous).
func runBlocking<T>(_ operation: @escaping () async -> T) -> T {
    let box = ResultBox<T>()
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        box.value = await operation()
        semaphore.signal()
    }
    semaphore.wait()
    return box.value!
}

private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}
