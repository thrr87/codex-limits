// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "CodexLimits",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CodexLimits", targets: ["CodexLimits"]),
        .executable(
            name: "CodexLimitsClaudeRelay",
            targets: ["CodexLimitsClaudeRelay"]
        )
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
            dependencies: ["ClaudeIntegrationCore", "Sparkle"]
        ),
        .target(name: "ClaudeIntegrationCore"),
        .executableTarget(
            name: "CodexLimitsClaudeRelay",
            dependencies: ["ClaudeIntegrationCore"]
        ),
        .testTarget(
            name: "CodexLimitsTests",
            dependencies: ["ClaudeIntegrationCore", "CodexLimits"],
            resources: [.copy("Fixtures")]
        )
    ]
)
