import Foundation
import RivetEmbedding
import RivetRuntime

@main
struct RivetIntegration {
    static func main() async throws {
        let environment = ProcessInfo.processInfo.environment
        func required(_ key: String) throws -> URL {
            guard let value = environment[key], !value.isEmpty else {
                throw IntegrationError.missingEnvironment(key)
            }
            return URL(fileURLWithPath: value)
        }

        let backend = EmbeddedRacketBackend(
            configuration: EmbeddedRacketConfiguration(
                executable: try required("RIVET_TEST_EXECUTABLE"),
                petiteBoot: try required("RIVET_TEST_PETITE_BOOT"),
                schemeBoot: try required("RIVET_TEST_SCHEME_BOOT"),
                racketBoot: try required("RIVET_TEST_RACKET_BOOT"),
                core: try required("RIVET_TEST_CORE"),
                moduleName: "backend",
                entryName: "start"
            )
        )

        try backend.start()

        let incremented = try await backend.client.call(
            "increment",
            arguments: [.int64(41)]
        )
        guard incremented == .int64(42) else {
            throw IntegrationError.unexpected("increment", incremented)
        }

        let initialState = try await backend.client.getState("counter")
        guard initialState == .int64(10) else {
            throw IntegrationError.unexpected("initial state", initialState)
        }

        let updatedState = try await backend.client.setState(
            "counter",
            value: .int64(11)
        )
        guard updatedState == .int64(11) else {
            throw IntegrationError.unexpected("updated state", updatedState)
        }

        let confirmedState = try await backend.client.getState("counter")
        guard confirmedState == .int64(11) else {
            throw IntegrationError.unexpected("confirmed state", confirmedState)
        }

        backend.stop()
        backend.stop() // stop is intentionally idempotent.

        do {
            try backend.start()
            throw IntegrationError.restartWasAllowed
        } catch EmbeddedBackendError.alreadyStarted {
            // Expected: an embedded Racket runtime is process-scoped and cannot restart.
        }

        print("Rivet embedded macOS round-trip passed")
    }
}

enum IntegrationError: Error, CustomStringConvertible {
    case missingEnvironment(String)
    case unexpected(String, RivetValue)
    case restartWasAllowed

    var description: String {
        switch self {
        case .missingEnvironment(let key):
            return "missing integration environment variable: \(key)"
        case .unexpected(let operation, let value):
            return "unexpected \(operation) result: \(value)"
        case .restartWasAllowed:
            return "embedded Racket backend unexpectedly allowed restart after stop"
        }
    }
}
