// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Prism",
    platforms: [
        .iOS(.v18),
        .macCatalyst(.v18),
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
            path: "Sources/PrismCore",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .target(
            name: "PrismUI",
            dependencies: [
                "PrismCore",
            ],
            path: "Sources/PrismUI",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableExperimentalFeature("StrictConcurrency"),
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
