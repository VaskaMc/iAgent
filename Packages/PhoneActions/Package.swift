// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PhoneActions",
    products: [
        .library(
            name: "PhoneActions",
            targets: ["PhoneActions"]
        )
    ],
    dependencies: [
        .package(path: "../AgentCore")
    ],
    targets: [
        .target(
            name: "PhoneActions",
            dependencies: [
                .product(name: "AgentCore", package: "AgentCore")
            ]
        ),
        .testTarget(
            name: "PhoneActionsTests",
            dependencies: ["PhoneActions", "AgentCore"]
        )
    ]
)
