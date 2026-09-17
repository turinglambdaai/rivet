// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RivetMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "RivetRuntime", targets: ["RivetRuntime"])
    ],
    targets: [
        .target(
            name: "RivetRuntime",
            path: "Sources/RivetRuntime"
        ),
        .testTarget(
            name: "RivetRuntimeTests",
            dependencies: ["RivetRuntime"],
            path: "Tests/RivetRuntimeTests"
        )
    ]
)
