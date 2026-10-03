import Foundation

/// Where backups go. Works with AWS S3, Cloudflare R2, MinIO, Backblaze B2,
/// Wasabi and anything else that speaks the S3 API with SigV4.
public struct S3Config: Codable, Equatable, Sendable {
    /// Service endpoint without bucket, e.g. `https://<account>.r2.cloudflarestorage.com`
    /// or `https://s3.us-east-1.amazonaws.com`.
    public var endpoint: URL
    /// `auto` for R2, the bucket region for AWS.
    public var region: String
    public var bucket: String
    /// Optional folder inside the bucket, e.g. `phones/alice`. No leading/trailing slash needed.
    public var prefix: String
    /// `https://endpoint/bucket/key` instead of `https://bucket.endpoint/key`.
    /// Path style is the safe default for R2 and MinIO.
    public var usePathStyle: Bool

    public init(endpoint: URL, region: String, bucket: String, prefix: String = "", usePathStyle: Bool = true) {
        self.endpoint = endpoint
        self.region = region
        self.bucket = bucket
        self.prefix = prefix
        self.usePathStyle = usePathStyle
    }

    /// Prefix without leading/trailing slashes and without empty segments.
    public var normalizedPrefix: String {
        prefix.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
    }

    public func validate() -> [S3ConfigError] {
        var errors: [S3ConfigError] = []
        if endpoint.scheme?.lowercased() != "https" { errors.append(.endpointNotHTTPS) }
        if endpoint.host == nil || endpoint.host?.isEmpty == true { errors.append(.endpointMissingHost) }
        let path = endpoint.path
        if !(path.isEmpty || path == "/") { errors.append(.endpointHasPath) }
        if endpoint.query != nil { errors.append(.endpointHasQuery) }
        if region.trimmingCharacters(in: .whitespaces).isEmpty { errors.append(.regionEmpty) }
        if !S3Config.isValidBucketName(bucket) { errors.append(.invalidBucketName) }
        if !usePathStyle && bucket.contains(".") { errors.append(.dottedBucketNeedsPathStyle) }
        let segments = prefix.split(separator: "/", omittingEmptySubsequences: true)
        if segments.contains(where: { $0 == "." || $0 == ".." }) { errors.append(.invalidPrefix) }
        if prefix.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { errors.append(.invalidPrefix) }
        return errors
    }

    /// S3 bucket naming rules (the strict, virtual-host compatible subset).
    public static func isValidBucketName(_ name: String) -> Bool {
        guard (3...63).contains(name.count) else { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard name.allSatisfy({ allowed.contains($0) }) else { return false }
        guard let first = name.first, let last = name.last,
              first.isLetter || first.isNumber, last.isLetter || last.isNumber else { return false }
        if name.contains("..") || name.contains(".-") || name.contains("-.") { return false }
        // Must not look like an IPv4 address.
        let parts = name.split(separator: ".")
        if parts.count == 4 && parts.allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false }) { return false }
        return true
    }

    // MARK: URLs

    /// Host (and port) the requests go to.
    var requestHost: String {
        let host = endpoint.host ?? ""
        return usePathStyle ? host : "\(bucket).\(host)"
    }

    /// URL for an object key. The key is URI-encoded per SigV4 rules with `/` kept.
    public func objectURL(key: String, query: [(String, String)] = []) -> URL {
        let encodedKey = URIEncoding.encode(key, keepSlash: true)
        let path = usePathStyle ? "/\(bucket)/\(encodedKey)" : "/\(encodedKey)"
        return makeURL(percentEncodedPath: path, query: query)
    }

    /// URL for bucket-level operations (list, delete-multiple).
    public func bucketURL(query: [(String, String)] = []) -> URL {
        let path = usePathStyle ? "/\(bucket)" : "/"
        return makeURL(percentEncodedPath: path, query: query)
    }

    private func makeURL(percentEncodedPath: String, query: [(String, String)]) -> URL {
        var components = URLComponents()
        components.scheme = endpoint.scheme ?? "https"
        components.host = requestHost
        components.port = endpoint.port
        components.percentEncodedPath = percentEncodedPath
        if !query.isEmpty {
            components.percentEncodedQuery = query
                .map { "\(URIEncoding.encode($0.0))=\(URIEncoding.encode($0.1))" }
                .joined(separator: "&")
        }
        return components.url!
    }

    /// Reverse of `objectURL`: the decoded key a request URL points at, or nil
    /// if the URL is not an object in this bucket. Used to match PhotoKit upload
    /// jobs back to the files we asked for.
    public func key(fromObjectURL url: URL) -> String? {
        guard let host = url.host, host.lowercased() == requestHost.lowercased() else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let encodedPath = components.percentEncodedPath
        let encodedKey: Substring
        if usePathStyle {
            let bucketPrefix = "/\(bucket)/"
            guard encodedPath.hasPrefix(bucketPrefix) else { return nil }
            encodedKey = encodedPath.dropFirst(bucketPrefix.count)
        } else {
            guard encodedPath.hasPrefix("/") else { return nil }
            encodedKey = encodedPath.dropFirst()
        }
        guard !encodedKey.isEmpty else { return nil }
        return String(encodedKey).removingPercentEncoding
    }

    /// The upload extension's Info.plist declares `BackgroundUploadURLBase`;
    /// every upload URL must live under it.
    public func isAllowed(byUploadURLBase base: URL) -> Bool {
        let sample = objectURL(key: "probe")
        guard sample.scheme?.lowercased() == base.scheme?.lowercased(),
              let host = sample.host?.lowercased(), let baseHost = base.host?.lowercased() else { return false }
        guard host == baseHost else { return false }
        if sample.port != base.port { return false }
        let basePath = base.path.isEmpty ? "/" : base.path
        return sample.path.hasPrefix(basePath)
    }
}

public enum S3ConfigError: String, Error, Equatable, Sendable, CaseIterable {
    case endpointNotHTTPS = "Endpoint must start with https://"
    case endpointMissingHost = "Endpoint has no host name"
    case endpointHasPath = "Endpoint must not contain a path — put folders in Prefix"
    case endpointHasQuery = "Endpoint must not contain a query string"
    case regionEmpty = "Region is required (use \"auto\" for Cloudflare R2)"
    case invalidBucketName = "Bucket name is not valid"
    case dottedBucketNeedsPathStyle = "Buckets with dots need path-style URLs"
    case invalidPrefix = "Prefix contains invalid characters or segments"
}

/// Access keys live in the Keychain, never in settings.
public struct S3Credentials: Equatable, Sendable {
    public var accessKeyID: String
    public var secretAccessKey: String
    public var sessionToken: String?

    public init(accessKeyID: String, secretAccessKey: String, sessionToken: String? = nil) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
    }

    public var isComplete: Bool {
        !accessKeyID.isEmpty && !secretAccessKey.isEmpty
    }
}

enum URIEncoding {
    private static let unreserved: Set<UInt8> = Set(
        Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~".utf8)
    )

    /// RFC 3986 encoding as SigV4 requires: only unreserved characters are
    /// left alone, everything else becomes %XX (uppercase hex).
    static func encode(_ string: String, keepSlash: Bool = false) -> String {
        var out = ""
        out.reserveCapacity(string.utf8.count)
        for byte in string.utf8 {
            if unreserved.contains(byte) || (keepSlash && byte == UInt8(ascii: "/")) {
                out.append(Character(UnicodeScalar(byte)))
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }
}
