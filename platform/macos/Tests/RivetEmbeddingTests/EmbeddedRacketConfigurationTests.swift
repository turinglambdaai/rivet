import Foundation
import Testing
@testable import RivetEmbedding

private func createFile(_ url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    #expect(FileManager.default.createFile(atPath: url.path, contents: Data()))
}

private func createLayout(at root: URL) throws {
    try createFile(root.appendingPathComponent("runtime/petite.boot"))
    try createFile(root.appendingPathComponent("runtime/scheme.boot"))
    try createFile(root.appendingPathComponent("runtime/racket.boot"))
    try createFile(root.appendingPathComponent("res/core.zo"))
}

@Test func resolverPrefersThePackagedResourceLayout() throws {
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let resources = temporary.appendingPathComponent("App.app/Contents/Resources", isDirectory: true)
    let staged = temporary.appendingPathComponent("staged", isDirectory: true)
    try createLayout(at: resources)
    try createLayout(at: staged)

    let executable = staged.appendingPathComponent("RivetHost")
    let configuration = try EmbeddedRacketConfiguration.resolve(
        executable: executable,
        candidateRoots: [resources, staged],
        moduleName: "sample-backend",
        entryName: "launch",
        maxPendingRequests: 7
    )

    #expect(configuration.executable == executable)
    #expect(configuration.petiteBoot == resources.appendingPathComponent("runtime/petite.boot"))
    #expect(configuration.schemeBoot == resources.appendingPathComponent("runtime/scheme.boot"))
    #expect(configuration.racketBoot == resources.appendingPathComponent("runtime/racket.boot"))
    #expect(configuration.core == resources.appendingPathComponent("res/core.zo"))
    #expect(configuration.moduleName == "sample-backend")
    #expect(configuration.entryName == "launch")
    #expect(configuration.maxPendingRequests == 7)
}

@Test func resolverFallsBackToTheStagedExecutableLayout() throws {
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let incompleteResources = temporary.appendingPathComponent("Resources", isDirectory: true)
    let staged = temporary.appendingPathComponent("staged", isDirectory: true)
    try createLayout(at: staged)
    try createFile(incompleteResources.appendingPathComponent("runtime/petite.boot"))

    let executable = staged.appendingPathComponent("RivetHost")
    let configuration = try EmbeddedRacketConfiguration.resolve(
        executable: executable,
        candidateRoots: [incompleteResources, staged],
        moduleName: "backend",
        entryName: "start",
        maxPendingRequests: 1024
    )

    #expect(configuration.core == staged.appendingPathComponent("res/core.zo"))
}

@Test func resolverRejectsIncompleteLayoutsWithSearchedRoots() throws {
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let first = temporary.appendingPathComponent("first", isDirectory: true)
    let second = temporary.appendingPathComponent("second", isDirectory: true)
    try createFile(first.appendingPathComponent("runtime/petite.boot"))
    try FileManager.default.createDirectory(
        at: second.appendingPathComponent("res/core.zo", isDirectory: true),
        withIntermediateDirectories: true
    )

    #expect(throws: EmbeddedRacketConfigurationError.self) {
        try EmbeddedRacketConfiguration.resolve(
            executable: temporary.appendingPathComponent("RivetHost"),
            candidateRoots: [first, second, first],
            moduleName: "backend",
            entryName: "start",
            maxPendingRequests: 1024
        )
    }

    do {
        _ = try EmbeddedRacketConfiguration.resolve(
            executable: temporary.appendingPathComponent("RivetHost"),
            candidateRoots: [first, second, first],
            moduleName: "backend",
            entryName: "start",
            maxPendingRequests: 1024
        )
        Issue.record("expected an incomplete layout to be rejected")
    } catch let error as EmbeddedRacketConfigurationError {
        #expect(error.description.contains(first.path))
        #expect(error.description.contains(second.path))
        #expect(error.description.components(separatedBy: first.path).count == 2)
        #expect(error.description.contains("runtime/racket.boot"))
        #expect(error.description.contains("res/core.zo"))
    }
}
