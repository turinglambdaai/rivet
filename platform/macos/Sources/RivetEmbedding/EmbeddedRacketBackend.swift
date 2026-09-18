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
    private let configuration: EmbeddedRacketConfiguration
    private let requestPipe = Pipe()
    private let responsePipe = Pipe()
    private let lifecycleLock = NSLock()
    private var started = false

    public private(set) lazy var client = RivetClient(
        input: responsePipe.fileHandleForReading,
        output: requestPipe.fileHandleForWriting
    )

    public init(configuration: EmbeddedRacketConfiguration) {
        self.configuration = configuration
    }

    public func start(onEvent: RivetClient.EventHandler? = nil) throws {
        lifecycleLock.lock()
        guard !started else {
            lifecycleLock.unlock()
            throw EmbeddedBackendError.alreadyStarted
        }
        started = true
        lifecycleLock.unlock()

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
        let server = Thread {
            runEmbeddedRacket(config, inputFD: racketInput, outputFD: racketOutput)
        }
        server.name = "Rivet Racket CS"
        server.qualityOfService = .userInitiated
        server.start()

        // Hello is emitted only after the Racket module and server have loaded.
        try client.start(onEvent: onEvent)
    }

    public func stop() {
        lifecycleLock.lock()
        let wasStarted = started
        started = false
        lifecycleLock.unlock()
        if wasStarted {
            client.stop()
        }
    }

    deinit {
        stop()
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
            return "embedded Racket backend has already been started"
        case .dupFailed(let code):
            return "dup() failed while creating Racket pipe descriptors (errno \(code))"
        }
    }
}
