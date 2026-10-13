import CryptoKit
import Foundation
import Testing
@testable import RivetUpdate

// MARK: - Test vectors

// A fixed seed derives the same Ed25519 pair on every access, so computed
// fixtures stay deterministic (and Sendable) under strict concurrency.
private let keySeed = Data(repeating: 0x42, count: 32)

private var signingKey: Curve25519.Signing.PrivateKey {
    try! Curve25519.Signing.PrivateKey(rawRepresentation: keySeed)
}

private func innerManifestJSON(version: String) -> String {
    let artifact = """
        {"platform":"macos","architecture":"arm64",
         "url":"https://example.com/app.zip","sha256":"00","size":10}
    """
    let x64 = """
        {"platform":"macos","architecture":"x64",
         "url":"https://example.com/app-x64.zip","sha256":"01","size":11}
    """
    return """
        {"version":"\(version)","artifacts":[\(artifact),\(x64)]}
    """
}

private func wrapperData(payloadJSON: String,
                         key: Curve25519.Signing.PrivateKey = signingKey,
                         keyID: String = "test-key",
                         schema: Int = 1,
                         algorithm: String = "ed25519",
                         payloadBase64: String? = nil,
                         signature: Data? = nil) throws -> Data {
    let payload = Data(payloadJSON.utf8)
    let signatureValue = try signature ?? key.signature(for: payload)
    let object: [String: Any] = [
        "schema": schema,
        "payload": payloadBase64 ?? payload.base64EncodedString(),
        "signature": [
            "algorithm": algorithm,
            "key_id": keyID,
            "value": signatureValue.base64EncodedString(),
        ],
    ]
    return try JSONSerialization.data(withJSONObject: object)
}

private var testConfiguration: RivetUpdateConfiguration {
    RivetUpdateConfiguration(
        feedURL: URL(string: "https://example.com/update-manifest.json")!,
        publicKeyBase64: signingKey.publicKey.rawRepresentation.base64EncodedString(),
        keyID: "test-key",
        bundleName: "Taskly.app")
}

// MARK: - Signed-manifest verification

@Test func validSignedManifestDecodes() throws {
    let wrapper = try wrapperData(payloadJSON: innerManifestJSON(version: "1.2.3"))
    let manifest = try RivetUpdateService.verifyManifest(
        wrapper, keyBase64: testConfiguration.publicKeyBase64, keyID: "test-key")
    #expect(manifest.version == "1.2.3")
    #expect(manifest.artifacts.count == 2)
}

@Test func wrongSigningKeyIsRejected() throws {
    let wrapper = try wrapperData(payloadJSON: innerManifestJSON(version: "1.2.3"),
                                  key: Curve25519.Signing.PrivateKey())
    #expect(throws: RivetUpdateError.signatureInvalid) {
        try RivetUpdateService.verifyManifest(
            wrapper, keyBase64: testConfiguration.publicKeyBase64, keyID: "test-key")
    }
}

@Test func wrongKeyIDIsRejected() throws {
    let wrapper = try wrapperData(payloadJSON: innerManifestJSON(version: "1.2.3"),
                                  keyID: "other-key")
    #expect(throws: RivetUpdateError.signatureInvalid) {
        try RivetUpdateService.verifyManifest(
            wrapper, keyBase64: testConfiguration.publicKeyBase64, keyID: "test-key")
    }
}

@Test func tamperedPayloadIsRejected() throws {
    let wrapper = try wrapperData(payloadJSON: innerManifestJSON(version: "9.9.9"),
                                  payloadBase64: Data("{}".utf8).base64EncodedString())
    #expect(throws: RivetUpdateError.signatureInvalid) {
        try RivetUpdateService.verifyManifest(
            wrapper, keyBase64: testConfiguration.publicKeyBase64, keyID: "test-key")
    }
}

@Test func nonEd25519AlgorithmIsRejected() throws {
    let wrapper = try wrapperData(payloadJSON: innerManifestJSON(version: "1.2.3"),
                                  algorithm: "sha256")
    #expect(throws: RivetUpdateError.signatureInvalid) {
        try RivetUpdateService.verifyManifest(
            wrapper, keyBase64: testConfiguration.publicKeyBase64, keyID: "test-key")
    }
}

