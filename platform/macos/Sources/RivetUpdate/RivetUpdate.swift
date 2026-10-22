import CryptoKit
import Foundation

#if canImport(AppKit)
import AppKit
#endif

/// Host-side online update client for installed `.app` bundles.
///
/// Rivet's engine-side `rivet/distribution` owns manifest trust, verified
/// downloads, and portable installation transactions. This module is the
/// native half for applications whose macOS host performs the update itself:
/// an authenticated manifest check, a bounded delegate-driven artifact
/// download, SHA-256 and size verification against the signed manifest,
/// `ditto` unpacking, bundle-version confirmation, and an atomic
/// swap-with-rollback that relaunches the application.
///
/// The downloader is delegate-driven on purpose. Byte-iterating
/// `URLSession.AsyncBytes` can park its continuation forever when the
/// stream's end-of-stream flag never surfaces (observed live against the
/// GitHub CDN: all bytes delivered, the loop never wakes, the update sheet
/// sticks at 100%). The delegate's `didFinishDownloadingTo` /
/// `didCompleteWithError` are definitive, and the request/resource timeout
/// intervals bound a silent stall. Hosts driving this from SwiftUI must keep
/// an explicit Cancel affordance while a transfer is running; a bounded
/// download that cannot be dismissed is a defect.
public struct RivetUpdateConfiguration: Sendable {
    /// Release feed publishing the signed wrapper (`update-manifest.json`).
    /// HTTPS is required; literal loopback hosts are accepted for local
    /// drills and tests only.
    public let feedURL: URL

    /// Ed25519 public key (base64, raw 32 bytes) paired with the release
    /// signing key.
    public let publicKeyBase64: String

    /// Key identity the manifest signature must carry. Rotation ships a
    /// client trusting the next key before releases stop being signed with
    /// this one.
    public let keyID: String

    /// Installed bundle file name, for example `"Taskly.app"`.
    public let bundleName: String

    /// Per-request idle deadline in seconds; bounds a silent stall.
    public let requestTimeout: TimeInterval

    /// Whole-transfer deadline in seconds.
    public let resourceTimeout: TimeInterval

    public init(feedURL: URL,
                publicKeyBase64: String,
                keyID: String,
                bundleName: String,
                requestTimeout: TimeInterval = 60,
                resourceTimeout: TimeInterval = 600) {
        self.feedURL = feedURL
        self.publicKeyBase64 = publicKeyBase64
        self.keyID = keyID
        self.bundleName = bundleName
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
    }
}

public enum RivetUpdateError: Error, LocalizedError, Equatable {
    case invalidConfiguration(String)
    case notInstalled
    case badPublicKey
    case manifestMissing
    case signatureInvalid
    case checksumMismatch
    case sizeMismatch(expected: Int, actual: Int)
    case versionMismatch(expected: String, got: String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let reason):
            return "update configuration is invalid: \(reason)"
        case .notInstalled: return "not an installed app bundle"
        case .badPublicKey: return "embedded public key is invalid"
        case .manifestMissing: return "release has no update manifest"
        case .signatureInvalid: return "manifest signature check failed"
        case .checksumMismatch: return "downloaded archive failed the sha256 check"
        case .sizeMismatch(let expected, let actual):
            return "downloaded size \(actual) != signed size \(expected)"
        case .versionMismatch(let expected, let got):
            return "bundle version \(got) != manifest \(expected)"
        case .network(let message): return message
        }
    }
}

/// The verified release manifest, decoded only after its Ed25519 signature
/// was checked over the exact payload bytes.
public struct RivetUpdateManifest: Decodable, Sendable, Equatable {
    public struct Artifact: Decodable, Sendable, Equatable {
        public let platform: String
        public let architecture: String
        public let url: URL
        public let sha256: String
        public let size: Int
    }

    public let version: String
    public let artifacts: [Artifact]

    /// The release feed carries one artifact per platform × architecture;
    /// each built host targets exactly one architecture, so the match is
    /// compile-time ("x64" on Intel builds, "arm64" on Apple silicon).
    public static let hostArchitecture: String = {
        #if arch(x86_64)
        return "x64"
        #elseif arch(arm64)
        return "arm64"
        #else
        #error("unsupported macOS architecture")
        #endif
    }()

