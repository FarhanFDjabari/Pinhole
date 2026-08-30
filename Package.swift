// swift-tools-version:5.9
import PackageDescription

// At the repo root, not in PinholeKit/, because SwiftPM resolves a remote
// package only from a manifest at the root of its repository — there is no
// subpath option for a URL dependency. The sources stay where they belong.
let package = Package(
    name: "PinholeKit",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "PinholeKit", targets: ["PinholeKit"])
    ],
    targets: [
        .target(name: "PinholeKit", path: "PinholeKit/Sources/PinholeKit")
    ]
)
