// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ModelProviders",
    platforms: [
        .macOS(.v15),
        .iOS(.v18)
    ],
    products: [
        .library(
            name: "ModelProviders",
            targets: ["ModelProviders"]
        )
    ],
    dependencies: [
        .package(path: "../AgentCore")
    ],
    targets: [
        .target(
            name: "ModelProviders",
            dependencies: [
                .product(name: "AgentCore", package: "AgentCore")
            ]
        ),
        .testTarget(
            name: "ModelProvidersTests",
            dependencies: ["ModelProviders", "AgentCore"]
        )
    ]
)