    public func artifact(forPlatform platform: String = "macos",
                         architecture: String = RivetUpdateManifest.hostArchitecture) -> Artifact? {
        artifacts.first {
            $0.platform == platform && $0.architecture == architecture
        }
    }
}

public enum RivetUpdateCheckResult: Sendable {
    case upToDate
    case available(RivetUpdateManifest)
}

/// One application's update client. Configure once at startup; `check` and
/// `downloadAndInstall` are free to interleave with normal UI work.
public final class RivetUpdateService: Sendable {
    private let configuration: RivetUpdateConfiguration
    private let session: URLSession
    /// Test seams for the runtime environment; nil = derive from Bundle.main.
    private let injectedBundlePath: String?
    private let injectedCurrentVersion: String?

    public init(configuration: RivetUpdateConfiguration,
                bundlePath: String? = nil,
                currentVersion: String? = nil,
                sessionConfiguration: URLSessionConfiguration? = nil)
        throws {
        self.configuration = try Self.validated(configuration)
        let config = sessionConfiguration ?? URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = configuration.requestTimeout
        config.timeoutIntervalForResource = configuration.resourceTimeout
        self.session = URLSession(configuration: config)
        self.injectedBundlePath = bundlePath
        self.injectedCurrentVersion = currentVersion
    }

    /// Fail closed on configurations that would only break mid-update:
    /// non-HTTPS non-loopback feeds, empty key identities, malformed bundle
    /// names, and public keys that are not the 32 raw Ed25519 bytes.
    private static func validated(_ configuration: RivetUpdateConfiguration)
        throws -> RivetUpdateConfiguration {
        guard configuration.keyID.isEmpty == false else {
            throw RivetUpdateError.invalidConfiguration("key id must not be empty")
        }
        guard configuration.bundleName.hasSuffix(".app"),
              configuration.bundleName.contains("/") == false,
              configuration.bundleName.count > ".app".count else {
            throw RivetUpdateError.invalidConfiguration(
                "bundle name must be a bare \"<Name>.app\" file name")
        }
        guard let scheme = configuration.feedURL.scheme?.lowercased() else {
            throw RivetUpdateError.invalidConfiguration("feed URL has no scheme")
        }
        if scheme != "https" {
            let host = configuration.feedURL.host ?? ""
            guard ["localhost", "127.0.0.1", "::1"].contains(host.lowercased()) else {
                throw RivetUpdateError.invalidConfiguration(
                    "feed URL must use HTTPS outside loopback drills")
            }
        }
        guard configuration.requestTimeout > 0, configuration.resourceTimeout > 0 else {
            throw RivetUpdateError.invalidConfiguration(
                "request and resource timeouts must be positive")
        }
        guard let keyData = Data(base64Encoded: configuration.publicKeyBase64),
              keyData.count == 32 else {
            throw RivetUpdateError.badPublicKey
        }
        return configuration
    }

    // MARK: - Environment

    /// The installed bundle this copy can update in place, or nil for
    /// development copies (not under /Applications or ~/Applications). The
    /// injected path (tests) passes through the same installed-copy rules.
    public var installedBundleURL: URL? {
        let path = injectedBundlePath ?? Bundle.main.bundlePath
        guard path.hasSuffix(".app"),
              path.hasPrefix("/Applications/")
              || path.hasPrefix("/Users/") && path.contains("/Applications/") else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    public var canUpdate: Bool { installedBundleURL != nil }

    private var currentVersion: String {
        injectedCurrentVersion
            ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? "0"
    }

    // MARK: - Check

    /// Fetches the latest release manifest, verifies its Ed25519 signature
    /// and compares versions. Throws with a precise reason otherwise;
    /// presentation is the caller's job.
    public func check() async throws -> RivetUpdateCheckResult {
        guard installedBundleURL != nil else {
            throw RivetUpdateError.notInstalled
        }
        let manifest = try await fetchSignedManifest()
        if Self.isVersion(manifest.version, greaterThan: currentVersion) {
            return .available(manifest)
        }
        return .upToDate
    }

    private func fetchSignedManifest() async throws -> RivetUpdateManifest {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: configuration.feedURL)
        } catch {
            throw RivetUpdateError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RivetUpdateError.network(
                "HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        return try Self.verifyManifest(data,
                                       keyBase64: configuration.publicKeyBase64,
                                       keyID: configuration.keyID)
    }

