// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RunieKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "RunieKit", targets: ["RunieKit"]),
        .executable(name: "runie-smoke", targets: ["runie-smoke"])
    ],
    targets: [
        .target(name: "RunieKit"),
        .executableTarget(name: "runie-smoke", dependencies: ["RunieKit"]),
        .testTarget(
            name: "RunieKitTests",
            dependencies: ["RunieKit"],
            resources: [.copy("Fixtures")]
        )
    ]
)
