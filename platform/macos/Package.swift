// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RivetMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "RivetRuntime", targets: ["RivetRuntime"]),
        .library(name: "RivetEmbedding", targets: ["RivetEmbedding"])
    ],
    targets: [
        .target(
            name: "RivetRuntime",
            path: "Sources/RivetRuntime"
        ),
        .target(
            name: "CRivetRacket",
            path: "Sources/CRivetRacket",
            publicHeadersPath: "include"
        ),
        .target(
            name: "RivetEmbedding",
            dependencies: ["RivetRuntime", "CRivetRacket"],
            path: "Sources/RivetEmbedding"
        ),
        .testTarget(
            name: "RivetRuntimeTests",
            dependencies: ["RivetRuntime"],
            path: "Tests/RivetRuntimeTests"
        )
    ]
)
