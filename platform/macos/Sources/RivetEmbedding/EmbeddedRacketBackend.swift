import Darwin
import Foundation
import CRivetRacket
import RivetRuntime

private final class EmbeddedDiagnosticContext: @unchecked Sendable {
    private let lock = NSLock()
    private var lastProtocolEvent = "none"

    func forward(_ record: RivetDiagnosticRecord, to sink: RivetDiagnosticSink) {
        if record.lastProtocolEvent != "none" {
            lock.lock()
            lastProtocolEvent = record.lastProtocolEvent
            lock.unlock()
        }
        sink(record)
    }

    func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return lastProtocolEvent
    }
}

public struct EmbeddedRacketConfiguration: Sendable {
    public var executable: URL
    public var petiteBoot: URL
    public var schemeBoot: URL
    public var racketBoot: URL
    public var core: URL
    /// Resource root used to resolve relative foreign-library paths staged by
    /// `raco ctool`. `nil` preserves the caller's process working directory.
    public var workingDirectory: URL?
    public var moduleName: String
    public var entryName: String
    public var maxPendingRequests: Int
    public var diagnosticSink: RivetDiagnosticSink

    public init(
        executable: URL,
        petiteBoot: URL,
        schemeBoot: URL,
        racketBoot: URL,
        core: URL,
        workingDirectory: URL? = nil,
        moduleName: String = "backend",
        entryName: String = "start",
        maxPendingRequests: Int = 1024,
        diagnosticSink: @escaping RivetDiagnosticSink = RivetDiagnostics.standardError
    ) {
        precondition(maxPendingRequests > 0, "Rivet native pending request limit must be positive")
        self.executable = executable
        self.petiteBoot = petiteBoot
        self.schemeBoot = schemeBoot
        self.racketBoot = racketBoot
        self.core = core
        self.workingDirectory = workingDirectory
        self.moduleName = moduleName
        self.entryName = entryName
        self.maxPendingRequests = maxPendingRequests
        self.diagnosticSink = diagnosticSink
    }

    /// Resolves the canonical Rivet runtime layout used by both packaged apps
    /// and `raco rivet dev`.
    ///
    /// Packaged applications keep `runtime/*.boot` and `res/core.zo` under
    /// `Bundle.main.resourceURL`. Development builds stage those directories
    /// beside the host executable. The packaged layout is preferred when both
    /// are present.
    public static func resolvedDefault(
        moduleName: String = "backend",
        entryName: String = "start",
        maxPendingRequests: Int = 1024,
        diagnosticSink: @escaping RivetDiagnosticSink = RivetDiagnostics.standardError
    ) throws -> EmbeddedRacketConfiguration {
        let executable = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let roots = [
            Bundle.main.resourceURL,
            executable.deletingLastPathComponent()
        ].compactMap { $0 }

        return try resolve(
            executable: executable,
            candidateRoots: roots,
            moduleName: moduleName,
            entryName: entryName,
            maxPendingRequests: maxPendingRequests,
            diagnosticSink: diagnosticSink
        )
    }

    static func resolve(
        executable: URL,
        candidateRoots: [URL],
        moduleName: String,
        entryName: String,
        maxPendingRequests: Int,
        diagnosticSink: @escaping RivetDiagnosticSink,
        fileManager: FileManager = .default
    ) throws -> EmbeddedRacketConfiguration {
        var searchedRoots: [URL] = []
        var seen = Set<String>()

        for candidate in candidateRoots {
            let root = candidate.standardizedFileURL
            guard seen.insert(root.path).inserted else { continue }
            searchedRoots.append(root)

            let runtime = root.appendingPathComponent("runtime", isDirectory: true)
            let petiteBoot = runtime.appendingPathComponent("petite.boot")
            let schemeBoot = runtime.appendingPathComponent("scheme.boot")
            let racketBoot = runtime.appendingPathComponent("racket.boot")
            let core = root.appendingPathComponent("res/core.zo")
            let required = [petiteBoot, schemeBoot, racketBoot, core]

            guard required.allSatisfy({ url in
                var isDirectory: ObjCBool = false
                return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
                    && !isDirectory.boolValue
            }) else { continue }

            return EmbeddedRacketConfiguration(
                executable: executable,
                petiteBoot: petiteBoot,
                schemeBoot: schemeBoot,
                racketBoot: racketBoot,
                core: core,
                workingDirectory: root,
                moduleName: moduleName,
                entryName: entryName,
                maxPendingRequests: maxPendingRequests,
                diagnosticSink: diagnosticSink
            )
        }

        throw EmbeddedRacketConfigurationError.missingRuntimeLayout(
            searchedRoots: searchedRoots
        )
    }
}