@Test func shortSignatureIsRejected() throws {
    let wrapper = try wrapperData(payloadJSON: innerManifestJSON(version: "1.2.3"),
                                  signature: Data(repeating: 0, count: 63))
    #expect(throws: RivetUpdateError.signatureInvalid) {
        try RivetUpdateService.verifyManifest(
            wrapper, keyBase64: testConfiguration.publicKeyBase64, keyID: "test-key")
    }
}

@Test func futureSchemaIsRejectedAsMissing() throws {
    let wrapper = try wrapperData(payloadJSON: innerManifestJSON(version: "1.2.3"),
                                  schema: 2)
    #expect(throws: RivetUpdateError.manifestMissing) {
        try RivetUpdateService.verifyManifest(
            wrapper, keyBase64: testConfiguration.publicKeyBase64, keyID: "test-key")
    }
}

@Test func malformedWrapperJSONIsRejected() {
    #expect(throws: RivetUpdateError.manifestMissing) {
        try RivetUpdateService.verifyManifest(
            Data("not json".utf8),
            keyBase64: testConfiguration.publicKeyBase64, keyID: "test-key")
    }
}

@Test func signedButUnparsablePayloadIsRejected() throws {
    let wrapper = try wrapperData(payloadJSON: "{\"version\":")
    #expect(throws: RivetUpdateError.network("manifest unparsable")) {
        try RivetUpdateService.verifyManifest(
            wrapper, keyBase64: testConfiguration.publicKeyBase64, keyID: "test-key")
    }
}

// MARK: - Version comparison

@Test func versionComparisonIsNumericPerSegment() {
    #expect(RivetUpdateService.isVersion("1.2", greaterThan: "1.1.9"))
    #expect(RivetUpdateService.isVersion("0.1.2", greaterThan: "0.1.1"))
    #expect(RivetUpdateService.isVersion("2.10.0", greaterThan: "2.9.9"))
    #expect(!RivetUpdateService.isVersion("2.0.0", greaterThan: "2"))
    #expect(!RivetUpdateService.isVersion("1.0.0", greaterThan: "1.0.0"))
    #expect(!RivetUpdateService.isVersion("0.9", greaterThan: "1.0"))
}

// MARK: - Artifact selection

@Test func artifactSelectionMatchesPlatformAndArchitecture() throws {
    let manifest = try RivetUpdateService.verifyManifest(
        try wrapperData(payloadJSON: innerManifestJSON(version: "1.2.3")),
        keyBase64: testConfiguration.publicKeyBase64, keyID: "test-key")
    #expect(manifest.artifact(forPlatform: "macos", architecture: "arm64")?
        .sha256 == "00")
    #expect(manifest.artifact(forPlatform: "macos", architecture: "x64")?
        .sha256 == "01")
    #expect(manifest.artifact(forPlatform: "windows", architecture: "arm64") == nil)
    #expect(manifest.artifact(forPlatform: "macos", architecture: "riscv") == nil)
}

// MARK: - Configuration validation

@Test func plainHTTPFeedIsRejectedOutsideLoopback() {
    let config = RivetUpdateConfiguration(
        feedURL: URL(string: "http://example.com/update-manifest.json")!,
        publicKeyBase64: testConfiguration.publicKeyBase64,
        keyID: "test-key",
        bundleName: "Taskly.app")
    #expect(throws: RivetUpdateError.invalidConfiguration("feed URL must use HTTPS outside loopback drills")) {
        try RivetUpdateService(configuration: config)
    }
}

@Test func loopbackHTTPFeedIsAcceptedForDrills() throws {
    let config = RivetUpdateConfiguration(
        feedURL: URL(string: "http://127.0.0.1:8787/update-manifest.json")!,
        publicKeyBase64: testConfiguration.publicKeyBase64,
        keyID: "test-key",
        bundleName: "Taskly.app")
    _ = try RivetUpdateService(configuration: config)
}

@Test func bareBundleNameIsRejected() {
    let config = RivetUpdateConfiguration(
        feedURL: testConfiguration.feedURL,
        publicKeyBase64: testConfiguration.publicKeyBase64,
        keyID: "test-key",
        bundleName: "Taskly")
    #expect(throws: RivetUpdateError.self) {
        try RivetUpdateService(configuration: config)
    }
}

@Test func emptyKeyIDIsRejected() {
    let config = RivetUpdateConfiguration(
        feedURL: testConfiguration.feedURL,
        publicKeyBase64: testConfiguration.publicKeyBase64,
        keyID: "",
        bundleName: "Taskly.app")
    #expect(throws: RivetUpdateError.invalidConfiguration("key id must not be empty")) {
        try RivetUpdateService(configuration: config)
    }
}

