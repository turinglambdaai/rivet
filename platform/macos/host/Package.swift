// swift-tools-version: 6.0

import Foundation
import PackageDescription

guard let rivetRoot = ProcessInfo.processInfo.environment["RIVET_ROOT"],
      !rivetRoot.isEmpty else {
    fatalError("RIVET_ROOT is not set. Build this app through raco rivet build/dev.")
}

guard let racketLibDir = ProcessInfo.processInfo.environment["RIVET_RACKET_LIB_DIR"],
      !racketLibDir.isEmpty else {
    fatalError("RIVET_RACKET_LIB_DIR is not set. Build this app through raco rivet build/dev.")
}

let package = Package(
    name: "RivetHost",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: rivetRoot + "/platform/macos")
    ],
    targets: [
        .executableTarget(
            name: "RivetHost",
            dependencies: [
                .product(name: "RivetRuntime", package: "macos"),
                .product(name: "RivetEmbedding", package: "macos")
            ],
            path: "Sources/RivetHost",
            linkerSettings: [
                .unsafeFlags(["-L", racketLibDir]),
                .linkedLibrary("racketcs"),
                .linkedLibrary("iconv"),
                .linkedLibrary("ncurses"),
                .linkedFramework("CoreFoundation")
            ]
        )
    ]
)