public enum EmbeddedRacketConfigurationError: Error, Sendable, CustomStringConvertible {
    case missingRuntimeLayout(searchedRoots: [URL])

    public var description: String {
        switch self {
        case .missingRuntimeLayout(let searchedRoots):
            let roots = searchedRoots.map(\.path).joined(separator: ", ")
            return "missing Rivet runtime/petite.boot, runtime/scheme.boot, "
                + "runtime/racket.boot, or res/core.zo under: \(roots)"
        }
    }
}

public final class EmbeddedRacketBackend: @unchecked Sendable {
    private enum Lifecycle {
        case created
        case starting
        case running
        case stopping
        case stopped
        case failed
    }

    private let configuration: EmbeddedRacketConfiguration
    private let requestPipe = Pipe()
    private let responsePipe = Pipe()
    private let lifecycle = NSCondition()
    private let serverExited = DispatchSemaphore(value: 0)
    private let diagnosticContext = EmbeddedDiagnosticContext()

    private var state: Lifecycle = .created
    private var serverThread: Thread?

    public private(set) lazy var client = RivetClient(
        input: responsePipe.fileHandleForReading,
        output: requestPipe.fileHandleForWriting,
        maxPendingRequests: configuration.maxPendingRequests,
        diagnosticSink: { [diagnosticContext, sink = configuration.diagnosticSink] record in
            diagnosticContext.forward(record, to: sink)
        }
    )

    public init(configuration: EmbeddedRacketConfiguration) {
        self.configuration = configuration
    }

    public func start(onEvent: RivetClient.EventHandler? = nil) throws {
        lifecycle.lock()
        guard state == .created else {
            lifecycle.unlock()
            throw EmbeddedBackendError.alreadyStarted
        }
        state = .starting
        lifecycle.unlock()
        diagnose(layer: "abi-bridge", event: "backend-init", status: "begin")

        do {
            if let workingDirectory = configuration.workingDirectory,
               !FileManager.default.changeCurrentDirectoryPath(workingDirectory.path) {
                throw EmbeddedBackendError.workingDirectoryFailed(workingDirectory.path)
            }

            let racketInput = Darwin.dup(requestPipe.fileHandleForReading.fileDescriptor)
            guard racketInput >= 0 else {
                throw EmbeddedBackendError.dupFailed(errno)
            }

            let racketOutput = Darwin.dup(responsePipe.fileHandleForWriting.fileDescriptor)
            guard racketOutput >= 0 else {
                Darwin.close(racketInput)
                throw EmbeddedBackendError.dupFailed(errno)
            }

            // Only the duplicated descriptors belong to Racket. Closing these
            // Foundation endpoints prevents an extra writer/read handle from
            // keeping the pipe artificially alive after the server exits.
            try? requestPipe.fileHandleForReading.close()
            try? responsePipe.fileHandleForWriting.close()

            let config = configuration
            let completion = serverExited
            let diagnostics = diagnosticContext
            let server = Thread {
                defer { completion.signal() }
                let result = runEmbeddedRacket(
                    config,
                    inputFD: racketInput,
                    outputFD: racketOutput
                )
                if result != 0 {
                    config.diagnosticSink(
                        RivetDiagnosticRecord(
                            layer: "abi-bridge",
                            event: "backend-exit",
                            status: "failure",
                            lastProtocolEvent: diagnostics.snapshot(),
                            message: "rivet_racket_run returned status \(result)"
                        )
                    )
                }
            }
            server.name = "Rivet Racket CS"
            server.qualityOfService = .userInitiated

            lifecycle.lock()
            serverThread = server
            lifecycle.unlock()
            server.start()

            // Hello is emitted only after the Racket module and server have loaded.
            try client.start(onEvent: onEvent)
            diagnose(
                layer: "abi-bridge",
                event: "backend-init",
                status: "success",
                lastProtocolEvent: "hello"
            )

            lifecycle.lock()
            if state == .starting {
                state = .running
            }
            lifecycle.broadcast()
            lifecycle.unlock()
        } catch {
            lifecycle.lock()
            let stopping = state == .stopping
            if !stopping {
                state = .failed
            }
            lifecycle.broadcast()
            lifecycle.unlock()

            // A concurrent stop owns teardown. Otherwise make startup failure
            // deterministic and leave the process-scoped runtime non-restartable.
            if !stopping {
                client.stop()
                closeNativePipeEndpoints()
                waitForServerExit()
            }
            diagnose(
                layer: "abi-bridge",
                event: "backend-init",
                status: "failure",
                message: String(describing: error)
            )
            throw error
        }
    }

