import XCTest
@testable import ShoeboxCore

final class S3ConfigTests: XCTestCase {
    let r2 = S3Config(endpoint: URL(string: "https://acct123.r2.cloudflarestorage.com")!, region: "auto",
                      bucket: "photos", prefix: "/iphone/alice/", usePathStyle: true)

    // MARK: Validation

    func testValidR2ConfigHasNoErrors() {
        XCTAssertEqual(r2.validate(), [])
    }

    func testRejectsHTTP() {
        var c = r2
        c.endpoint = URL(string: "http://acct.r2.cloudflarestorage.com")!
        XCTAssertTrue(c.validate().contains(.endpointNotHTTPS))
    }

    func testRejectsEndpointWithPathOrQuery() {
        var c = r2
        c.endpoint = URL(string: "https://acct.r2.cloudflarestorage.com/photos")!
        XCTAssertTrue(c.validate().contains(.endpointHasPath))
        c.endpoint = URL(string: "https://acct.r2.cloudflarestorage.com?x=1")!
        XCTAssertTrue(c.validate().contains(.endpointHasQuery))
    }

    func testAcceptsTrailingSlashEndpoint() {
        var c = r2
        c.endpoint = URL(string: "https://acct.r2.cloudflarestorage.com/")!
        XCTAssertEqual(c.validate(), [])
    }

    func testRegionRequired() {
        var c = r2
        c.region = "  "
        XCTAssertTrue(c.validate().contains(.regionEmpty))
    }

    func testBucketNames() {
        let valid = ["abc", "my-photos", "my.photos.2026", String(repeating: "a", count: 63), "0ab"]
        let invalid = ["ab", String(repeating: "a", count: 64), "My-Photos", "-abc", "abc-", "a..b", "a.-b",
                       "a-.b", "192.168.1.1", "under_score", "space here", ""]
        for name in valid { XCTAssertTrue(S3Config.isValidBucketName(name), name) }
        for name in invalid { XCTAssertFalse(S3Config.isValidBucketName(name), name) }
    }

    func testDottedBucketNeedsPathStyle() {
        var c = r2
        c.bucket = "my.photos"
        c.usePathStyle = false
        XCTAssertTrue(c.validate().contains(.dottedBucketNeedsPathStyle))
        c.usePathStyle = true
        XCTAssertEqual(c.validate(), [])
    }

    func testPrefixValidationAndNormalization() {
        var c = r2
        XCTAssertEqual(c.normalizedPrefix, "iphone/alice")
        c.prefix = "a//b///"
        XCTAssertEqual(c.normalizedPrefix, "a/b")
        c.prefix = "a/../b"
        XCTAssertTrue(c.validate().contains(.invalidPrefix))
        c.prefix = "a/\u{01}b"
        XCTAssertTrue(c.validate().contains(.invalidPrefix))
        c.prefix = ""
        XCTAssertEqual(c.normalizedPrefix, "")
        XCTAssertEqual(c.validate(), [])
    }

    // MARK: URLs

    func testPathStyleObjectURL() {
        XCTAssertEqual(r2.objectURL(key: "snapshots/x/IMG 1.heic").absoluteString,
                       "https://acct123.r2.cloudflarestorage.com/photos/snapshots/x/IMG%201.heic")
    }

    func testVirtualHostedObjectURL() {
        var c = r2
        c.usePathStyle = false
        XCTAssertEqual(c.objectURL(key: "a/b.jpg").absoluteString, "https://photos.acct123.r2.cloudflarestorage.com/a/b.jpg")
        XCTAssertEqual(c.bucketURL(query: [("list-type", "2")]).absoluteString,
                       "https://photos.acct123.r2.cloudflarestorage.com/?list-type=2")
    }

    func testBucketURLWithQuery() {
        XCTAssertEqual(r2.bucketURL(query: [("list-type", "2"), ("prefix", "a/b")]).absoluteString,
                       "https://acct123.r2.cloudflarestorage.com/photos?list-type=2&prefix=a%2Fb")
    }

