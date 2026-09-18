import Darwin
import Foundation
import CRivetRacket
import RivetRuntime

public struct RacketRuntimeConfiguration: Sendable {
    public var executablePath: String
    public var petiteBoot: String
    public var schemeBoot: String
    public var racketBoot: String
    public var backendBundle: String
    public var moduleName: String
    public var entryName: String

    public init(
        executablePath: String,
        petiteBoot: String,
        schemeBoot: String,
        racketBoot: String,
        backendBundle: String,
        moduleName: String = "backend",
        entryName: String = "start"
    ) {
        self.executablePath = executablePath
        self.petiteBoot = petiteBoot
        self.schemeBoot = schemeBoot
        self.racketBoot = racketBoot
        self.backendBundle = backendBundle
        self.moduleName = moduleName
        self.entryName = entryName
    }
}

public final class EmbeddedBackend: @unchecked Sendable {
    public typealias EventHandler = RivetClient.EventHandler

    private let configuration: RacketRuntimeConfiguration
    private let requestPipe = Pipe()
    private let responsePipe = Pipe()
    private let stateLock = NSLock()

    private var client: RivetClient?
    private var runtimeThread: Thread?
    private var started = false

    public init(configuration: RacketRuntimeConfiguration) {
        self.configuration = configuration
    }

    deinit {
        stop()
    }

    public func start(onEvent: EventHandler? = nil) throws {
        stateLock.lock()
        guard !started else {
            stateLock.unlock()
            throw EmbeddedBackendError.alreadyStarted
        }
        started = true
        stateLock.unlock()

        let serverIn = Darwin.dup(requestPipe.fileHandleForReading.fileDescriptor)
        guard serverIn >= 0 else {
            resetStarted()
            throw EmbeddedBackendError.posix("dup(request read)", errno)
        }

        let serverOut = Darwin.dup(responsePipe.fileHandleForWriting.fileDescriptor)
        guard serverOut >= 0 else {
            Darwin.close(serverIn)
            resetStarted()
            throw EmbeddedBackendError.posix("dup(response write)", errno)
        }

        // Keep only the native endpoints in Swift. This is important for EOF:
        // once the Racket-owned duplicate closes, the client reader must wake.
        try requestPipe.fileHandleForReading.close()
        try responsePipe.fileHandleForWriting.close()

        let configuration = self.configuration
        let thread = Thread {
            Self.runRacket(configuration: configuration, inFD: serverIn, outFD: serverOut)
        }
        thread.name = "Rivet Racket Runtime"
        thread.qualityOfService = .userInitiated
        runtimeThread = thread
        thread.start()

        let client = RivetClient(
            input: responsePipe.fileHandleForReading,
            output: requestPipe.fileHandleForWriting
        )
        do {
            try client.start(onEvent: onEvent)
            stateLock.lock()
            self.client = client
            stateLock.unlock()
        } catch {
            client.stop()
            resetStarted()
            throw error
        }
    }

    public func call(
        _ name: String,
        arguments: [RivetValue] = []
    ) async throws -> RivetValue {
        let client = try activeClient()
        return try await client.call(name, arguments: arguments)
    }

    public func stop() {
        stateLock.lock()
        let client = self.client
        self.client = nil
        let thread = runtimeThread
        runtimeThread = nil
        let wasStarted = started
        started = false
        stateLock.unlock()

        guard wasStarted else { return }
        client?.stop()

        if let thread, !thread.isFinished, thread != Thread.current {
            // Thread has no join primitive. RVT1 Shutdown causes the Racket
            // server to return and the thread to finish naturally.
        }
    }

    private func activeClient() throws -> RivetClient {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let client else { throw EmbeddedBackendError.notStarted }
        return client
    }

    private func resetStarted() {
        stateLock.lock()
        started = false
        stateLock.unlock()
    }

    private static func runRacket(
        configuration: RacketRuntimeConfiguration,
        inFD: Int32,
        outFD: Int32
    ) {
        configuration.executablePath.withCString { executable in
            configuration.petiteBoot.withCString { petite in
                configuration.schemeBoot.withCString { scheme in
                    configuration.racketBoot.withCString { racket in
                        configuration.backendBundle.withCString { bundle in
                            configuration.moduleName.withCString { module in
                                configuration.entryName.withCString { entry in
                                    var config = rivet_racket_config()
                                    config.exec_file = executable
                                    config.petite_boot = petite
                                    config.scheme_boot = scheme
                                    config.racket_boot = racket
                                    config.core_zo = bundle
                                    config.module_name = module
                                    config.entry_name = entry
                                    config.collects_dir = nil
                                    config.config_dir = nil
                                    _ = rivet_racket_run(&config, inFD, outFD)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

public enum EmbeddedBackendError: Error, CustomStringConvertible {
    case alreadyStarted
    case notStarted
    case posix(String, Int32)

    public var description: String {
        switch self {
        case .alreadyStarted:
            return "Rivet embedded backend has already been started"
        case .notStarted:
            return "Rivet embedded backend is not started"
        case .posix(let operation, let code):
            return "\(operation) failed with errno \(code)"
        }
    }
}
