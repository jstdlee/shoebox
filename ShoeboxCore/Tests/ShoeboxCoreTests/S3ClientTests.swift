import XCTest
@testable import ShoeboxCore

final class S3XMLTests: XCTestCase {
    func testParseListWithObjectsAndPrefixes() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <Name>photos</Name><Prefix>p/</Prefix><KeyCount>3</KeyCount><MaxKeys>1000</MaxKeys>
          <IsTruncated>true</IsTruncated>
          <NextContinuationToken>1ueGcxLPRx1Tr/XYExHnhbYLgveDs2J/wm36Hy4vbOwM=</NextContinuationToken>
          <Contents><Key>p/a.jpg</Key><LastModified>2026-01-01T00:00:00.000Z</LastModified><Size>123</Size></Contents>
          <Contents><Key>p/b &amp; c.jpg</Key><Size>0</Size></Contents>
          <CommonPrefixes><Prefix>p/snapshots/20260101T000000Z/</Prefix></CommonPrefixes>
          <CommonPrefixes><Prefix>p/snapshots/20260108T000000Z/</Prefix></CommonPrefixes>
        </ListBucketResult>
        """
        let result = try S3XML.parseList(Data(xml.utf8))
        XCTAssertEqual(result.objects, [.init(key: "p/a.jpg", size: 123), .init(key: "p/b & c.jpg", size: 0)])
        XCTAssertEqual(result.commonPrefixes, ["p/snapshots/20260101T000000Z/", "p/snapshots/20260108T000000Z/"])
        XCTAssertTrue(result.isTruncated)
        XCTAssertEqual(result.nextContinuationToken, "1ueGcxLPRx1Tr/XYExHnhbYLgveDs2J/wm36Hy4vbOwM=")
    }

    func testParseEmptyList() throws {
        let xml = "<ListBucketResult><IsTruncated>false</IsTruncated><KeyCount>0</KeyCount></ListBucketResult>"
        let result = try S3XML.parseList(Data(xml.utf8))
        XCTAssertEqual(result, ListObjectsResult())
    }

    func testParseMalformedListThrows() {
        XCTAssertThrowsError(try S3XML.parseList(Data("<ListBucketResult><Contents>".utf8)))
        XCTAssertThrowsError(try S3XML.parseList(Data("not xml".utf8)))
        XCTAssertThrowsError(try S3XML.parseList(Data()))
    }

    func testParseDeleteResult() throws {
        let xml = """
        <DeleteResult>
          <Deleted><Key>a</Key></Deleted>
          <Deleted><Key>b</Key></Deleted>
          <Error><Key>c</Key><Code>AccessDenied</Code><Message>Access Denied</Message></Error>
        </DeleteResult>
        """
        let result = try S3XML.parseDelete(Data(xml.utf8))
        XCTAssertEqual(result.deleted, ["a", "b"])
        XCTAssertEqual(result.errors, [.init(key: "c", code: "AccessDenied", message: "Access Denied")])
    }

    func testParseError() {
        let xml = "<Error><Code>NoSuchBucket</Code><Message>The specified bucket does not exist</Message><BucketName>x</BucketName></Error>"
        let error = S3XML.parseError(status: 404, Data(xml.utf8))
        XCTAssertEqual(error, S3Error(status: 404, code: "NoSuchBucket", message: "The specified bucket does not exist"))
        XCTAssertTrue(error.description.contains("NoSuchBucket"))
    }

    func testParseErrorWithEmptyBody() {
        let error = S3XML.parseError(status: 403, Data())
        XCTAssertEqual(error.status, 403)
        XCTAssertEqual(error.description, "HTTP 403")
    }

    func testDeleteBodyEscapesKeys() {
        let body = String(decoding: S3XML.deleteBody(keys: ["a&b", "<c>", "d\"e'f"]), as: UTF8.self)
        XCTAssertTrue(body.contains("<Key>a&amp;b</Key>"))
        XCTAssertTrue(body.contains("<Key>&lt;c&gt;</Key>"))
        XCTAssertTrue(body.contains("<Key>d&quot;e&apos;f</Key>"))
        XCTAssertTrue(body.contains("<Quiet>true</Quiet>"))
    }
}

final class S3ClientTests: XCTestCase {
    let config = S3Config(endpoint: URL(string: "https://acct.r2.cloudflarestorage.com")!, region: "auto", bucket: "photos", prefix: "p")
    let creds = S3Credentials(accessKeyID: "AK", secretAccessKey: "SK")
    let clock = FixedClock(Date(timeIntervalSince1970: 1_790_000_000))

    func client(_ transport: MockTransport) -> S3Client {
        S3Client(config: config, credentials: creds, transport: transport, clock: clock)
    }

    func listXML(keys: [String], prefixes: [String] = [], next: String? = nil) -> Data {
        var xml = "<ListBucketResult><IsTruncated>\(next != nil)</IsTruncated>"
        if let next { xml += "<NextContinuationToken>\(next)</NextContinuationToken>" }
        for k in keys { xml += "<Contents><Key>\(S3XML.escape(k))</Key><Size>1</Size></Contents>" }
        for p in prefixes { xml += "<CommonPrefixes><Prefix>\(p)</Prefix></CommonPrefixes>" }
        return Data((xml + "</ListBucketResult>").utf8)
    }

    func testPresignedPutShape() {
        let request = client(MockTransport()).presignedPut(key: "p/a b.jpg", contentType: "image/jpeg", expires: 3600)
        XCTAssertEqual(request.method, "PUT")
        XCTAssertEqual(request.headers["Content-Type"], "image/jpeg")
        XCTAssertNil(request.body)
        let s = request.url.absoluteString
        XCTAssertTrue(s.hasPrefix("https://acct.r2.cloudflarestorage.com/photos/p/a%20b.jpg?"))
        XCTAssertTrue(s.contains("X-Amz-Expires=3600"))
        XCTAssertTrue(s.contains("X-Amz-Credential=AK%2F20260921%2Fauto%2Fs3%2Faws4_request"))
        XCTAssertTrue(s.contains("X-Amz-Signature="))
    }

    func testPutObjectSignsBodyHash() async throws {
        let transport = MockTransport()
        let body = Data("{}".utf8)
        try await client(transport).putObject(key: "p/m.json", body: body, contentType: "application/json")
        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(sent.method, "PUT")
        XCTAssertEqual(sent.body, body)
        XCTAssertEqual(sent.headers["x-amz-content-sha256"], Digest.sha256Hex(body))
        XCTAssertNotNil(sent.headers["Authorization"])
        XCTAssertTrue(sent.headers["Authorization"]!.contains("content-type"))
    }

    func testPutObjectErrorIsThrown() async {
        let transport = MockTransport { _ in
            HTTPResponse(status: 403, body: Data("<Error><Code>AccessDenied</Code><Message>no</Message></Error>".utf8))
        }
        do {
            try await client(transport).putObject(key: "k", body: Data(), contentType: "x")
            XCTFail("expected throw")
        } catch let error as S3Error {
            XCTAssertEqual(error.code, "AccessDenied")
            XCTAssertEqual(error.status, 403)
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testHeadObject() async throws {
        var status = 200
        let transport = MockTransport { _ in HTTPResponse(status: status) }
        let c = client(transport)
        let exists = try await c.headObject(key: "k")
        XCTAssertTrue(exists)
        status = 404
        let missing = try await c.headObject(key: "k")
        XCTAssertFalse(missing)
        status = 500
        do {
            _ = try await c.headObject(key: "k")
            XCTFail("expected throw")
        } catch {}
        XCTAssertEqual(transport.requests.first?.method, "HEAD")
    }

    func testListObjectsQuery() async throws {
        let transport = MockTransport { _ in HTTPResponse(status: 200, body: self.listXML(keys: [])) }
        _ = try await client(transport).listObjects(prefix: "p/snapshots/", delimiter: "/", continuationToken: "t+/=")
        let url = try XCTUnwrap(transport.requests.first?.url.absoluteString)
        XCTAssertTrue(url.hasPrefix("https://acct.r2.cloudflarestorage.com/photos?"))
        XCTAssertTrue(url.contains("list-type=2"))
        XCTAssertTrue(url.contains("prefix=p%2Fsnapshots%2F"))
        XCTAssertTrue(url.contains("delimiter=%2F"))
        XCTAssertTrue(url.contains("continuation-token=t%2B%2F%3D"))
    }

    func testListAllKeysFollowsContinuation() async throws {
        let transport = MockTransport { request in
            let url = request.url.absoluteString
            if url.contains("continuation-token=page2") {
                return HTTPResponse(status: 200, body: self.listXML(keys: ["c"]))
            }
            return HTTPResponse(status: 200, body: self.listXML(keys: ["a", "b"], next: "page2"))
        }
        let keys = try await client(transport).listAllKeys(prefix: "x")
        XCTAssertEqual(keys, ["a", "b", "c"])
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testDeleteObjectsRequest() async throws {
        let transport = MockTransport { _ in HTTPResponse(status: 200, body: Data("<DeleteResult/>".utf8)) }
        _ = try await client(transport).deleteObjects(keys: ["a", "b"])
        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(sent.method, "POST")
        XCTAssertTrue(sent.url.absoluteString.hasSuffix("/photos?delete="))
        XCTAssertEqual(sent.headers["Content-MD5"], Digest.md5Base64(sent.body!))
        XCTAssertTrue(sent.headers["Authorization"]!.contains("content-md5"))
    }

    func testDeleteObjectsEmptyIsNoop() async throws {
        let transport = MockTransport()
        let result = try await client(transport).deleteObjects(keys: [])
        XCTAssertEqual(result, DeleteObjectsResult())
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testMD5KnownValue() {
        XCTAssertEqual(Digest.md5Base64(Data()), "1B2M2Y8AsgTpgAmY7PhCfg==")
    }
}

final class S3SnapshotStoreTests: XCTestCase {
    let config = S3Config(endpoint: URL(string: "https://acct.r2.cloudflarestorage.com")!, region: "auto", bucket: "photos", prefix: "p")
    let layout = KeyLayout(prefix: "p")

    func store(_ transport: MockTransport) -> S3SnapshotStore {
        S3SnapshotStore(client: S3Client(config: config, credentials: .init(accessKeyID: "a", secretAccessKey: "b"), transport: transport),
                        layout: layout)
    }

    func xml(keys: [String] = [], prefixes: [String] = []) -> HTTPResponse {
        var s = "<ListBucketResult><IsTruncated>false</IsTruncated>"
        for k in keys { s += "<Contents><Key>\(k)</Key><Size>1</Size></Contents>" }
        for p in prefixes { s += "<CommonPrefixes><Prefix>\(p)</Prefix></CommonPrefixes>" }
        return HTTPResponse(status: 200, body: Data((s + "</ListBucketResult>").utf8))
    }

    func testListSnapshotsChecksManifests() async throws {
        let transport = MockTransport { request in
            if request.method == "HEAD" {
                return HTTPResponse(status: request.url.path.contains("20260101") ? 200 : 404)
            }
            return self.xml(prefixes: ["p/snapshots/20260108T000000Z/", "p/snapshots/20260101T000000Z/", "p/snapshots/junk/"])
        }
        let snapshots = try await store(transport).listSnapshots()
        XCTAssertEqual(snapshots, [
            RemoteSnapshot(id: SnapshotID("20260101T000000Z")!, isComplete: true),
            RemoteSnapshot(id: SnapshotID("20260108T000000Z")!, isComplete: false),
        ])
    }

    func testDeleteSnapshotDeletesManifestLast() async throws {
        let id = SnapshotID("20260101T000000Z")!
        let manifest = layout.manifestKey(id)
        var remaining = [layout.snapshotPrefix(id) + "2026/01/a.jpg", manifest, layout.snapshotPrefix(id) + "undated/b.jpg"]
        var deleteBodies: [String] = []
        let transport = MockTransport { request in
            if request.method == "POST" {
                let body = String(decoding: request.body!, as: UTF8.self)
                deleteBodies.append(body)
                remaining.removeAll { body.contains("<Key>\($0)</Key>") }
                return HTTPResponse(status: 200, body: Data("<DeleteResult/>".utf8))
            }
            return self.xml(keys: remaining)
        }
        let (done, used) = try await store(transport).deleteSnapshot(id, maxBatches: 10)
        XCTAssertTrue(done)
        XCTAssertEqual(used, 2)
        XCTAssertFalse(deleteBodies[0].contains("manifest.json"))
        XCTAssertTrue(deleteBodies[1].contains("manifest.json"))
        XCTAssertTrue(remaining.isEmpty)
    }

    func testDeleteSnapshotStopsAtBatchBudget() async throws {
        let id = SnapshotID("20260101T000000Z")!
        let transport = MockTransport { request in
            if request.method == "POST" { return HTTPResponse(status: 200, body: Data("<DeleteResult/>".utf8)) }
            // Never empties: pretend there is always more.
            return self.xml(keys: [self.layout.snapshotPrefix(id) + "x.jpg"])
        }
        let (done, used) = try await store(transport).deleteSnapshot(id, maxBatches: 3)
        XCTAssertFalse(done)
        XCTAssertEqual(used, 3)
    }

    func testDeleteSnapshotSurfacesPerKeyErrors() async {
        let id = SnapshotID("20260101T000000Z")!
        let transport = MockTransport { request in
            if request.method == "POST" {
                return HTTPResponse(status: 200, body: Data("<DeleteResult><Error><Key>k</Key><Code>AccessDenied</Code><Message>m</Message></Error></DeleteResult>".utf8))
            }
            return self.xml(keys: [self.layout.snapshotPrefix(id) + "x.jpg"])
        }
        do {
            _ = try await store(transport).deleteSnapshot(id, maxBatches: 3)
            XCTFail("expected throw")
        } catch let error as S3Error {
            XCTAssertEqual(error.code, "AccessDenied")
        } catch {
            XCTFail("\(error)")
        }
    }

    func testPutManifestUploadsJSON() async throws {
        let transport = MockTransport()
        let id = SnapshotID("20260101T000000Z")!
        let manifest = Manifest(snapshotID: id, startedAt: id.date, completedAt: id.date, assetCount: 1, skippedAssets: 0, files: ["a"], failed: [])
        try await store(transport).putManifest(manifest, key: layout.manifestKey(id))
        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(sent.headers["Content-Type"], "application/json")
        XCTAssertEqual(try Manifest.decode(sent.body!), manifest)
    }
}
