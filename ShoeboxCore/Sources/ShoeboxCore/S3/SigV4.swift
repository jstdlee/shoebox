import Foundation

/// AWS Signature Version 4 for S3-compatible services.
public struct SigV4Signer: Sendable {
    public static let unsignedPayload = "UNSIGNED-PAYLOAD"
    public static let emptyPayloadHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    /// S3 caps presigned URLs at 7 days.
    public static let maxPresignSeconds = 604_800

    public var credentials: S3Credentials
    public var region: String
    public var service: String

    public init(credentials: S3Credentials, region: String, service: String = "s3") {
        self.credentials = credentials
        self.region = region
        self.service = service
    }

    // MARK: Header auth

    /// Adds `x-amz-date`, `x-amz-content-sha256` (for s3), optional session
    /// token and `Authorization` headers. All headers already on the request
    /// are signed.
    public func sign(_ request: HTTPRequest, payloadHash: String, date: Date) -> HTTPRequest {
        var request = request
        let amzDate = UTCFormat.basic(date)
        request.headers["x-amz-date"] = amzDate
        if service == "s3" {
            request.headers["x-amz-content-sha256"] = payloadHash
        }
        if let token = credentials.sessionToken {
            request.headers["x-amz-security-token"] = token
        }
        var headersToSign = request.headers
        headersToSign["host"] = Self.hostHeader(for: request.url)

        let (canonicalHeaders, signedHeaders) = Self.canonicalHeaders(headersToSign)
        let canonical = [
            request.method.uppercased(),
            Self.canonicalURI(request.url),
            Self.canonicalQuery(request.url),
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let scope = credentialScope(date)
        let signature = self.signature(canonicalRequest: canonical, amzDate: amzDate, scope: scope, date: date)
        request.headers["Authorization"] =
            "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        return request
    }

    // MARK: Query auth (presigned URLs)

    /// Returns a presigned URL. Only `host` (plus `signedHeaders`) is signed,
    /// and the payload is UNSIGNED-PAYLOAD, so the system can stream the file
    /// without us ever reading it.
    public func presign(method: String, url: URL, expires: Int, date: Date, signedHeaders extra: [String: String] = [:]) -> URL {
        let expires = min(max(expires, 1), Self.maxPresignSeconds)
        let amzDate = UTCFormat.basic(date)
        let scope = credentialScope(date)

        var headersToSign = extra
        headersToSign["host"] = Self.hostHeader(for: url)
        let (canonicalHeaders, signedHeaders) = Self.canonicalHeaders(headersToSign)

        var query = Self.queryPairs(url)
        query.append(("X-Amz-Algorithm", "AWS4-HMAC-SHA256"))
        query.append(("X-Amz-Credential", "\(credentials.accessKeyID)/\(scope)"))
        query.append(("X-Amz-Date", amzDate))
        query.append(("X-Amz-Expires", String(expires)))
        if let token = credentials.sessionToken {
            query.append(("X-Amz-Security-Token", token))
        }
        query.append(("X-Amz-SignedHeaders", signedHeaders))

        let canonicalQuery = Self.encodeQuery(query)
        let canonical = [
            method.uppercased(),
            Self.canonicalURI(url),
            canonicalQuery,
            canonicalHeaders,
            signedHeaders,
            Self.unsignedPayload,
        ].joined(separator: "\n")
        let signature = self.signature(canonicalRequest: canonical, amzDate: amzDate, scope: scope, date: date)

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = canonicalQuery + "&X-Amz-Signature=\(signature)"
        return components.url!
    }

    // MARK: Internals

    func credentialScope(_ date: Date) -> String {
        "\(UTCFormat.day(date))/\(region)/\(service)/aws4_request"
    }

    func signature(canonicalRequest: String, amzDate: String, scope: String, date: Date) -> String {
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            Digest.sha256Hex(canonicalRequest),
        ].joined(separator: "\n")
        var key = Digest.hmacSHA256(key: Data("AWS4\(credentials.secretAccessKey)".utf8), message: UTCFormat.day(date))
        key = Digest.hmacSHA256(key: key, message: region)
        key = Digest.hmacSHA256(key: key, message: service)
        key = Digest.hmacSHA256(key: key, message: "aws4_request")
        return Digest.hmacSHA256(key: key, message: stringToSign).hexString
    }

    static func hostHeader(for url: URL) -> String {
        let host = url.host ?? ""
        if let port = url.port {
            let scheme = url.scheme?.lowercased()
            if !((scheme == "https" && port == 443) || (scheme == "http" && port == 80)) {
                return "\(host):\(port)"
            }
        }
        return host
    }

    /// S3 does not double-encode: the path we built is already RFC 3986 encoded.
    static func canonicalURI(_ url: URL) -> String {
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        return path.isEmpty ? "/" : path
    }

    static func queryPairs(_ url: URL) -> [(String, String)] {
        guard let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery,
              !raw.isEmpty else { return [] }
        return raw.split(separator: "&", omittingEmptySubsequences: true).map { item in
            let parts = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0]).removingPercentEncoding ?? String(parts[0])
            let value = parts.count > 1 ? (String(parts[1]).removingPercentEncoding ?? String(parts[1])) : ""
            return (name, value)
        }
    }

    static func canonicalQuery(_ url: URL) -> String {
        encodeQuery(queryPairs(url))
    }

    static func encodeQuery(_ pairs: [(String, String)]) -> String {
        let encoded: [(name: String, value: String)] = pairs.map { pair in
            (URIEncoding.encode(pair.0), URIEncoding.encode(pair.1))
        }
        let sorted = encoded.sorted { a, b in
            a.name == b.name ? a.value < b.value : a.name < b.name
        }
        return sorted.map { "\($0.name)=\($0.value)" }.joined(separator: "&")
    }

    static func canonicalHeaders(_ headers: [String: String]) -> (canonical: String, signed: String) {
        var merged: [String: [String]] = [:]
        for (name, value) in headers {
            merged[name.lowercased(), default: []].append(trimAll(value))
        }
        let names = merged.keys.sorted()
        let canonical = names.map { "\($0):\(merged[$0]!.joined(separator: ","))\n" }.joined()
        return (canonical, names.joined(separator: ";"))
    }

    /// Trim and collapse runs of spaces, as SigV4 requires.
    static func trimAll(_ value: String) -> String {
        value.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
