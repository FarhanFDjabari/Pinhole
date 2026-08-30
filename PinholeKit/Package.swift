// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PinholeKit",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "PinholeKit", targets: ["PinholeKit"])
    ],
    targets: [
        .target(name: "PinholeKit", path: "Sources/PinholeKit")
    ]
)
