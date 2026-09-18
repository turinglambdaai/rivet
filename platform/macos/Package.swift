// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RivetMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "RivetRuntime", targets: ["RivetRuntime"]),
        .library(name: "RivetEmbedding", targets: ["RivetEmbedding"]),
        .executable(name: "RivetIntegration", targets: ["RivetIntegration"])
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
        .executableTarget(
            name: "RivetIntegration",
            dependencies: ["RivetRuntime", "RivetEmbedding"],
            path: "Integration/Sources"
        ),
        .testTarget(
            name: "RivetRuntimeTests",
            dependencies: ["RivetRuntime"],
            path: "Tests/RivetRuntimeTests"
        )
    ]
)
