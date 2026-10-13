// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SimCleanerKit",
    platforms: [.macOS("15.6")],
    products: [
        .library(name: "SimCleanerKit", targets: ["SimCleanerKit"]),
    ],
    targets: [
        .target(name: "SimCleanerKit"),
        .testTarget(name: "SimCleanerKitTests", dependencies: ["SimCleanerKit"]),
    ]
)
