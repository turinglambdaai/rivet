import Foundation

public let rivetDeviceProtocolVersion: UInt8 = 1
public let rivetDeviceDefaultMaximumMessageSize = 512 * 1024

public protocol RivetDeviceRequest: Codable, Sendable {
    associatedtype Response: Codable & Sendable
    static var route: String { get }
}

public protocol RivetDeviceTransport: Sendable {
    func send(_ request: Data) async throws -> Data
}

public protocol RivetDeviceRemoteError: Error, Sendable {
    var rivetDeviceErrorCode: String { get }
    var rivetDeviceErrorMessage: String { get }
}

public enum RivetDeviceError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidRoute(String)
    case duplicateRoute(String)
    case messageTooLarge(actual: Int, maximum: Int)
    case malformedEnvelope
    case unsupportedVersion(UInt8)
    case responseIDMismatch
    case missingResponsePayload
    case remote(code: String, message: String)

    public var description: String {
        switch self {
        case .invalidRoute(let route):
            return "invalid Rivet device route: \(route)"
        case .duplicateRoute(let route):
            return "duplicate Rivet device route: \(route)"
        case .messageTooLarge(let actual, let maximum):
            return "Rivet device message is \(actual) bytes; maximum is \(maximum)"
        case .malformedEnvelope:
            return "malformed Rivet device envelope"
        case .unsupportedVersion(let version):
            return "unsupported Rivet device protocol version \(version)"
        case .responseIDMismatch:
            return "Rivet device response id does not match its request"
        case .missingResponsePayload:
            return "Rivet device response contains neither a payload nor an error"
        case .remote(let code, let message):
            return "Rivet device remote error [\(code)]: \(message)"
        }
    }
}

private struct RequestEnvelope: Codable, Sendable {
    let version: UInt8
    let id: UUID
    let route: String
    let payload: Data
}

private struct ResponseEnvelope: Codable, Sendable {
    let version: UInt8
    let id: UUID
    let payload: Data?
    let error: ErrorEnvelope?
}

private struct ErrorEnvelope: Codable, Sendable {
    let code: String
    let message: String
}

private func validateRoute(_ route: String) throws {
    guard !route.isEmpty,
          route.utf8.count <= 128,
          route.unicodeScalars.allSatisfy({
              CharacterSet.alphanumerics.contains($0) || ".-_".unicodeScalars.contains($0)
          }) else {
        throw RivetDeviceError.invalidRoute(route)
    }
}

private func checkedSize(_ data: Data, maximum: Int) throws {
    guard data.count <= maximum else {
        throw RivetDeviceError.messageTooLarge(actual: data.count, maximum: maximum)
    }
}

private func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}

public struct RivetDeviceClient: Sendable {
    private let transport: any RivetDeviceTransport
    private let maximumMessageSize: Int

    public init(
        transport: any RivetDeviceTransport,
        maximumMessageSize: Int = rivetDeviceDefaultMaximumMessageSize
    ) {
        precondition(maximumMessageSize > 0, "Rivet device message limit must be positive")
        self.transport = transport
        self.maximumMessageSize = maximumMessageSize
    }

    public func send<Request: RivetDeviceRequest>(
        _ request: Request
    ) async throws -> Request.Response {
        try validateRoute(Request.route)
        let id = UUID()
        let payload = try encoder().encode(request)
        let wireRequest = try encoder().encode(RequestEnvelope(
            version: rivetDeviceProtocolVersion,
            id: id,
            route: Request.route,
            payload: payload
        ))
        try checkedSize(wireRequest, maximum: maximumMessageSize)

        let wireResponse = try await transport.send(wireRequest)
        try checkedSize(wireResponse, maximum: maximumMessageSize)
        guard let response = try? JSONDecoder().decode(ResponseEnvelope.self, from: wireResponse) else {
            throw RivetDeviceError.malformedEnvelope
        }
        guard response.version == rivetDeviceProtocolVersion else {
            throw RivetDeviceError.unsupportedVersion(response.version)
        }
        guard response.id == id else {
            throw RivetDeviceError.responseIDMismatch
        }
        if let remote = response.error {
            throw RivetDeviceError.remote(code: remote.code, message: remote.message)
        }
        guard let responsePayload = response.payload else {
            throw RivetDeviceError.missingResponsePayload
        }
        return try JSONDecoder().decode(Request.Response.self, from: responsePayload)
    }
}

public actor RivetDeviceRouter {
    private typealias Handler = @Sendable (Data) async throws -> Data

    private var handlers: [String: Handler] = [:]
    private let maximumMessageSize: Int

    public init(maximumMessageSize: Int = rivetDeviceDefaultMaximumMessageSize) {
        precondition(maximumMessageSize > 0, "Rivet device message limit must be positive")
        self.maximumMessageSize = maximumMessageSize
    }

    public func register<Request: RivetDeviceRequest>(
        _ request: Request.Type = Request.self,
        handler: @escaping @Sendable (Request) async throws -> Request.Response
    ) throws {
        try validateRoute(Request.route)
        guard handlers[Request.route] == nil else {
            throw RivetDeviceError.duplicateRoute(Request.route)
        }
        handlers[Request.route] = { payload in
            let value = try JSONDecoder().decode(Request.self, from: payload)
            let result = try await handler(value)
            return try encoder().encode(result)
        }
    }

    public func handle(_ wireRequest: Data) async throws -> Data {
        try checkedSize(wireRequest, maximum: maximumMessageSize)
        guard let request = try? JSONDecoder().decode(RequestEnvelope.self, from: wireRequest) else {
            throw RivetDeviceError.malformedEnvelope
        }
        guard request.version == rivetDeviceProtocolVersion else {
            return try response(
                id: request.id,
                error: ErrorEnvelope(
                    code: "unsupported_version",
                    message: "unsupported Rivet device protocol version \(request.version)"
                )
            )
        }
        do {
            try validateRoute(request.route)
        } catch {
            return try response(
                id: request.id,
                error: ErrorEnvelope(code: "invalid_route", message: request.route)
            )
        }
        guard let handler = handlers[request.route] else {
            return try response(
                id: request.id,
                error: ErrorEnvelope(code: "unknown_route", message: request.route)
            )
        }

        do {
            let payload = try await handler(request.payload)
            return try response(id: request.id, payload: payload)
        } catch let error as any RivetDeviceRemoteError {
            return try response(
                id: request.id,
                error: ErrorEnvelope(
                    code: error.rivetDeviceErrorCode,
                    message: error.rivetDeviceErrorMessage
                )
            )
        } catch {
            return try response(
                id: request.id,
                error: ErrorEnvelope(code: "handler_error", message: "request handler failed")
            )
        }
    }

    private func response(
        id: UUID,
        payload: Data? = nil,
        error: ErrorEnvelope? = nil
    ) throws -> Data {
        let data = try encoder().encode(ResponseEnvelope(
            version: rivetDeviceProtocolVersion,
            id: id,
            payload: payload,
            error: error
        ))
        try checkedSize(data, maximum: maximumMessageSize)
        return data
    }
}
