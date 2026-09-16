// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RunieKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "RunieKit", targets: ["RunieKit"])
    ],
    targets: [
        .target(name: "RunieKit"),
        .testTarget(name: "RunieKitTests", dependencies: ["RunieKit"])
    ]
)
