// swift-tools-version:6.0
import PackageDescription

// ShoeboxCore holds everything that does not need PhotoKit: S3 signing and
// client, key layout, scheduling, retention and the backup engine itself.
// Tests run on the iOS Simulator (see .github/workflows/ci.yml).
let package = Package(
    name: "ShoeboxCore",
    platforms: [.iOS("26.1")],
    products: [
        .library(name: "ShoeboxCore", targets: ["ShoeboxCore"]),
    ],
    targets: [
        .target(name: "ShoeboxCore"),
        .testTarget(name: "ShoeboxCoreTests", dependencies: ["ShoeboxCore"]),
    ],
    swiftLanguageModes: [.v5]
)
