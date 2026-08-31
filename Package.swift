// swift-tools-version:5.9
import PackageDescription

// At the repo root, not in PinholeKit/, because SwiftPM resolves a remote
// package only from a manifest at the root of its repository — there is no
// subpath option for a URL dependency. The sources stay where they belong.
let package = Package(
    name: "PinholeKit",
    // macOS is listed so `swift test` runs the wire and framing tests natively,
    // with no simulator in the loop. The UIKit-dependent sources compile out there.
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "PinholeKit", targets: ["PinholeKit"])
    ],
    targets: [
        .target(name: "PinholeKit", path: "PinholeKit/Sources/PinholeKit"),
        .testTarget(
            name: "PinholeKitTests",
            dependencies: ["PinholeKit"],
            path: "PinholeKit/Tests/PinholeKitTests"
        )
    ]
)
