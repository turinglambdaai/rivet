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
        .library(
            name: "RivetDeviceAppleSecurity",
            targets: ["RivetDeviceAppleSecurity"]
        ),
        .library(name: "RivetDeviceSession", targets: ["RivetDeviceSession"]),
        .library(
            name: "RivetDeviceAppleTransport",
            targets: ["RivetDeviceAppleTransport"]
        ),
        .library(
            name: "RivetDeviceAppleCompanion",
            targets: ["RivetDeviceAppleCompanion"]
        ),
        .library(
            name: "RivetDeviceAppleCompanionUI",
            targets: ["RivetDeviceAppleCompanionUI"]
        ),
        .library(name: "RivetWatchConnectivity", targets: ["RivetWatchConnectivity"]),
        .library(name: "RivetEmbedding", targets: ["RivetEmbedding"]),
        .library(name: "RivetSystem", targets: ["RivetSystem"]),
        .library(name: "RivetUpdate", targets: ["RivetUpdate"]),
        .library(name: "RivetUI", targets: ["RivetUI"])
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
            name: "RivetDeviceAppleSecurity",
            dependencies: ["RivetDevice"],
            path: "Sources/RivetDeviceAppleSecurity",
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .target(
            name: "RivetDeviceSession",
            dependencies: ["RivetDevice", "RivetRuntime"],
            path: "Sources/RivetDeviceSession",
            linkerSettings: [
                .linkedFramework("CryptoKit")
            ]
        ),
        .target(
            name: "RivetDeviceAppleTransport",
            dependencies: ["RivetDevice", "RivetDeviceSession"],
            path: "Sources/RivetDeviceAppleTransport",
            linkerSettings: [
                .linkedFramework("CryptoKit"),
                .linkedFramework("Network"),
                .linkedFramework("Security")
            ]
        ),
        .target(
            name: "RivetDeviceAppleCompanion",
            dependencies: [
                "RivetDevice",
                "RivetDeviceSession",
                "RivetDeviceAppleSecurity",
                "RivetDeviceAppleTransport"
            ],
            path: "Sources/RivetDeviceAppleCompanion",
            linkerSettings: [
                .linkedFramework("Network")
            ]
        ),
        .target(
            name: "RivetDeviceAppleCompanionUI",
            dependencies: [
                "RivetDevice",
                "RivetDeviceAppleTransport",
                "RivetDeviceAppleCompanion"
            ],
            path: "Sources/RivetDeviceAppleCompanionUI"
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
        .target(
            name: "RivetUpdate",
            path: "Sources/RivetUpdate",
            linkerSettings: [
                .linkedFramework("CryptoKit")
            ]
        ),
        .target(
            name: "RivetUI",
            dependencies: ["RivetRuntime"],
            path: "Sources/RivetUI"
        ),
        .testTarget(
            name: "RivetWatchConnectivityTests",
            dependencies: ["RivetWatchConnectivity", "RivetDevice"],
            path: "Tests/RivetWatchConnectivityTests"
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
        ),
        .testTarget(
            name: "RivetDeviceAppleSecurityTests",
            dependencies: ["RivetDevice", "RivetDeviceAppleSecurity"],
            path: "Tests/RivetDeviceAppleSecurityTests"
        ),
        .testTarget(
            name: "RivetDeviceSessionTests",
            dependencies: ["RivetDevice", "RivetDeviceSession"],
            path: "Tests/RivetDeviceSessionTests"
        ),
        .testTarget(
            name: "RivetDeviceAppleTransportTests",
            dependencies: ["RivetDeviceAppleTransport", "RivetDeviceSession"],
            path: "Tests/RivetDeviceAppleTransportTests"
        ),
        .testTarget(
            name: "RivetDeviceAppleCompanionTests",
            dependencies: [
                "RivetDeviceAppleCompanion",
                "RivetDevice",
                "RivetDeviceSession"
            ],
            path: "Tests/RivetDeviceAppleCompanionTests"
        ),
        .testTarget(
            name: "RivetSystemTests",
            dependencies: ["RivetSystem"],
            path: "Tests/RivetSystemTests"
        ),
        .testTarget(
            name: "RivetUpdateTests",
            dependencies: ["RivetUpdate"],
            path: "Tests/RivetUpdateTests"
        ),
        .testTarget(
            name: "RivetUITests",
            dependencies: ["RivetUI"],
            path: "Tests/RivetUITests"
        )
    ]
)
