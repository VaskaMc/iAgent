// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentCore",
    platforms: [
        .macOS(.v15),
        .iOS(.v18)
    ],
    products: [
        .library(
            name: "AgentCore",
            targets: ["AgentCore"]
        )
    ],
    targets: [
        .target(
            name: "AgentCore"
        ),
        .testTarget(
            name: "AgentCoreTests",
            dependencies: ["AgentCore"]
        )
    ]
)
