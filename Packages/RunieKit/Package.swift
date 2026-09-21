// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RunieKit",
    defaultLocalization: "ru",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "RunieKit", targets: ["RunieKit"]),
        .executable(name: "runie-smoke", targets: ["runie-smoke"]),
        .executable(name: "runie-suggest", targets: ["runie-suggest"])
    ],
    targets: [
        .target(name: "RunieKit", resources: [.process("Resources")]),
        .executableTarget(name: "runie-smoke", dependencies: ["RunieKit"]),
        .executableTarget(name: "runie-suggest", dependencies: ["RunieKit"]),
        .testTarget(
            name: "RunieKitTests",
            dependencies: ["RunieKit"],
            resources: [.copy("Fixtures")]
        )
    ]
)
