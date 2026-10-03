import XCTest
@testable import ShoeboxCore

/// Vectors from the AWS SigV4 test suite and the S3 SigV4 documentation
/// examples ("Examples of signature calculations", "Authenticating requests:
/// query parameters").
final class SigV4Tests: XCTestCase {
    let s3Docs = S3Credentials(accessKeyID: "AKIAIOSFODNN7EXAMPLE",
                               secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
    let may24 = Date(timeIntervalSince1970: 1_369_353_600) // 2013-05-24T00:00:00Z

    private func signature(_ request: HTTPRequest) -> String {
        let auth = request.headers["Authorization"] ?? ""
        return String(auth.split(separator: "=").last ?? "")
    }

    private func signedHeaders(_ request: HTTPRequest) -> String {
        let auth = request.headers["Authorization"] ?? ""
        guard let range = auth.range(of: "SignedHeaders=") else { return "" }
        return String(auth[range.upperBound...].prefix { $0 != "," })
    }

    // MARK: Generic SigV4 suite

    func testGetVanilla() {
        let signer = SigV4Signer(credentials: S3Credentials(accessKeyID: "AKIDEXAMPLE",
                                                            secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"),
                                 region: "us-east-1", service: "service")
        let date = Date(timeIntervalSince1970: 1_440_938_160) // 2015-08-30T12:36:00Z
        let signed = signer.sign(HTTPRequest(method: "GET", url: URL(string: "https://example.amazonaws.com/")!),
                                 payloadHash: SigV4Signer.emptyPayloadHash, date: date)
        XCTAssertEqual(signed.headers["Authorization"],
                       "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
        XCTAssertNil(signed.headers["x-amz-content-sha256"], "only S3 adds the content hash header")
    }

    // MARK: S3 documentation examples

    func testS3GetObjectWithRange() {
        let signer = SigV4Signer(credentials: s3Docs, region: "us-east-1")
        let request = HTTPRequest(method: "GET", url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!,
                                  headers: ["Range": "bytes=0-9"])
        let signed = signer.sign(request, payloadHash: SigV4Signer.emptyPayloadHash, date: may24)
        XCTAssertEqual(signedHeaders(signed), "host;range;x-amz-content-sha256;x-amz-date")
        XCTAssertEqual(signature(signed), "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    }

    func testS3PutObject() {
        let signer = SigV4Signer(credentials: s3Docs, region: "us-east-1")
        let body = Data("Welcome to Amazon S3.".utf8)
        let hash = Digest.sha256Hex(body)
        XCTAssertEqual(hash, "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072")
        let request = HTTPRequest(method: "PUT", url: URL(string: "https://examplebucket.s3.amazonaws.com/test%24file.text")!,
                                  headers: ["Date": "Fri, 24 May 2013 00:00:00 GMT", "x-amz-storage-class": "REDUCED_REDUNDANCY"],
                                  body: body)
        let signed = signer.sign(request, payloadHash: hash, date: may24)
        XCTAssertEqual(signedHeaders(signed), "date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class")
        XCTAssertEqual(signature(signed), "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd")
    }

    func testS3GetBucketLifecycleQueryWithoutValue() {
        let signer = SigV4Signer(credentials: s3Docs, region: "us-east-1")
        let request = HTTPRequest(method: "GET", url: URL(string: "https://examplebucket.s3.amazonaws.com/?lifecycle")!)
        let signed = signer.sign(request, payloadHash: SigV4Signer.emptyPayloadHash, date: may24)
        XCTAssertEqual(signature(signed), "fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543")
    }

    func testS3ListObjectsSortsQuery() {
        let signer = SigV4Signer(credentials: s3Docs, region: "us-east-1")
        // Deliberately unsorted: canonical query must sort it.
        let request = HTTPRequest(method: "GET", url: URL(string: "https://examplebucket.s3.amazonaws.com/?prefix=J&max-keys=2")!)
        let signed = signer.sign(request, payloadHash: SigV4Signer.emptyPayloadHash, date: may24)
        XCTAssertEqual(signature(signed), "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7")
    }

    func testS3PresignedGet() {
        let signer = SigV4Signer(credentials: s3Docs, region: "us-east-1")
        // The documented example signs the payload as UNSIGNED-PAYLOAD.
        let url = signer.presign(method: "GET", url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!,
                                 expires: 86400, date: may24)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        let dict = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(dict["X-Amz-Algorithm"], "AWS4-HMAC-SHA256")
        XCTAssertEqual(dict["X-Amz-Credential"], "AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request")
        XCTAssertEqual(dict["X-Amz-Date"], "20130524T000000Z")
        XCTAssertEqual(dict["X-Amz-Expires"], "86400")
        XCTAssertEqual(dict["X-Amz-SignedHeaders"], "host")
        XCTAssertEqual(dict["X-Amz-Signature"], "aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404")
        XCTAssertTrue(url.absoluteString.hasSuffix("X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"),
                      "signature must be the last parameter")
    }

    // MARK: Behaviour

    func testPresignClampsExpiry() {
        let signer = SigV4Signer(credentials: s3Docs, region: "auto")
        let base = URL(string: "https://acct.r2.cloudflarestorage.com/b/k")!
        let long = signer.presign(method: "PUT", url: base, expires: 10_000_000, date: may24)
        XCTAssertTrue(long.absoluteString.contains("X-Amz-Expires=604800"))
        let negative = signer.presign(method: "PUT", url: base, expires: -5, date: may24)
        XCTAssertTrue(negative.absoluteString.contains("X-Amz-Expires=1&"))
    }

    func testPresignIncludesSessionTokenInSignedQuery() {
        var creds = s3Docs
        creds.sessionToken = "token/with+chars="
        let signer = SigV4Signer(credentials: creds, region: "us-east-1")
        let withToken = signer.presign(method: "GET", url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!,
                                       expires: 86400, date: may24)
        XCTAssertTrue(withToken.absoluteString.contains("X-Amz-Security-Token=token%2Fwith%2Bchars%3D"))
        XCTAssertFalse(withToken.absoluteString.contains("aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"),
                       "token must change the signature")
    }

    func testHeaderSignAddsSessionToken() {
        var creds = s3Docs
        creds.sessionToken = "abc"
        let signed = SigV4Signer(credentials: creds, region: "us-east-1")
            .sign(HTTPRequest(method: "GET", url: URL(string: "https://b.s3.amazonaws.com/k")!),
                  payloadHash: SigV4Signer.emptyPayloadHash, date: may24)
        XCTAssertEqual(signed.headers["x-amz-security-token"], "abc")
        XCTAssertTrue(signedHeaders(signed).contains("x-amz-security-token"))
    }

    func testCanonicalHeadersTrimAndCollapseSpaces() {
        let (canonical, signed) = SigV4Signer.canonicalHeaders(["My-Header": "  a   b  c ", "Host": "h"])
        XCTAssertEqual(canonical, "host:h\nmy-header:a b c\n")
        XCTAssertEqual(signed, "host;my-header")
    }

    func testHostHeaderKeepsNonDefaultPort() {
        XCTAssertEqual(SigV4Signer.hostHeader(for: URL(string: "https://minio.local:9000/b")!), "minio.local:9000")
        XCTAssertEqual(SigV4Signer.hostHeader(for: URL(string: "https://minio.local:443/b")!), "minio.local")
        XCTAssertEqual(SigV4Signer.hostHeader(for: URL(string: "https://minio.local/b")!), "minio.local")
    }

    func testCanonicalQueryEncodesStrictly() {
        let url = URL(string: "https://h/?prefix=a%2Fb%20c&continuation-token=x%2By")!
        XCTAssertEqual(SigV4Signer.canonicalQuery(url), "continuation-token=x%2By&prefix=a%2Fb%20c")
    }

    func testCanonicalQuerySortsDuplicateNamesByValue() {
        let url = URL(string: "https://h/?a=2&a=1&b=")!
        XCTAssertEqual(SigV4Signer.canonicalQuery(url), "a=1&a=2&b=")
    }

    func testURIEncoding() {
        XCTAssertEqual(URIEncoding.encode("a b+c=d&e/f~g_h-i.j"), "a%20b%2Bc%3Dd%26e%2Ff~g_h-i.j")
        XCTAssertEqual(URIEncoding.encode("a b/c", keepSlash: true), "a%20b/c")
        XCTAssertEqual(URIEncoding.encode("é"), "%C3%A9")
        XCTAssertEqual(URIEncoding.encode("写真.heic"), "%E5%86%99%E7%9C%9F.heic")
    }

    func testSigningIsDeterministic() {
        let signer = SigV4Signer(credentials: s3Docs, region: "auto")
        let request = HTTPRequest(method: "GET", url: URL(string: "https://a.r2.cloudflarestorage.com/b/k")!)
        XCTAssertEqual(signer.sign(request, payloadHash: SigV4Signer.emptyPayloadHash, date: may24),
                       signer.sign(request, payloadHash: SigV4Signer.emptyPayloadHash, date: may24))
    }
}