    public func stop() {
        lifecycle.lock()
        while state == .stopping {
            lifecycle.wait()
        }

        switch state {
        case .stopped, .failed:
            lifecycle.unlock()
            return
        case .created:
            state = .stopped
            lifecycle.broadcast()
            lifecycle.unlock()
            closeNativePipeEndpoints()
            return
        case .starting, .running:
            state = .stopping
            lifecycle.unlock()
            diagnose(
                layer: "native-runtime",
                event: "backend-stop",
                status: "begin"
            )
        case .stopping:
            // The loop above consumes this state.
            lifecycle.unlock()
            return
        }

        client.stop()
        closeNativePipeEndpoints()
        waitForServerExit()

        lifecycle.lock()
        state = .stopped
        lifecycle.broadcast()
        lifecycle.unlock()
        diagnose(layer: "native-runtime", event: "backend-stop", status: "success")
    }

    deinit {
        stop()
    }

    private func closeNativePipeEndpoints() {
        try? requestPipe.fileHandleForWriting.close()
        try? responsePipe.fileHandleForReading.close()
    }

    private func waitForServerExit() {
        lifecycle.lock()
        let thread = serverThread
        lifecycle.unlock()
        guard thread != nil else { return }

        serverExited.wait()

        lifecycle.lock()
        serverThread = nil
        lifecycle.unlock()
    }

    private func diagnose(
        layer: String,
        event: String,
        status: String,
        lastProtocolEvent: String? = nil,
        message: String? = nil
    ) {
        configuration.diagnosticSink(
            RivetDiagnosticRecord(
                layer: layer,
                event: event,
                status: status,
                lastProtocolEvent: lastProtocolEvent ?? diagnosticContext.snapshot(),
                message: message
            )
        )
    }
}

@discardableResult
private func runEmbeddedRacket(
    _ config: EmbeddedRacketConfiguration,
    inputFD: Int32,
    outputFD: Int32
) -> Int32 {
    let result: Int32 = config.executable.path.withCString { executable in
        config.petiteBoot.path.withCString { petite in
            config.schemeBoot.path.withCString { scheme in
                config.racketBoot.path.withCString { racket in
                    config.core.path.withCString { core in
                        config.moduleName.withCString { module in
                            config.entryName.withCString { entry in
                                var cconfig = rivet_racket_config(
                                    exec_file: executable,
                                    petite_boot: petite,
                                    scheme_boot: scheme,
                                    racket_boot: racket,
                                    core_zo: core,
                                    module_name: module,
                                    entry_name: entry,
                                    collects_dir: nil,
                                    config_dir: nil
                                )
                                return rivet_racket_run(&cconfig, inputFD, outputFD)
                            }
                        }
                    }
                }
            }
        }
    }

    if result != 0 {
        Darwin.close(inputFD)
        Darwin.close(outputFD)
    }
    return result
}

public enum EmbeddedBackendError: Error, CustomStringConvertible {
    case alreadyStarted
    case dupFailed(Int32)
    case workingDirectoryFailed(String)

    public var description: String {
        switch self {
        case .alreadyStarted:
            return "embedded Racket backend instances cannot be restarted"
        case .dupFailed(let code):
            return "dup() failed while creating Racket pipe descriptors (errno \(code))"
        case .workingDirectoryFailed(let path):
            return "could not select the Rivet runtime working directory: \(path)"
        }
    }
}
