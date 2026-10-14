// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AppleDeviceCodegenFixture",
    platforms: [
        .iOS(.v16),
        .watchOS(.v9)
    ],
    products: [
        .library(name: "AppleDeviceCodegenFixture", targets: ["AppleDeviceCodegenFixture"])
    ],
    dependencies: [
        .package(path: "../../../platform/macos")
    ],
    targets: [
        .target(
            name: "AppleDeviceCodegenFixture",
            dependencies: [
                .product(name: "RivetRuntime", package: "macos"),
                .product(name: "RivetDevice", package: "macos")
            ]
        )
    ]
)
