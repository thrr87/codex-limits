// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "CodexLimits",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CodexLimits", targets: ["CodexLimits"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            exact: "2.9.5"
        )
    ],
    targets: [
        .executableTarget(
            name: "CodexLimits",
            dependencies: ["Sparkle"]
        ),
        .testTarget(
            name: "CodexLimitsTests",
            dependencies: ["CodexLimits"],
            resources: [.copy("Fixtures")]
        )
    ]
)
