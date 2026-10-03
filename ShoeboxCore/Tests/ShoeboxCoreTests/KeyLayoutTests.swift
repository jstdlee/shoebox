import XCTest
@testable import ShoeboxCore

final class KeyLayoutTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC")!
    let snap = SnapshotID("20260929T020000Z")!
    // 2026-03-15T12:00:00Z
    let march = Date(timeIntervalSince1970: 1_773_576_000)

    func photo(_ name: String, _ kind: ResourceKind = .photo, _ index: Int = 0) -> ResourceInfo {
        ResourceInfo(kind: kind, originalFilename: name, index: index)
    }

    func testRoots() {
        XCTAssertEqual(KeyLayout(prefix: "").snapshotsRoot, "snapshots/")
        XCTAssertEqual(KeyLayout(prefix: "/a/b/").snapshotsRoot, "a/b/snapshots/")
        XCTAssertEqual(KeyLayout(prefix: "a").snapshotPrefix(snap), "a/snapshots/20260929T020000Z/")
        XCTAssertEqual(KeyLayout(prefix: "a").manifestKey(snap), "a/snapshots/20260929T020000Z/manifest.json")
    }

    func testObjectKeyShape() {
        let layout = KeyLayout(prefix: "p", timeZone: utc)
        let asset = AssetInfo(localIdentifier: "ABC/L0/001", creationDate: march)
        let key = layout.objectKey(snapshot: snap, asset: asset, resource: photo("IMG_0001.HEIC"))
        let hash = String(Digest.sha256Hex("ABC/L0/001").prefix(8))
        XCTAssertEqual(key, "p/snapshots/20260929T020000Z/2026/03/IMG_0001_\(hash).HEIC")
    }

    func testSameAssetSameNameAcrossSnapshots() {
        let layout = KeyLayout(prefix: "", timeZone: utc)
        let asset = AssetInfo(localIdentifier: "X", creationDate: march)
        let a = layout.objectKey(snapshot: snap, asset: asset, resource: photo("a.jpg"))
        let b = layout.objectKey(snapshot: SnapshotID("20261006T020000Z")!, asset: asset, resource: photo("a.jpg"))
        XCTAssertEqual(a.split(separator: "/").suffix(3), b.split(separator: "/").suffix(3))
    }

    func testSameFilenameDifferentAssetsDoNotCollide() {
        let layout = KeyLayout(prefix: "", timeZone: utc)
        let a = layout.objectKey(snapshot: snap, asset: AssetInfo(localIdentifier: "A", creationDate: march), resource: photo("IMG_0001.HEIC"))
        let b = layout.objectKey(snapshot: snap, asset: AssetInfo(localIdentifier: "B", creationDate: march), resource: photo("IMG_0001.HEIC"))
        XCTAssertNotEqual(a, b)
    }

    func testMonthFolderUsesTimeZone() {
        // 2026-01-01T02:00:00Z is still Dec 31 in Los Angeles.
        let newYear = Date(timeIntervalSince1970: 1_767_232_800)
        let asset = AssetInfo(localIdentifier: "X", creationDate: newYear)
        let utcKey = KeyLayout(prefix: "", timeZone: utc).objectKey(snapshot: snap, asset: asset, resource: photo("a.jpg"))
        let laKey = KeyLayout(prefix: "", timeZone: TimeZone(identifier: "America/Los_Angeles")!)
            .objectKey(snapshot: snap, asset: asset, resource: photo("a.jpg"))
        XCTAssertTrue(utcKey.contains("/2026/01/"))
        XCTAssertTrue(laKey.contains("/2025/12/"))
    }

    func testUndatedAsset() {
        let key = KeyLayout(prefix: "", timeZone: utc)
            .objectKey(snapshot: snap, asset: AssetInfo(localIdentifier: "X", creationDate: nil), resource: photo("a.jpg"))
        XCTAssertTrue(key.hasPrefix("snapshots/20260929T020000Z/undated/a_"))
    }

    func testLivePhotoEditedAndRawResources() {
        let layout = KeyLayout(prefix: "", timeZone: utc)
        let asset = AssetInfo(localIdentifier: "LP", creationDate: march)
        let resources = [
            photo("IMG_0005.HEIC", .photo, 0),
            photo("IMG_0005.MOV", .pairedVideo, 1),
            photo("IMG_0005.HEIC", .fullSizePhoto, 2),
            photo("IMG_0005.MOV", .fullSizePairedVideo, 3),
            photo("IMG_0005.DNG", .alternatePhoto, 4),
        ]
        let keys = layout.objectKeys(snapshot: snap, asset: asset, resources: resources)
        XCTAssertEqual(Set(keys).count, 5)
        let names = keys.map { String($0.split(separator: "/").last!) }
        let hash = String(Digest.sha256Hex("LP").prefix(8))
        XCTAssertEqual(names, [
            "IMG_0005_\(hash).HEIC",
            "IMG_0005_\(hash).MOV",
            "IMG_0005_\(hash)_edited.HEIC",
            "IMG_0005_\(hash)_edited.MOV",
            "IMG_0005_\(hash)_alt.DNG",
        ])
    }

    func testDuplicateResourcesInOneAssetGetCounterSuffix() {
        let layout = KeyLayout(prefix: "", timeZone: utc)
        let asset = AssetInfo(localIdentifier: "D", creationDate: march)
        let keys = layout.objectKeys(snapshot: snap, asset: asset, resources: [photo("a.jpg", .photo, 0), photo("a.jpg", .photo, 1), photo("a.jpg", .photo, 2)])
        XCTAssertEqual(Set(keys).count, 3)
        XCTAssertTrue(keys[1].hasSuffix("_2.jpg"))
        XCTAssertTrue(keys[2].hasSuffix("_3.jpg"))
    }

    func testSanitize() {
        XCTAssertEqual(KeyLayout.sanitize("a/b\\c.jpg"), "a_b_c.jpg")
        XCTAssertEqual(KeyLayout.sanitize("  x.jpg \n"), "x.jpg")
        XCTAssertEqual(KeyLayout.sanitize("..hidden.png"), "hidden.png")
        XCTAssertEqual(KeyLayout.sanitize(""), "file")
        XCTAssertEqual(KeyLayout.sanitize("/"), "_")
        XCTAssertEqual(KeyLayout.sanitize("tab\tname.jpg"), "tab_name.jpg")
        XCTAssertEqual(KeyLayout.sanitize("写真 1.HEIC"), "写真 1.HEIC")
    }

    func testSanitizeCapsLengthAndKeepsExtension() {
        let long = String(repeating: "é", count: 200) + ".HEIC"
        let result = KeyLayout.sanitize(long)
        XCTAssertLessThanOrEqual(result.utf8.count, KeyLayout.maxFilenameBytes)
        XCTAssertTrue(result.hasSuffix(".HEIC"))
    }

    func testSplitFilename() {
        XCTAssertEqual(KeyLayout.splitFilename("a.jpg").stem, "a")
        XCTAssertEqual(KeyLayout.splitFilename("a.jpg").ext, "jpg")
        XCTAssertEqual(KeyLayout.splitFilename("archive.tar.gz").stem, "archive.tar")
        XCTAssertEqual(KeyLayout.splitFilename("noext").ext, "")
        XCTAssertEqual(KeyLayout.splitFilename("trailing.").ext, "")
        XCTAssertEqual(KeyLayout.splitFilename("v1.this is not ext").ext, "")
        XCTAssertEqual(KeyLayout.splitFilename(".profile").stem, ".profile")
    }

    func testSnapshotIDFromCommonPrefix() {
        let layout = KeyLayout(prefix: "p")
        XCTAssertEqual(layout.snapshotID(fromCommonPrefix: "p/snapshots/20260929T020000Z/"), snap)
        XCTAssertNil(layout.snapshotID(fromCommonPrefix: "p/snapshots/garbage/"))
        XCTAssertNil(layout.snapshotID(fromCommonPrefix: "q/snapshots/20260929T020000Z/"))
        XCTAssertNil(layout.snapshotID(fromCommonPrefix: "p/snapshots/20260929T020000Z"))
    }

    func testSnapshotIDFormatAndOrder() {
        XCTAssertEqual(SnapshotID(date: march).rawValue, "20260315T120000Z")
        XCTAssertNil(SnapshotID("2026-03-15"))
        XCTAssertNil(SnapshotID("20261315T120000Z"))
        XCTAssertLessThan(SnapshotID("20260101T000000Z")!, SnapshotID("20260101T000001Z")!)
        XCTAssertEqual(SnapshotID(date: march).date, march)
    }
}
