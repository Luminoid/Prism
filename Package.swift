// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Prism",
    platforms: [
        .iOS(.v18),
        .macCatalyst(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "PrismCore", targets: ["PrismCore"]),
        .library(name: "PrismUI", targets: ["PrismUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/SnapKit/SnapKit.git", from: "5.7.0"),
    ],
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
                .product(name: "SnapKit", package: "SnapKit"),
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
