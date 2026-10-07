// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "Prism",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v18),
    ],
    products: [
        .library(name: "PrismCore", targets: ["PrismCore"]),
        .library(name: "PrismUI", targets: ["PrismUI"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "PrismCore",
            dependencies: [],
            path: "Sources/PrismCore"
        ),
        .target(
            name: "PrismUI",
            dependencies: [
                "PrismCore",
            ],
            path: "Sources/PrismUI",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
            ]
        ),
        .testTarget(
            name: "PrismCoreTests",
            dependencies: ["PrismCore"],
            path: "Tests/PrismCoreTests"
        ),
        .testTarget(
            name: "PrismUITests",
            dependencies: ["PrismUI"],
            path: "Tests/PrismUITests"
        ),
    ]
)