    func testEndpointPortIsKept() {
        var c = r2
        c.endpoint = URL(string: "https://minio.home.lan:9000")!
        XCTAssertEqual(c.objectURL(key: "k").absoluteString, "https://minio.home.lan:9000/photos/k")
    }

    func testKeyRoundTripsThroughURL() {
        let keys = ["a/b/c.jpg", "snap/2026/09/IMG 0001_ab12cd34.HEIC", "写真/é+&=?#.mov", "x/100%.png"]
        for style in [true, false] {
            var c = r2
            c.usePathStyle = style
            for key in keys {
                let url = c.objectURL(key: key)
                XCTAssertEqual(c.key(fromObjectURL: url), key, "pathStyle=\(style) key=\(key)")
                // Presigning adds a query; the key must still be recoverable.
                let presigned = SigV4Signer(credentials: .init(accessKeyID: "a", secretAccessKey: "b"), region: "auto")
                    .presign(method: "PUT", url: url, expires: 60, date: Date())
                XCTAssertEqual(c.key(fromObjectURL: presigned), key)
            }
        }
    }

    func testKeyFromForeignURLIsNil() {
        XCTAssertNil(r2.key(fromObjectURL: URL(string: "https://example.com/photos/a.jpg")!))
        XCTAssertNil(r2.key(fromObjectURL: URL(string: "https://acct123.r2.cloudflarestorage.com/otherbucket/a.jpg")!))
        XCTAssertNil(r2.key(fromObjectURL: URL(string: "https://acct123.r2.cloudflarestorage.com/photos/")!))
    }

    func testUploadURLBaseCheck() {
        XCTAssertTrue(r2.isAllowed(byUploadURLBase: URL(string: "https://acct123.r2.cloudflarestorage.com")!))
        XCTAssertTrue(r2.isAllowed(byUploadURLBase: URL(string: "https://acct123.r2.cloudflarestorage.com/photos")!))
        XCTAssertFalse(r2.isAllowed(byUploadURLBase: URL(string: "https://acct123.r2.cloudflarestorage.com/other")!))
        XCTAssertFalse(r2.isAllowed(byUploadURLBase: URL(string: "https://other.r2.cloudflarestorage.com")!))
        XCTAssertFalse(r2.isAllowed(byUploadURLBase: URL(string: "http://acct123.r2.cloudflarestorage.com")!))
        var virtual = r2
        virtual.usePathStyle = false
        XCTAssertFalse(virtual.isAllowed(byUploadURLBase: URL(string: "https://acct123.r2.cloudflarestorage.com")!),
                       "virtual-hosted requests go to bucket.host, which the base must name")
        XCTAssertTrue(virtual.isAllowed(byUploadURLBase: URL(string: "https://photos.acct123.r2.cloudflarestorage.com")!))
    }

    func testConfigCodableRoundTrip() throws {
        let data = try JSONEncoder().encode(r2)
        XCTAssertEqual(try JSONDecoder().decode(S3Config.self, from: data), r2)
    }

    func testCredentialsCompleteness() {
        XCTAssertTrue(S3Credentials(accessKeyID: "a", secretAccessKey: "b").isComplete)
        XCTAssertFalse(S3Credentials(accessKeyID: "", secretAccessKey: "b").isComplete)
        XCTAssertFalse(S3Credentials(accessKeyID: "a", secretAccessKey: "").isComplete)
    }

    func testContentTypes() {
        XCTAssertEqual(ContentType.forFilename("IMG_1.HEIC"), "image/heic")
        XCTAssertEqual(ContentType.forFilename("a.JPG"), "image/jpeg")
        XCTAssertEqual(ContentType.forFilename("clip.mov"), "video/quicktime")
        XCTAssertEqual(ContentType.forFilename("raw.DNG"), "image/x-adobe-dng")
        XCTAssertEqual(ContentType.forFilename("noext"), "application/octet-stream")
        XCTAssertEqual(ContentType.forFilename("weird.xyz"), "application/octet-stream")
    }
}
