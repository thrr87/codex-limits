// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "CodexLimits",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CodexLimits", targets: ["CodexLimits"])
    ],
    targets: [
        .executableTarget(name: "CodexLimits"),
        .testTarget(name: "CodexLimitsTests", dependencies: ["CodexLimits"])
    ]
)
