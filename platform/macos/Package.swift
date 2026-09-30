// swift-tools-version: 6.0

import Foundation
import PackageDescription

let macosMinVersion = ProcessInfo.processInfo.environment["RIVET_MACOS_MIN_VERSION"] ?? "14.0"

let package = Package(
    name: "RivetApple",
    platforms: [
        .macOS(macosMinVersion),
        .iOS(.v16),
        .watchOS(.v9)
    ],
    products: [
        .library(name: "RivetRuntime", targets: ["RivetRuntime"]),
        .library(name: "RivetDevice", targets: ["RivetDevice"]),
        .library(name: "RivetWatchConnectivity", targets: ["RivetWatchConnectivity"]),
        .library(name: "RivetEmbedding", targets: ["RivetEmbedding"]),
        .library(name: "RivetSystem", targets: ["RivetSystem"])
    ],
    targets: [
        .target(
            name: "RivetRuntime",
            path: "Sources/RivetRuntime"
        ),
        .target(
            name: "RivetDevice",
            path: "Sources/RivetDevice"
        ),
        .target(
            name: "RivetWatchConnectivity",
            dependencies: ["RivetDevice"],
            path: "Sources/RivetWatchConnectivity"
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
        .target(
            name: "RivetSystem",
            path: "Sources/RivetSystem",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications")
            ]
        ),
        .testTarget(
            name: "RivetRuntimeTests",
            dependencies: ["RivetRuntime"],
            path: "Tests/RivetRuntimeTests"
        ),
        .testTarget(
            name: "RivetDeviceTests",
            dependencies: ["RivetDevice"],
            path: "Tests/RivetDeviceTests"
        )
    ]
)
