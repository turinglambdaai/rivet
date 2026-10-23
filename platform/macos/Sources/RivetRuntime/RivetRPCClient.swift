import Foundation

/// The minimal typed RPC surface consumed by generated \`RivetAPI\` code.
/// In-process clients and authenticated network clients can share the same
/// generated API without pretending to have the same lifecycle or transport.
public protocol RivetRPCClient: Sendable {
    func call(_ name: String, arguments: [RivetValue]) async throws -> RivetValue
}

public extension RivetRPCClient {
    func getState(_ name: String) async throws -> RivetValue {
        try await call("$state/get", arguments: [.string(name)])
    }

    @discardableResult
    func setState(_ name: String, value: RivetValue) async throws -> RivetValue {
        try await call("$state/set", arguments: [.string(name), value])
    }
}

extension RivetClient: RivetRPCClient {}