@Test func nonEd25519PublicKeyIsRejected() {
    let config = RivetUpdateConfiguration(
        feedURL: testConfiguration.feedURL,
        publicKeyBase64: Data(repeating: 1, count: 16).base64EncodedString(),
        keyID: "test-key",
        bundleName: "Taskly.app")
    #expect(throws: RivetUpdateError.badPublicKey) {
        try RivetUpdateService(configuration: config)
    }
}

// MARK: - Installed-bundle detection

@Test func installedBundleDetectionAppliesToInjectedPaths() throws {
    let installed = try RivetUpdateService(
        configuration: testConfiguration,
        bundlePath: "/Applications/Taskly.app",
        currentVersion: "1.0.0")
    #expect(installed.installedBundleURL != nil)
    #expect(installed.canUpdate)

    let userInstalled = try RivetUpdateService(
        configuration: testConfiguration,
        bundlePath: "/Users/tester/Applications/Taskly.app")
    #expect(userInstalled.installedBundleURL != nil)

    let development = try RivetUpdateService(
        configuration: testConfiguration,
        bundlePath: "/tmp/rivet-build/Taskly.app")
    #expect(development.installedBundleURL == nil)
    #expect(!development.canUpdate)
}

// MARK: - Swap script and hashing

@Test func swapScriptQuotesPathsAndRestoresBackup() {
    let script = RivetUpdateService.swapScript(
        bundlePath: "/Applications/Ta skly.app",
        newBundlePath: "/tmp/rivet-update/unpacked/Ta skly.app")
    #expect(script.contains("sleep 1"))
    #expect(script.contains("rm -rf '/Applications/Ta skly.app.old'"))
    #expect(script.contains("mv '/Applications/Ta skly.app' '/Applications/Ta skly.app.old'"))
    // The failed-move branch restores the previous bundle before exiting.
    #expect(script.contains("mv '/Applications/Ta skly.app.old' '/Applications/Ta skly.app'"))
    #expect(script.contains("open '/Applications/Ta skly.app'"))
    #expect(script.hasSuffix("exit 1"))
}

@Test func swapScriptEscapesSingleQuotesInPaths() {
    let script = RivetUpdateService.swapScript(
        bundlePath: "/Applications/it's.app",
        newBundlePath: "/tmp/x/it's.app")
    #expect(script.contains("'\\''"))
}

@Test func sha256HexMatchesKnownVector() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("rivet-update-test-\(UUID()).txt")
    try Data("abc".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(try RivetUpdateService.sha256Hex(ofFileAt: url)
        == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
}

// MARK: - Networked tests (serialized: they share the URLProtocol stub)

private enum StubResponse {
    case success(Data)
    case httpStatus(Int, Data)
    case failure(URLError)
    case parkForever
}

private final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> StubResponse)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        switch handler(request) {
        case .success(let data):
            deliver(status: 200, data: data)
        case .httpStatus(let status, let data):
            deliver(status: status, data: data)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .parkForever:
            break
        }
    }

    private func deliver(status: Int, data: Data) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": String(data.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    func append(_ value: Int) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }
    var snapshot: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

