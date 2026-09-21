// swift-tools-version: 6.0

import Foundation
import PackageDescription

let macosMinVersion = ProcessInfo.processInfo.environment["RIVET_MACOS_MIN_VERSION"] ?? "14.0"

let package = Package(
    name: "RivetMac",
    platforms: [
        .macOS(macosMinVersion)
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
