import Darwin
import Foundation
import CRivetRacket
import RivetRuntime

public struct EmbeddedRacketConfiguration: Sendable {
    public var executable: URL
    public var petiteBoot: URL
    public var schemeBoot: URL
    public var racketBoot: URL
    public var core: URL
    public var moduleName: String
    public var entryName: String

    public init(
        executable: URL,
        petiteBoot: URL,
        schemeBoot: URL,
        racketBoot: URL,
        core: URL,
        moduleName: String = "backend",
        entryName: String = "start"
    ) {
        self.executable = executable
        self.petiteBoot = petiteBoot
        self.schemeBoot = schemeBoot
        self.racketBoot = racketBoot
        self.core = core
        self.moduleName = moduleName
        self.entryName = entryName
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

    private var state: Lifecycle = .created
    private var serverThread: Thread?

    public private(set) lazy var client = RivetClient(
        input: responsePipe.fileHandleForReading,
        output: requestPipe.fileHandleForWriting
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

        do {
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
            let server = Thread {
                defer { completion.signal() }
                runEmbeddedRacket(config, inputFD: racketInput, outputFD: racketOutput)
            }
            server.name = "Rivet Racket CS"
            server.qualityOfService = .userInitiated

            lifecycle.lock()
            serverThread = server
            lifecycle.unlock()
            server.start()

            // Hello is emitted only after the Racket module and server have loaded.
            try client.start(onEvent: onEvent)

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
}

private func runEmbeddedRacket(
    _ config: EmbeddedRacketConfiguration,
    inputFD: Int32,
    outputFD: Int32
) {
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
}

public enum EmbeddedBackendError: Error, CustomStringConvertible {
    case alreadyStarted
    case dupFailed(Int32)

    public var description: String {
        switch self {
        case .alreadyStarted:
            return "embedded Racket backend instances cannot be restarted"
        case .dupFailed(let code):
            return "dup() failed while creating Racket pipe descriptors (errno \(code))"
        }
    }
}