    // MARK: - Pure steps (unit-tested)

    /// Verifies the signed wrapper (schema, key id, Ed25519 over the exact
    /// payload bytes) and decodes the inner manifest. The payload stays
    /// opaque until the signature check succeeds — unauthenticated input
    /// never reaches the JSON decoder.
    public static func verifyManifest(_ wrapperBytes: Data,
                                      keyBase64: String,
                                      keyID: String) throws -> RivetUpdateManifest {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let wrapper: SignedWrapper
        do {
            wrapper = try decoder.decode(SignedWrapper.self, from: wrapperBytes)
        } catch {
            throw RivetUpdateError.manifestMissing
        }
        guard wrapper.schema == 1 else { throw RivetUpdateError.manifestMissing }
        guard wrapper.signature.algorithm == "ed25519",
              wrapper.signature.keyId == keyID else {
            throw RivetUpdateError.signatureInvalid
        }
        guard let payload = Data(base64Encoded: wrapper.payload),
              let signature = Data(base64Encoded: wrapper.signature.value) else {
            throw RivetUpdateError.signatureInvalid
        }
        guard signature.count == 64 else { throw RivetUpdateError.signatureInvalid }
        guard let keyData = Data(base64Encoded: keyBase64),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            throw RivetUpdateError.badPublicKey
        }
        guard publicKey.isValidSignature(signature, for: payload) else {
            throw RivetUpdateError.signatureInvalid
        }
        do {
            return try decoder.decode(RivetUpdateManifest.self, from: payload)
        } catch {
            throw RivetUpdateError.network("manifest unparsable")
        }
    }

    /// The signed wrapper: the inner manifest travels base64-encoded so the
    /// Ed25519 signature covers the exact bytes every client verifies
    /// (rivet/distribution's signed-wrapper format).
    struct SignedWrapper: Decodable {
        struct SignatureBlock: Decodable {
            let algorithm: String
            let keyId: String
            let value: String
        }
        let schema: Int
        let payload: String
        let signature: SignatureBlock
    }

    // MARK: - Download + install

    /// Downloads, verifies (sha256 and unpacked bundle version), swaps the
    /// bundle in place and relaunches. Throws before touching the running
    /// install when anything is off; on success this method does not return
    /// (the application terminates as part of the swap). `onProgress`
    /// reports download percent (0…100) on a background thread; hosts hop
    /// to their UI actor themselves.
    public func downloadAndInstall(_ manifest: RivetUpdateManifest,
                                   onProgress: (@Sendable (Int) -> Void)? = nil) async throws {
        guard let bundleURL = installedBundleURL else {
            throw RivetUpdateError.notInstalled
        }
        guard let artifact = manifest.artifact(forPlatform: "macos") else {
            throw RivetUpdateError.manifestMissing
        }
        try await Self.downloadAndSwap(artifact: artifact,
                                       bundleURL: bundleURL,
                                       bundleName: configuration.bundleName,
                                       expectedVersion: manifest.version,
                                       requestTimeout: configuration.requestTimeout,
                                       resourceTimeout: configuration.resourceTimeout,
                                       onProgress: onProgress ?? { _ in })
    }

    /// The whole download → verify → swap sequence, deliberately off the
    /// main actor so the transfer never competes with UI work.
    private static func downloadAndSwap(
        artifact: RivetUpdateManifest.Artifact,
        bundleURL: URL,
        bundleName: String,
        expectedVersion: String,
        requestTimeout: TimeInterval,
        resourceTimeout: TimeInterval,
        onProgress: @escaping @Sendable (Int) -> Void
    ) async throws {
        // Download to a temp directory.
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rivet-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir,
                                                withIntermediateDirectories: true)
        let zipURL = workDir.appendingPathComponent("update.zip")
        var swapLaunched = false
        defer {
            // Once the swap script is spawned it owns the work dir (it
            // unpacks from there after we are gone); deleting it here would
            // race the script's grace sleep and destroy the payload.
            if !swapLaunched { try? FileManager.default.removeItem(at: workDir) }
        }

        let downloader = RivetArtifactDownloader(destination: zipURL,
                                                 expectedSize: artifact.size,
                                                 requestTimeout: requestTimeout,
                                                 resourceTimeout: resourceTimeout,
                                                 onProgress: onProgress)
        do {
            try await downloader.run(from: artifact.url)
        } catch let error as RivetUpdateError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw RivetUpdateError.network(error.localizedDescription)
        }

        // Size and sha256 against the signed manifest — from the file on
        // disk, so the artifact never sits whole in memory.
        let attributes = try FileManager.default.attributesOfItem(atPath: zipURL.path)
        guard let fileSize = attributes[.size] as? Int, fileSize == artifact.size else {
            let actual = (attributes[.size] as? Int) ?? -1
            throw RivetUpdateError.sizeMismatch(expected: artifact.size, actual: actual)
        }
        let digest = try Self.sha256Hex(ofFileAt: zipURL)
        guard digest == artifact.sha256.lowercased() else {
            throw RivetUpdateError.checksumMismatch
        }

        // Unzip and verify the payload really is the promised version.
        let unpacked = workDir.appendingPathComponent("unpacked")
        try FileManager.default.createDirectory(at: unpacked,
                                                withIntermediateDirectories: true)
        let dittoStatus = try await Self.runProcess(
            "/usr/bin/ditto", arguments: ["-x", "-k", zipURL.path, unpacked.path])
        guard dittoStatus == 0 else { throw RivetUpdateError.checksumMismatch }
        let newBundle = unpacked.appendingPathComponent(bundleName)
        guard let newVersion = Bundle(url: newBundle)?
            .infoDictionary?["CFBundleShortVersionString"] as? String else {
            throw RivetUpdateError.versionMismatch(expected: expectedVersion,
                                                   got: "missing")
        }
        guard newVersion == expectedVersion else {
            throw RivetUpdateError.versionMismatch(expected: expectedVersion,
                                                   got: newVersion)
        }

        // Swap: the shell script survives our exit; it also restores the
        // old bundle if the new one fails to move in.
        let script = Self.swapScript(bundlePath: bundleURL.path,
                                     newBundlePath: newBundle.path,
                                     oldPID: ProcessInfo.processInfo.processIdentifier)
        let swapPath = workDir.appendingPathComponent("swap.sh")
        try script.write(to: swapPath, atomically: true, encoding: .utf8)
        try await Self.runProcess("/bin/chmod", arguments: ["+x", swapPath.path])

        // Launch the swap, then leave through the normal exit path so
        // AppKit tears the app down cleanly; the script's grace sleep gives
        // us time to quit before it moves the bundle.
        let bash = Process()
        bash.executableURL = URL(fileURLWithPath: "/bin/bash")
        bash.arguments = [swapPath.path]
        do {
            try bash.run()
            swapLaunched = true
        } catch {
            throw error
        }
        #if canImport(AppKit)
        await MainActor.run {
            // A presented SwiftUI sheet vetoes NSApplication.terminate
            // silently; end every sheet first so the quit sequence runs.
            for window in NSApplication.shared.windows {
                for sheet in window.sheets {
                    window.endSheet(sheet)
                }
            }
            NSApplication.shared.terminate(nil)
        }
        // If terminate was still vetoed (or deferred), stop the run loop so
        // the app leaves inside the swap script's sleep window — otherwise
        // a surviving old process can hold a single-instance lease and
        // quietly kill the relaunched update.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await MainActor.run { NSApplication.shared.stop(nil) }
        // Stopping NSApplication's run loop is not itself a process-exit
        // guarantee when SwiftUI tasks retain the application. The detached
        // handoff must not race a live old PID while moving its bundle.
        exit(0)
        #else
        exit(0)
        #endif
    }

    /// The swap helper: wait for the old process to exit, activate the verified
    /// bundle, and keep the previous bundle until the replacement process has
    /// survived a short health window. If launch fails or the process exits
    /// during that window, restore and reopen the previous bundle.
    /// Static and pure so the exact script is unit-testable.
    static func swapScript(bundlePath: String,
                           newBundlePath: String,
                           oldPID: Int32 = 0,
                           healthTimeoutSeconds: Int = 15,
                           healthSettleSeconds: Int = 3,
                           openCommand: String = "/usr/bin/open") -> String {
        let old = bundlePath + ".old"
        return """
        #!/bin/bash
        set -u
        APP=\(shellQuoted(bundlePath))
        NEW=\(shellQuoted(newBundlePath))
        OLD=\(shellQuoted(old))
        OLD_PID=\(oldPID)
        OPEN_COMMAND=\(shellQuoted(openCommand))
        sleep 1

        # Never move a running app bundle. NSApplication gets the normal
        # terminate path first; this bounded wait covers deferred shutdown.
        if [ "$OLD_PID" -gt 1 ]; then
          waited=0
          while /bin/kill -0 "$OLD_PID" 2>/dev/null && [ "$waited" -lt 40 ]; do
            /bin/sleep 0.25
            waited=$((waited + 1))
          done
          if /bin/kill -0 "$OLD_PID" 2>/dev/null; then
            exit 1
          fi
        fi

        # A stale .old can only be discarded after the current app was alive
        # enough to request an update. Keep the current bundle as the rollback
        # copy for this transaction.
        /bin/rm -rf "$OLD"
        if ! /bin/mv "$APP" "$OLD"; then
          exit 1
        fi
        if ! /bin/mv "$NEW" "$APP"; then
          /bin/mv "$OLD" "$APP"
          exit 1
        fi

        APP_EXECUTABLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist") || APP_EXECUTABLE=""
        if [ -z "$APP_EXECUTABLE" ]; then
          /bin/rm -rf "$APP"
          /bin/mv "$OLD" "$APP"
          exit 1
        fi
        EXECUTABLE_PATH="$APP/Contents/MacOS/$APP_EXECUTABLE"

        # open only acknowledges LaunchServices; it does not prove the new
        # process survived. Find the executable under the new bundle and keep
        # the backup until that same process remains alive for the settle time.
        if "$OPEN_COMMAND" -n "$APP"; then
          waited=0
          while [ "$waited" -lt \(healthTimeoutSeconds * 2) ]; do
            new_pid=$(/bin/ps -ww -axo pid=,command= | /usr/bin/awk -v path="$EXECUTABLE_PATH" -v old_pid="$OLD_PID" '$1 != old_pid && index($0, path) > 0 { print $1; exit }')
            if [ -n "$new_pid" ] && /bin/kill -0 "$new_pid" 2>/dev/null; then
              /bin/sleep \(healthSettleSeconds)
              if /bin/kill -0 "$new_pid" 2>/dev/null &&
                 /bin/ps -ww -p "$new_pid" -o command= | /usr/bin/grep -Fq "$EXECUTABLE_PATH"; then
                /bin/rm -rf "$OLD"
                exit 0
              fi
              waited=$((waited + \(healthSettleSeconds * 2)))
            else
              /bin/sleep 0.5
              waited=$((waited + 1))
            fi
          done
        fi

        # Launch failed or crashed during the health window. Restore the
        # previous bundle before attempting to reopen it.
        if [ -d "$OLD" ]; then
          /bin/rm -rf "$APP"
          if /bin/mv "$OLD" "$APP"; then
            "$OPEN_COMMAND" -n "$APP" >/dev/null 2>&1 || true
          fi
        fi
        exit 1
        """
    }

    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @discardableResult
    private static func runProcess(_ path: String,
                                               arguments: [String]) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try process.run()
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { termination in
                continuation.resume(returning: termination.terminationStatus)
            }
        }
    }

    /// Chunked sha256 over a file on disk; hashing by 1 MiB chunks keeps
    /// peak memory flat regardless of artifact size.
    static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunkSize = 1 << 20
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Version compare (numeric per segment; 1.2 > 1.1.9)

    public static func isVersion(_ a: String, greaterThan b: String) -> Bool {
        let av = a.split(separator: ".").map { Int($0) ?? 0 }
        let bv = b.split(separator: ".").map { Int($0) ?? 0 }
        let length = max(av.count, bv.count)
        for i in 0..<length {
            let x = i < av.count ? av[i] : 0
            let y = i < bv.count ? bv[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Removes work directories left behind by update attempts that died
    /// before their swap script finished. Call once at application startup;
    /// fresh directories (an in-flight update from another process) are
    /// kept.
    public static func cleanupStaleWorkDirectories(olderThan interval: TimeInterval = 1800) {
        let temporary = FileManager.default.temporaryDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: temporary,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix("rivet-update-") {
            if let date = try? entry.resourceValues(
                    forKeys: [.contentModificationDateKey]).contentModificationDate,
               Date().timeIntervalSince(date) > interval {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }
}

/// One-artifact file download driven by URLSessionDownloadDelegate.
/// Delegate callbacks arrive on the session's serial delegate queue; the
/// checked continuation is taken exactly once under the lock.
/// `finishTasksAndInvalidate` on completion also breaks the delegate retain
/// cycle (the session retains its delegate).
final class RivetArtifactDownloader: NSObject,
        URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var lastPercent = -1
    private let destination: URL
    private let expectedSize: Int
    private let onProgress: @Sendable (Int) -> Void
    // Set once in init after super.init (the session needs self as its
    // delegate); never reassigned afterwards.
    private var session: URLSession!

    init(destination: URL,
         expectedSize: Int,
         requestTimeout: TimeInterval = 60,
         resourceTimeout: TimeInterval = 600,
         sessionConfiguration: URLSessionConfiguration? = nil,
         onProgress: @escaping @Sendable (Int) -> Void) {
        self.destination = destination
        self.expectedSize = expectedSize
        self.onProgress = onProgress
        super.init()
        let config = sessionConfiguration ?? URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        self.session = URLSession(configuration: config, delegate: self,
                                  delegateQueue: nil)
    }

    func run(from url: URL) async throws {
        let operation: @Sendable () async throws -> Void = { [self] in
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                begin(cont, url: url)
            }
        }
        let onCancel: @Sendable () -> Void = { [self] in
            session.invalidateAndCancel()
        }
        try await withTaskCancellationHandler(operation: operation,
                                              onCancel: onCancel)
    }

    private func begin(_ cont: CheckedContinuation<Void, Error>, url: URL) {
        lock.lock()
        if continuation != nil {
            lock.unlock()
            cont.resume(throwing: RivetUpdateError.network("download already running"))
            return
        }
        continuation = cont
        lock.unlock()
        session.downloadTask(with: url).resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        // Content-Length from the CDN; the signed manifest size is the
        // fallback when the response carries none. A definitive length that
        // disagrees with the signed size fails the transfer immediately —
        // downloading a wrong artifact to the end would only die later at
        // the sha256 check.
        if totalBytesExpectedToWrite > 0,
           Int(totalBytesExpectedToWrite) != expectedSize {
            downloadTask.cancel()
            resume(with: .failure(RivetUpdateError.sizeMismatch(
                expected: expectedSize,
                actual: Int(totalBytesExpectedToWrite))))
            return
        }
        let total = totalBytesExpectedToWrite > 0
            ? Int(totalBytesExpectedToWrite) : max(expectedSize, 1)
        let percent = min(100, Int(totalBytesWritten) * 100 / total)
        if percent != lastPercent {
            lastPercent = percent
            onProgress(percent)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // `location` is valid only inside this callback — move now.
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            // The deterministic size gate: whatever the transfer reported,
            // the file on disk must match the signed size or the transfer
            // fails right here (a 404 body would otherwise "succeed").
            let attributes = try FileManager.default.attributesOfItem(
                atPath: destination.path)
            guard let size = attributes[.size] as? Int, size == expectedSize else {
                let actual = (attributes[.size] as? Int) ?? -1
                resume(with: .failure(RivetUpdateError.sizeMismatch(
                    expected: expectedSize, actual: actual)))
                return
            }
            resume(with: .success(()))
        } catch {
            resume(with: .failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        // Success is reported by didFinishDownloadingTo; this callback
        // carries the failure half (including cancellation and the
        // request/resource timeouts that bound a silent stall).
        guard let error else { return }
        resume(with: .failure(error))
    }

    private func resume(with result: Result<Void, Error>) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        session.finishTasksAndInvalidate()
        cont?.resume(with: result)
    }
}
