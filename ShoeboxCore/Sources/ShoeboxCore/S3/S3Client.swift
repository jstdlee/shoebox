import Foundation

/// The few S3 operations Shoebox needs. Photo uploads themselves are not done
/// here — PhotoKit's background upload service sends them to presigned URLs.
public struct S3Client: Sendable {
    public var config: S3Config
    public var credentials: S3Credentials
    public var transport: HTTPTransport
    public var clock: Clock

    public init(config: S3Config, credentials: S3Credentials, transport: HTTPTransport, clock: Clock = SystemClock()) {
        self.config = config
        self.credentials = credentials
        self.transport = transport
        self.clock = clock
    }

    var signer: SigV4Signer {
        SigV4Signer(credentials: credentials, region: config.region)
    }

    /// A request the system can PUT a file body to, valid for `expires` seconds.
    public func presignedPut(key: String, contentType: String?, expires: Int) -> HTTPRequest {
        let url = signer.presign(method: "PUT", url: config.objectURL(key: key), expires: expires, date: clock.now())
        var headers: [String: String] = [:]
        if let contentType { headers["Content-Type"] = contentType }
        return HTTPRequest(method: "PUT", url: url, headers: headers)
    }

    public func putObject(key: String, body: Data, contentType: String) async throws {
        let request = HTTPRequest(method: "PUT", url: config.objectURL(key: key),
                                  headers: ["Content-Type": contentType], body: body)
        _ = try await send(request, payload: body)
    }

    /// true if the object exists, false on 404.
    public func headObject(key: String) async throws -> Bool {
        let request = HTTPRequest(method: "HEAD", url: config.objectURL(key: key))
        let signed = signer.sign(request, payloadHash: SigV4Signer.emptyPayloadHash, date: clock.now())
        let response = try await transport.send(signed)
        if response.isSuccess { return true }
        if response.status == 404 { return false }
        throw S3XML.parseError(status: response.status, response.body)
    }

    public func listObjects(prefix: String, delimiter: String? = nil, continuationToken: String? = nil, maxKeys: Int = 1000) async throws -> ListObjectsResult {
        var query: [(String, String)] = [("list-type", "2"), ("prefix", prefix), ("max-keys", String(maxKeys))]
        if let delimiter { query.append(("delimiter", delimiter)) }
        if let continuationToken { query.append(("continuation-token", continuationToken)) }
        let request = HTTPRequest(method: "GET", url: config.bucketURL(query: query))
        let response = try await send(request, payload: Data())
        return try S3XML.parseList(response.body)
    }

    /// Lists every key under a prefix, following continuation tokens.
    public func listAllKeys(prefix: String) async throws -> [String] {
        var keys: [String] = []
        var token: String?
        repeat {
            let page = try await listObjects(prefix: prefix, continuationToken: token)
            keys += page.objects.map(\.key)
            token = page.isTruncated ? page.nextContinuationToken : nil
        } while token != nil
        return keys
    }

    public static let maxDeleteBatch = 1000

    /// Deletes up to 1000 keys in one request.
    public func deleteObjects(keys: [String]) async throws -> DeleteObjectsResult {
        precondition(keys.count <= Self.maxDeleteBatch, "DeleteObjects takes at most 1000 keys")
        guard !keys.isEmpty else { return DeleteObjectsResult() }
        let body = S3XML.deleteBody(keys: keys)
        let request = HTTPRequest(method: "POST", url: config.bucketURL(query: [("delete", "")]),
                                  headers: ["Content-Type": "application/xml", "Content-MD5": Digest.md5Base64(body)],
                                  body: body)
        let response = try await send(request, payload: body)
        return try S3XML.parseDelete(response.body)
    }

    private func send(_ request: HTTPRequest, payload: Data) async throws -> HTTPResponse {
        let signed = signer.sign(request, payloadHash: Digest.sha256Hex(payload), date: clock.now())
        let response = try await transport.send(signed)
        guard response.isSuccess else {
            throw S3XML.parseError(status: response.status, response.body)
        }
        return response
    }
}

public enum ContentType {
    private static let table: [String: String] = [
        "jpg": "image/jpeg", "jpeg": "image/jpeg", "heic": "image/heic", "heif": "image/heif",
        "png": "image/png", "gif": "image/gif", "tif": "image/tiff", "tiff": "image/tiff",
        "webp": "image/webp", "dng": "image/x-adobe-dng", "raw": "application/octet-stream",
        "mov": "video/quicktime", "mp4": "video/mp4", "m4v": "video/x-m4v", "hevc": "video/hevc",
        "m4a": "audio/mp4", "aac": "audio/aac", "wav": "audio/wav", "mp3": "audio/mpeg",
        "aae": "application/xml", "json": "application/json",
    ]

    public static func forFilename(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        return table[ext] ?? "application/octet-stream"
    }
}
