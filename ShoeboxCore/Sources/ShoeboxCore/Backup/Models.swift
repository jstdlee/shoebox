import Foundation

/// Mirrors PHAssetResourceType so the core stays PhotoKit-free.
public enum ResourceKind: String, Codable, Sendable, CaseIterable {
    case photo, video, audio
    case alternatePhoto
    case fullSizePhoto, fullSizeVideo
    case pairedVideo, fullSizePairedVideo
    case adjustmentData, adjustmentBasePhoto, adjustmentBaseVideo, adjustmentBasePairedVideo
    case photoProxy
    case other

    var isVideo: Bool {
        self == .video || self == .fullSizeVideo
    }

    var isLivePhotoVideo: Bool {
        self == .pairedVideo || self == .fullSizePairedVideo
    }

    var isEdit: Bool {
        self == .fullSizePhoto || self == .fullSizeVideo || self == .fullSizePairedVideo
    }

    /// Resources that only make sense inside Photos (edit recipes, proxies).
    var isInternal: Bool {
        switch self {
        case .adjustmentData, .adjustmentBasePhoto, .adjustmentBaseVideo, .adjustmentBasePairedVideo, .photoProxy, .other:
            return true
        default:
            return false
        }
    }

    /// Filename suffix so an asset's resources never collide.
    var keySuffix: String {
        switch self {
        case .alternatePhoto: return "_alt"
        case .fullSizePhoto, .fullSizeVideo, .fullSizePairedVideo: return "_edited"
        default: return ""
        }
    }
}

public struct AssetInfo: Equatable, Sendable {
    public var localIdentifier: String
    public var creationDate: Date?

    public init(localIdentifier: String, creationDate: Date?) {
        self.localIdentifier = localIdentifier
        self.creationDate = creationDate
    }
}

public struct ResourceInfo: Equatable, Sendable, Codable {
    public var kind: ResourceKind
    public var originalFilename: String
    /// Position in PHAssetResource.assetResources(for:), used to find the
    /// resource again when creating the upload job.
    public var index: Int

    public init(kind: ResourceKind, originalFilename: String, index: Int) {
        self.kind = kind
        self.originalFilename = originalFilename
        self.index = index
    }
}

/// Which resources of an asset get backed up.
public struct ResourcePolicy: Equatable, Sendable, Codable {
    public var includeVideos: Bool
    public var includeLivePhotoVideos: Bool
    public var includeEdits: Bool

    public init(includeVideos: Bool = true, includeLivePhotoVideos: Bool = true, includeEdits: Bool = true) {
        self.includeVideos = includeVideos
        self.includeLivePhotoVideos = includeLivePhotoVideos
        self.includeEdits = includeEdits
    }

    public func select(_ resources: [ResourceInfo]) -> [ResourceInfo] {
        resources.filter { r in
            if r.kind.isInternal { return false }
            if r.kind.isVideo && !includeVideos { return false }
            if r.kind.isLivePhotoVideo && !includeLivePhotoVideos { return false }
            if r.kind.isEdit && !includeEdits { return false }
            return true
        }
    }
}

/// `20260929T020000Z`. Sorts chronologically as a string.
public struct SnapshotID: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(date: Date) {
        rawValue = UTCFormat.basic(date)
    }

    public init?(_ rawValue: String) {
        guard UTCFormat.parseBasic(rawValue) != nil, rawValue.count == 16 else { return nil }
        self.rawValue = rawValue
    }

    public var date: Date { UTCFormat.parseBasic(rawValue)! }
    public var description: String { rawValue }

    public static func < (lhs: SnapshotID, rhs: SnapshotID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    // Encoded as a plain string in state files and manifests.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let id = SnapshotID(raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid snapshot id \(raw)")
        }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
