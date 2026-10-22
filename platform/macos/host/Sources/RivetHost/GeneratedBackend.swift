// Generated from the default Rivet scaffold backend.
// raco rivet build replaces this file from the application's actual schema.
import Foundation
import RivetRuntime

public enum RivetGeneratedError: Error {
    case typeMismatch(String)
}

public enum RivetGeneratedConfig {
    public static let moduleName = "backend"
    public static let entryName = "start"
    public static let displayName = "Rivet"
    public static let version = "0.1.0"
    public static let build: Int64 = 1
    public static let identifier = "dev.rivet.app"
    public static let releaseChannel = "stable"
}

public protocol RivetGeneratedRPCClient: Sendable {
    func call(_ name: String, arguments: [RivetValue]) async throws -> RivetValue
}

// Keep generated clients compatible with the last released SwiftPM runtime.
// Authenticated network clients can use RivetAPI(call: deviceClient.call).
public extension RivetGeneratedRPCClient {
    func getState(_ name: String) async throws -> RivetValue {
        try await call("$state/get", arguments: [.string(name)])
    }

    @discardableResult
    func setState(_ name: String, value: RivetValue) async throws -> RivetValue {
        try await call("$state/set", arguments: [.string(name), value])
    }
}

extension RivetClient: RivetGeneratedRPCClient {}

private struct RivetGeneratedClosureClient: RivetGeneratedRPCClient {
    let invoke: @Sendable (String, [RivetValue]) async throws -> RivetValue

    func call(_ name: String, arguments: [RivetValue]) async throws -> RivetValue {
        try await invoke(name, arguments)
    }
}

public struct RivetAPI: Sendable {
    public let client: any RivetGeneratedRPCClient
    public init(client: any RivetGeneratedRPCClient) { self.client = client }
    public init(call: @escaping @Sendable (String, [RivetValue]) async throws -> RivetValue) {
        self.client = RivetGeneratedClosureClient(invoke: call)
    }

    public func greet(name: String) async throws -> String {
        let value = try await client.call("greet", arguments: [.string(name)])
        guard case .string(let result) = value else {
            throw RivetGeneratedError.typeMismatch("String")
        }
        return result
    }

    public func increment(value: Int64) async throws -> Int64 {
        let result = try await client.call("increment", arguments: [.int64(value)])
        guard case .int64(let next) = result else {
            throw RivetGeneratedError.typeMismatch("Int64")
        }
        return next
    }
}
