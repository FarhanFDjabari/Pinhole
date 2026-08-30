// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SimCamKit",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "SimCamKit", targets: ["SimCamKit"])
    ],
    targets: [
        .target(name: "SimCamKit", path: "Sources/SimCamKit")
    ]
)
