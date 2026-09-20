// swift-tools-version: 6.0

import Foundation
import PackageDescription

guard let rivetRoot = ProcessInfo.processInfo.environment["RIVET_ROOT"],
      !rivetRoot.isEmpty else {
    fatalError("RIVET_ROOT is required")
}

guard let racketFrameworkDir = ProcessInfo.processInfo.environment["RIVET_RACKET_FRAMEWORK_DIR"],
      !racketFrameworkDir.isEmpty else {
    fatalError("RIVET_RACKET_FRAMEWORK_DIR is required")
}

let package = Package(
    name: "RivetIntegration",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: rivetRoot + "/platform/macos")
    ],
    targets: [
        .executableTarget(
            name: "RivetIntegration",
            dependencies: [
                .product(name: "RivetRuntime", package: "macos"),
                .product(name: "RivetEmbedding", package: "macos")
            ],
            path: "Sources",
            linkerSettings: [
                .unsafeFlags(["-F", racketFrameworkDir]),
                .linkedFramework("Racket")
            ]
        )
    ]
)