@Suite(.serialized)
struct RivetUpdateNetworkedTests {
    private func stubbedConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return config
    }

    @Test func downloaderDeliversExactBytesWithMonotonicProgress() async throws {
        let payload = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0) })
        StubURLProtocol.handler = { _ in .success(payload) }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("rivet-update-test-\(UUID()).bin")
        defer { try? FileManager.default.removeItem(at: destination) }
        let progress = ProgressLog()
        let downloader = RivetArtifactDownloader(
            destination: destination,
            expectedSize: payload.count,
            sessionConfiguration: stubbedConfiguration(),
            onProgress: { progress.append($0) })
        try await downloader.run(from: URL(string: "https://example.com/a.zip")!)
        #expect(try Data(contentsOf: destination) == payload)
        let values = progress.snapshot
        #expect(values == values.sorted())
        #expect(values.allSatisfy { (0...100).contains($0) })
        if let last = values.last { #expect(last == 100) }
    }

    @Test func downloaderFailsFastOnContentLengthMismatch() async throws {
        let payload = Data(repeating: 7, count: 4096)
        StubURLProtocol.handler = { _ in .success(payload) }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("rivet-update-test-\(UUID()).bin")
        defer { try? FileManager.default.removeItem(at: destination) }
        let downloader = RivetArtifactDownloader(
            destination: destination,
            expectedSize: payload.count + 1,
            sessionConfiguration: stubbedConfiguration(),
            onProgress: { _ in })
        do {
            try await downloader.run(from: URL(string: "https://example.com/a.zip")!)
            Issue.record("expected a sizeMismatch failure")
        } catch let error as RivetUpdateError {
            guard case .sizeMismatch(let expected, let actual) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(expected == payload.count + 1)
            #expect(actual == payload.count)
        }
    }

    @Test func downloaderSurfacesTransportFailures() async throws {
        StubURLProtocol.handler = { _ in .failure(URLError(.notConnectedToInternet)) }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("rivet-update-test-\(UUID()).bin")
        defer { try? FileManager.default.removeItem(at: destination) }
        let downloader = RivetArtifactDownloader(
            destination: destination,
            expectedSize: 128,
            sessionConfiguration: stubbedConfiguration(),
            onProgress: { _ in })
        do {
            try await downloader.run(from: URL(string: "https://example.com/a.zip")!)
            Issue.record("expected a transport failure")
        } catch let error as URLError {
            #expect(error.code == .notConnectedToInternet)
        }
    }

    @Test func downloaderCancellationAlwaysResumes() async throws {
        StubURLProtocol.handler = { _ in .parkForever }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("rivet-update-test-\(UUID()).bin")
        defer { try? FileManager.default.removeItem(at: destination) }
        let downloader = RivetArtifactDownloader(
            destination: destination,
            expectedSize: 128,
            sessionConfiguration: stubbedConfiguration(),
            onProgress: { _ in })
        let task = Task {
            try await downloader.run(from: URL(string: "https://example.com/a.zip")!)
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        do {
            try await task.value
            Issue.record("expected a cancellation failure")
        } catch let error as URLError {
            // Task cancellation invalidates the session, so the parked
            // continuation always resumes promptly (the escape hatch a
            // stuck download sheet needs).
            #expect(error.code == .cancelled)
        }
    }

    @Test func checkReportsAvailableForNewerSignedRelease() async throws {
        let wrapper = try wrapperData(payloadJSON: innerManifestJSON(version: "1.2.3"))
        StubURLProtocol.handler = { _ in .success(wrapper) }
        let service = try RivetUpdateService(
            configuration: testConfiguration,
            bundlePath: "/Applications/Taskly.app",
            currentVersion: "1.0.0",
            sessionConfiguration: stubbedConfiguration())
        let result = try await service.check()
        guard case .available(let manifest) = result else {
            Issue.record("expected an available update")
            return
        }
        #expect(manifest.version == "1.2.3")
    }

    @Test func checkReportsUpToDateForSameVersion() async throws {
        let wrapper = try wrapperData(payloadJSON: innerManifestJSON(version: "1.0.0"))
        StubURLProtocol.handler = { _ in .success(wrapper) }
        let service = try RivetUpdateService(
            configuration: testConfiguration,
            bundlePath: "/Applications/Taskly.app",
            currentVersion: "1.0.0",
            sessionConfiguration: stubbedConfiguration())
        let result = try await service.check()
        guard case .upToDate = result else {
            Issue.record("expected up-to-date")
            return
        }
    }

    @Test func checkRejectsBadHTTPStatus() async throws {
        StubURLProtocol.handler = { _ in .httpStatus(404, Data("missing".utf8)) }
        let service = try RivetUpdateService(
            configuration: testConfiguration,
            bundlePath: "/Applications/Taskly.app",
            currentVersion: "1.0.0",
            sessionConfiguration: stubbedConfiguration())
        do {
            _ = try await service.check()
            Issue.record("expected an HTTP failure")
        } catch let error as RivetUpdateError {
            guard case .network(let message) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(message.contains("404"))
        }
    }

    @Test func checkRefusesDevelopmentCopies() async throws {
        // No network involved: the installed-bundle guard fires first.
        let service = try RivetUpdateService(
            configuration: testConfiguration,
            bundlePath: "/tmp/rivet-build/Taskly.app")
        await #expect(throws: RivetUpdateError.notInstalled) {
            try await service.check()
        }
    }
}
