// swift-tools-version: 6.0
//
// Root manifest so downstream hosts depend on rivet as a released SwiftPM
// package (issue #238):
//
//     .package(url: "https://github.com/turinglambdaai/rivet.git",
//              from: "0.11.0")
//
// The in-repo platform packages under platform/ keep their own manifests
// for path-based consumption from `raco rivet build` environments; this
// root package exposes the same products from a tag.

import PackageDescription

let package = Package(
    name: "rivet",
    platforms: [
        .macOS(.v14),
        .iOS(.v16),
        .watchOS(.v9)
    ],
    products: [
        .library(name: "RivetRuntime", targets: ["RivetRuntime"]),
        .library(name: "RivetDevice", targets: ["RivetDevice"]),
        .library(name: "RivetWatchConnectivity", targets: ["RivetWatchConnectivity"]),
        .library(name: "RivetEmbedding", targets: ["RivetEmbedding"]),
        .library(name: "RivetSystem", targets: ["RivetSystem"]),
        .library(name: "RivetUpdate", targets: ["RivetUpdate"]),
        .library(name: "RivetUI", targets: ["RivetUI"])
    ],
    targets: [
        .target(
            name: "RivetRuntime",
            path: "platform/macos/Sources/RivetRuntime"
        ),
        .target(
            name: "RivetDevice",
            path: "platform/macos/Sources/RivetDevice"
        ),
        .target(
            name: "RivetWatchConnectivity",
            dependencies: ["RivetDevice"],
            path: "platform/macos/Sources/RivetWatchConnectivity"
        ),
        .target(
            name: "CRivetRacket",
            path: "platform/macos/Sources/CRivetRacket",
            publicHeadersPath: "include"
        ),
        .target(
            name: "RivetEmbedding",
            dependencies: ["RivetRuntime", "CRivetRacket"],
            path: "platform/macos/Sources/RivetEmbedding"
        ),
        .target(
            name: "RivetSystem",
            path: "platform/macos/Sources/RivetSystem",
            swiftSettings: [.enableExperimentalFeature("IsolatedDeinit")],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications")
            ]
        ),
        .target(
            name: "RivetUI",
            dependencies: ["RivetRuntime"],
            path: "platform/macos/Sources/RivetUI"
        ),
        .target(
            name: "RivetUpdate",
            path: "platform/macos/Sources/RivetUpdate",
            linkerSettings: [
                .linkedFramework("CryptoKit")
            ]
        ),
        .testTarget(
            name: "RivetRuntimeTests",
            dependencies: ["RivetRuntime"],
            path: "platform/macos/Tests/RivetRuntimeTests"
        ),
        .testTarget(
            name: "RivetDeviceTests",
            dependencies: ["RivetDevice"],
            path: "platform/macos/Tests/RivetDeviceTests"
        ),
        .testTarget(
            name: "RivetSystemTests",
            dependencies: ["RivetSystem"],
            path: "platform/macos/Tests/RivetSystemTests"
        ),
        .testTarget(
            name: "RivetUpdateTests",
            dependencies: ["RivetUpdate"],
            path: "platform/macos/Tests/RivetUpdateTests"
        )
    ]
)
