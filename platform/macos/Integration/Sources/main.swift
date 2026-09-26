import Dispatch
import Foundation
import RivetEmbedding
import RivetRuntime

#if arch(arm64)
private let benchmarkArchitecture = "arm64"
#elseif arch(x86_64)
private let benchmarkArchitecture = "x64"
#else
private let benchmarkArchitecture = "unknown"
#endif

private struct BenchmarkMetric {
    let iterations: Int
    let totalMilliseconds: Double

    var microsecondsPerOperation: Double {
        totalMilliseconds * 1000.0 / Double(iterations)
    }

    var json: [String: Any] {
        [
            "iterations": iterations,
            "total_ms": totalMilliseconds,
            "us_per_operation": microsecondsPerOperation
        ]
    }
}

private func elapsedMilliseconds(from start: UInt64, to end: UInt64) -> Double {
    Double(end - start) / 1_000_000.0
}

private func benchmarkOperations(
    iterations: Int,
    operation: (Int) async throws -> Void
) async rethrows -> BenchmarkMetric {
    let start = DispatchTime.now().uptimeNanoseconds
    for index in 0..<iterations {
        try await operation(index)
    }
    let end = DispatchTime.now().uptimeNanoseconds
    return BenchmarkMetric(
        iterations: iterations,
        totalMilliseconds: elapsedMilliseconds(from: start, to: end)
    )
}

private func benchmarkMode() throws -> Bool {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.isEmpty { return false }
    if arguments == ["--benchmark"] { return true }
    throw IntegrationError.invalidArguments(arguments)
}

private func runBenchmark(
    backend: EmbeddedRacketBackend,
    startupMilliseconds: Double
) async throws {
    let warmupIterations = 50
    let rpcIterations = 1000
    let stateGetIterations = 1000
    let stateSetIterations = 500

    for _ in 0..<warmupIterations {
        let result = try await backend.client.call(
            "increment",
            arguments: [.int64(41)]
        )
        guard result == .int64(42) else {
            throw IntegrationError.unexpected("benchmark warmup", result)
        }
    }

    let rpc = try await benchmarkOperations(iterations: rpcIterations) { _ in
        let result = try await backend.client.call(
            "increment",
            arguments: [.int64(41)]
        )
        guard result == .int64(42) else {
            throw IntegrationError.unexpected("benchmark RPC", result)
        }
    }

    let stateGet = try await benchmarkOperations(iterations: stateGetIterations) { _ in
        let result = try await backend.client.getState("counter")
        guard result == .int64(10) else {
            throw IntegrationError.unexpected("benchmark state get", result)
        }
    }

    let stateSet = try await benchmarkOperations(iterations: stateSetIterations) { index in
        let expected: RivetValue = .int64(Int64(10 + (index & 1)))
        let result = try await backend.client.setState("counter", value: expected)
        guard result == expected else {
            throw IntegrationError.unexpected("benchmark state set", result)
        }
    }

    let report: [String: Any] = [
        "schema_version": 1,
        "platform": "macos",
        "architecture": benchmarkArchitecture,
        "configuration": "release",
        "startup_ms": startupMilliseconds,
        "warmup_iterations": warmupIterations,
        "rpc": rpc.json,
        "state_get": stateGet.json,
        "state_set": stateSet.json
    ]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    guard let json = String(data: data, encoding: .utf8) else {
        throw IntegrationError.benchmarkEncoding
    }
    print(json)
}

@main
struct RivetIntegration {
    static func main() async throws {
        let benchmark = try benchmarkMode()
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

        let startupStart = DispatchTime.now().uptimeNanoseconds
        try backend.start()
        let startupEnd = DispatchTime.now().uptimeNanoseconds
        let startupMilliseconds = elapsedMilliseconds(from: startupStart, to: startupEnd)

        if benchmark {
            try await runBenchmark(
                backend: backend,
                startupMilliseconds: startupMilliseconds
            )
            backend.stop()
            return
        }

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
    case invalidArguments([String])
    case benchmarkEncoding

    var description: String {
        switch self {
        case .missingEnvironment(let key):
            return "missing integration environment variable: \(key)"
        case .unexpected(let operation, let value):
            return "unexpected \(operation) result: \(value)"
        case .restartWasAllowed:
            return "embedded Racket backend unexpectedly allowed restart after stop"
        case .invalidArguments(let arguments):
            return "usage: RivetIntegration [--benchmark]; received: \(arguments)"
        case .benchmarkEncoding:
            return "failed to encode benchmark report as UTF-8 JSON"
        }
    }
}
