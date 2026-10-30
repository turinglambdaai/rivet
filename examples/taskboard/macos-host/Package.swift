// swift-tools-version: 6.0

import PackageDescription

import Foundation

guard let racketFrameworkDir = ProcessInfo.processInfo.environment["RIVET_RACKET_FRAMEWORK_DIR"],
      !racketFrameworkDir.isEmpty else {
    fatalError("RIVET_RACKET_FRAMEWORK_DIR is not set. Build this app through raco rivet build/dev.")
}

let macosMinVersion = ProcessInfo.processInfo.environment["RIVET_MACOS_MIN_VERSION"] ?? "14.0"

let package = Package(
    name: "RivetHost",
    platforms: [.macOS(macosMinVersion)],
    dependencies: [
        .package(url: "https://github.com/turlamai/rivet.git", from: "0.10.0")
    ],
    targets: [
        .executableTarget(
            name: "RivetHost",
            dependencies: [
                .product(name: "RivetRuntime", package: "rivet"),
                .product(name: "RivetDevice", package: "rivet"),
                .product(name: "RivetEmbedding", package: "rivet"),
                .product(name: "RivetSystem", package: "rivet"),
                .product(name: "RivetUI", package: "rivet")
            ],
            path: "Sources/RivetHost",
            linkerSettings: [
                .unsafeFlags(["-F", racketFrameworkDir]),
                .linkedFramework("Racket")
            ]
        )
    ]
)
