import Foundation

/// Object key layout in the bucket:
///
///     <prefix>/snapshots/<snapshot-id>/manifest.json
///     <prefix>/snapshots/<snapshot-id>/<yyyy>/<MM>/<name>_<hash8><suffix>.<ext>
///
/// `hash8` comes from the asset's local identifier, so the same photo keeps
/// the same name in every snapshot and two photos named IMG_0001.HEIC never
/// collide.
public struct KeyLayout: Sendable {
    public static let manifestName = "manifest.json"
    public static let maxFilenameBytes = 180

    public var prefix: String
    public var timeZone: TimeZone

    public init(prefix: String, timeZone: TimeZone = .current) {
        self.prefix = prefix.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
        self.timeZone = timeZone
    }

    /// `<prefix>/snapshots/` (or `snapshots/`).
    public var snapshotsRoot: String {
        prefix.isEmpty ? "snapshots/" : "\(prefix)/snapshots/"
    }

    public func snapshotPrefix(_ id: SnapshotID) -> String {
        "\(snapshotsRoot)\(id.rawValue)/"
    }

    public func manifestKey(_ id: SnapshotID) -> String {
        snapshotPrefix(id) + Self.manifestName
    }

    /// Parses a CommonPrefix returned by listing `snapshotsRoot` with delimiter `/`.
    public func snapshotID(fromCommonPrefix commonPrefix: String) -> SnapshotID? {
        guard commonPrefix.hasPrefix(snapshotsRoot) else { return nil }
        let rest = commonPrefix.dropFirst(snapshotsRoot.count)
        guard rest.hasSuffix("/") else { return nil }
        return SnapshotID(String(rest.dropLast()))
    }

    /// Keys for every selected resource of one asset, unique within the asset.
    public func objectKeys(snapshot: SnapshotID, asset: AssetInfo, resources: [ResourceInfo]) -> [String] {
        var used = Set<String>()
        return resources.map { resource in
            var key = objectKey(snapshot: snapshot, asset: asset, resource: resource)
            var n = 2
            while used.contains(key) {
                key = objectKey(snapshot: snapshot, asset: asset, resource: resource, extraSuffix: "_\(n)")
                n += 1
            }
            used.insert(key)
            return key
        }
    }

    public func objectKey(snapshot: SnapshotID, asset: AssetInfo, resource: ResourceInfo, extraSuffix: String = "") -> String {
        let folder: String
        if let date = asset.creationDate {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let parts = calendar.dateComponents([.year, .month], from: date)
            folder = String(format: "%04d/%02d", parts.year ?? 0, parts.month ?? 0)
        } else {
            folder = "undated"
        }
        let (stem, ext) = Self.splitFilename(Self.sanitize(resource.originalFilename))
        let hash = String(Digest.sha256Hex(asset.localIdentifier).prefix(8))
        let name = "\(stem)_\(hash)\(resource.kind.keySuffix)\(extraSuffix)" + (ext.isEmpty ? "" : ".\(ext)")
        return "\(snapshotPrefix(snapshot))\(folder)/\(name)"
    }

    /// Removes path separators and control characters, caps the length.
    static func sanitize(_ filename: String) -> String {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        var cleaned = String(trimmed.unicodeScalars.map { scalar -> Character in
            if scalar == "/" || scalar == "\\" || scalar.value < 0x20 || scalar.value == 0x7F { return "_" }
            return Character(scalar)
        })
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.isEmpty { cleaned = "file" }
        if cleaned.utf8.count > maxFilenameBytes {
            let (stem, ext) = splitFilename(cleaned)
            var shortStem = ""
            let budget = maxFilenameBytes - ext.utf8.count - 1
            for ch in stem {
                if shortStem.utf8.count + String(ch).utf8.count > budget { break }
                shortStem.append(ch)
            }
            cleaned = ext.isEmpty ? shortStem : "\(shortStem).\(ext)"
        }
        return cleaned
    }

    static func splitFilename(_ name: String) -> (stem: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        let ext = String(name[name.index(after: dot)...])
        // Treat very long or empty "extensions" as part of the name.
        if ext.isEmpty || ext.count > 8 || ext.contains(" ") { return (name, "") }
        return (String(name[..<dot]), ext)
    }
}
