import Foundation

public let rivetDeviceDefaultMaximumPendingRequests = 64
public let rivetDeviceDefaultMaximumSessions = 8

/// A declarative, default-deny capability set assigned during device pairing.
public struct RivetDeviceScope: Equatable, Sendable {
    public let name: String
    public let rpcs: Set<String>
    public let events: Set<String>
    public let readableStates: Set<String>
    public let writableStates: Set<String>

    public init(
        name: String,
        rpcs: Set<String> = [],
        events: Set<String> = [],
        readableStates: Set<String> = [],
        writableStates: Set<String> = []
    ) {
        self.name = name
        self.rpcs = rpcs
        self.events = events
        self.readableStates = readableStates
        self.writableStates = writableStates
    }
}

public struct RivetDeviceGatewayHostCall: Sendable {
    public let id: UInt64
    public let response: Task<Data, any Error>

    public init(id: UInt64, response: Task<Data, any Error>) {
        self.id = id
        self.response = response
    }
}

/// The narrow adapter implemented by a future network host. The gateway owns
/// authorization and remote-to-host request ID translation; the adapter owns
/// the actual host client and its cancellation primitive.
public protocol RivetDeviceGatewayHost: Sendable {
    /// Payload is an encoded RivetValue list containing the RPC arguments.
    /// The adapter decodes it for the embedded backend and encodes the result
    /// as a RivetValue. Returned IDs must be nonzero and unique across
    /// simultaneously pending calls; cancellation must affect exactly that ID.
    func startRPC(name: String, payload: Data) async throws -> RivetDeviceGatewayHostCall
    func cancelRPC(id: UInt64) async
}

public protocol RivetDeviceSessionRevoker: Sendable {
    func revokeSessions(deviceID: UUID) async
}

public enum RivetDeviceGatewayError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidName(String)
    case forbidden
    case invalidRequestID
    case duplicateRequestID(UInt64)
    case pendingRequestLimit(Int)
    case messageTooLarge(actual: Int, maximum: Int)
    case duplicateSession(UUID)
    case sessionLimit(Int)
    case sessionClosed
    case cancelled

    public var description: String {
        switch self {
        case .invalidName(let name):
            return "invalid Rivet device API name: \(name)"
        case .forbidden:
            return "Rivet device operation is not permitted"
        case .invalidRequestID:
            return "Rivet device request id must be nonzero"
        case .duplicateRequestID(let id):
            return "duplicate Rivet device request id \(id)"
        case .pendingRequestLimit(let maximum):
            return "Rivet device session has reached its \(maximum)-request limit"
        case .messageTooLarge(let actual, let maximum):
            return "Rivet device message is \(actual) bytes; maximum is \(maximum)"
        case .duplicateSession(let id):
            return "duplicate Rivet device session \(id)"
        case .sessionLimit(let maximum):
            return "Rivet device gateway has reached its \(maximum)-session limit"
        case .sessionClosed:
            return "Rivet device session is closed"
        case .cancelled:
            return "Rivet device request was cancelled"
        }
    }
}

private struct RivetDeviceGatewayGrants: Sendable {
    var rpcs: Set<String> = []
    var events: Set<String> = []
    var readableStates: Set<String> = []
    var writableStates: Set<String> = []

    init(scopes: [RivetDeviceScope]) {
        for scope in scopes {
            rpcs.formUnion(scope.rpcs)
            events.formUnion(scope.events)
            readableStates.formUnion(scope.readableStates)
            writableStates.formUnion(scope.writableStates)
        }
    }
}

package func isValidDeviceAPIName(_ name: String) -> Bool {
    !name.isEmpty
        && name.utf8.count <= 128
        && name.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || ".-_".unicodeScalars.contains($0)
        }
}

private func validateDeviceScope(_ scope: RivetDeviceScope) throws {
    let names = [scope.name]
        + scope.rpcs.sorted()
        + scope.events.sorted()
        + scope.readableStates.sorted()
        + scope.writableStates.sorted()
    if let invalid = names.first(where: { !isValidDeviceAPIName($0) }) {
        throw RivetDeviceGatewayError.invalidName(invalid)
    }
}

private struct RivetDevicePendingCall: Sendable {
    let token: UUID
    var hostRequestID: UInt64?
    var cancellationRequested: Bool
}

/// A single authenticated device session. Each session owns its request-ID
/// namespace, pending calls, and effective capabilities.
public actor RivetDeviceGatewaySession {
    public nonisolated let id: UUID
    public nonisolated let pairedDeviceID: UUID

    private let host: any RivetDeviceGatewayHost
    private let grants: RivetDeviceGatewayGrants
    private let maximumMessageSize: Int
    private let maximumPendingRequests: Int
    private var pending: [UInt64: RivetDevicePendingCall] = [:]
    private var closed = false

    init(
        id: UUID = UUID(),
        pairedDeviceID: UUID,
        scopes: [RivetDeviceScope],
        host: any RivetDeviceGatewayHost,
        maximumMessageSize: Int = rivetDeviceDefaultMaximumMessageSize,
        maximumPendingRequests: Int = rivetDeviceDefaultMaximumPendingRequests
    ) throws {
        precondition(maximumMessageSize > 0, "Rivet device message limit must be positive")
        precondition(maximumPendingRequests > 0, "Rivet device pending-request limit must be positive")
        for scope in scopes {
            try validateDeviceScope(scope)
        }
        self.id = id
        self.pairedDeviceID = pairedDeviceID
        self.host = host
        self.grants = RivetDeviceGatewayGrants(scopes: scopes)
        self.maximumMessageSize = maximumMessageSize
        self.maximumPendingRequests = maximumPendingRequests
    }

    public func invokeRPC(
        remoteRequestID: UInt64,
        name: String,
        payload: Data
    ) async throws -> Data {
        // State routes must carry an explicit state name through the guarded
        // API below; treating them as ordinary RPCs would let one granted
        // state capability unlock every state of the same direction.
        guard name != "$state/get", name != "$state/set" else {
            throw RivetDeviceGatewayError.forbidden
        }
        return try await invokeRPCInternal(
            remoteRequestID: remoteRequestID,
            name: name,
            payload: payload,
            isStateRoute: false
        )
    }

    package func invokeStateRPC(
        remoteRequestID: UInt64,
        name: String,
        stateName: String,
        payload: Data
    ) async throws -> Data {
        switch name {
        case "$state/get":
            try requireStateRead(stateName)
        case "$state/set":
            try requireStateWrite(stateName)
        default:
            throw RivetDeviceGatewayError.forbidden
        }
        return try await invokeRPCInternal(
            remoteRequestID: remoteRequestID,
            name: name,
            payload: payload,
            isStateRoute: true
        )
    }

    private func invokeRPCInternal(
        remoteRequestID: UInt64,
        name: String,
        payload: Data,
        isStateRoute: Bool
    ) async throws -> Data {
        guard !closed else {
            throw RivetDeviceGatewayError.sessionClosed
        }
        guard !Task.isCancelled else {
            throw RivetDeviceGatewayError.cancelled
        }
        guard remoteRequestID != 0 else {
            throw RivetDeviceGatewayError.invalidRequestID
        }
        if isStateRoute {
            guard name == "$state/get" || name == "$state/set" else {
                throw RivetDeviceGatewayError.forbidden
            }
        } else {
            // Unknown and ungranted names intentionally have the same result.
            guard grants.rpcs.contains(name) else {
                throw RivetDeviceGatewayError.forbidden
            }
        }
        try checkMessageSize(payload)
        guard pending[remoteRequestID] == nil else {
            throw RivetDeviceGatewayError.duplicateRequestID(remoteRequestID)
        }
        guard pending.count < maximumPendingRequests else {
            throw RivetDeviceGatewayError.pendingRequestLimit(maximumPendingRequests)
        }

        let token = UUID()
        pending[remoteRequestID] = RivetDevicePendingCall(
            token: token,
            hostRequestID: nil,
            cancellationRequested: false
        )

        let call: RivetDeviceGatewayHostCall
        do {
            call = try await host.startRPC(name: name, payload: payload)
        } catch {
            finish(remoteRequestID: remoteRequestID, token: token)
            throw error
        }

        guard var entry = pending[remoteRequestID], entry.token == token else {
            await host.cancelRPC(id: call.id)
            throw RivetDeviceGatewayError.cancelled
        }
        entry.hostRequestID = call.id
        pending[remoteRequestID] = entry
        if entry.cancellationRequested || closed {
            await host.cancelRPC(id: call.id)
        }

        do {
            let response = try await call.response.value
            let wasCancelled = cancellationWasRequested(
                remoteRequestID: remoteRequestID,
                token: token
            )
            finish(remoteRequestID: remoteRequestID, token: token)
            if wasCancelled {
                throw RivetDeviceGatewayError.cancelled
            }
            try checkMessageSize(response)
            return response
        } catch {
            let wasCancelled = cancellationWasRequested(
                remoteRequestID: remoteRequestID,
                token: token
            )
            finish(remoteRequestID: remoteRequestID, token: token)
            if wasCancelled {
                throw RivetDeviceGatewayError.cancelled
            }
            throw error
        }
    }

    /// Cancellation is deliberately silent for unknown IDs so one session
    /// cannot probe request ownership in another session.
    public func cancel(remoteRequestID: UInt64) async {
        guard var entry = pending[remoteRequestID] else {
            return
        }
        guard !entry.cancellationRequested else {
            return
        }
        entry.cancellationRequested = true
        pending[remoteRequestID] = entry
        if let hostRequestID = entry.hostRequestID {
            await host.cancelRPC(id: hostRequestID)
        }
    }

    public func filterEvent(name: String, payload: Data) throws -> Data? {
        guard !closed else {
            throw RivetDeviceGatewayError.sessionClosed
        }
        // State changes have a separate state-name authorization path;
        // never let an ordinary event grant bypass readable-state filtering.
        guard name != "$state", grants.events.contains(name) else {
            return nil
        }
        try checkMessageSize(payload)
        return payload
    }

    /// State-change delivery follows read permission: a device that cannot
    /// read a state also cannot learn that the state changed.
    public func filterStateChange(name: String, payload: Data) throws -> Data? {
        guard !closed else {
            throw RivetDeviceGatewayError.sessionClosed
        }
        guard grants.readableStates.contains(name) else {
            return nil
        }
        try checkMessageSize(payload)
        return payload
    }

    public func requireStateRead(_ name: String) throws {
        guard !closed else {
            throw RivetDeviceGatewayError.sessionClosed
        }
        guard grants.readableStates.contains(name) else {
            throw RivetDeviceGatewayError.forbidden
        }
    }

    public func requireStateWrite(_ name: String) throws {
        guard !closed else {
            throw RivetDeviceGatewayError.sessionClosed
        }
        guard grants.writableStates.contains(name) else {
            throw RivetDeviceGatewayError.forbidden
        }
    }

    public func disconnect() async {
        guard !closed else {
            return
        }
        closed = true
        let hostRequestIDs = pending.compactMap { remoteID, entry -> UInt64? in
            var updated = entry
            updated.cancellationRequested = true
            pending[remoteID] = updated
            return updated.hostRequestID
        }
        for hostRequestID in hostRequestIDs {
            await host.cancelRPC(id: hostRequestID)
        }
    }

    public func pendingRequestCount() -> Int {
        pending.count
    }

    public func isClosed() -> Bool {
        closed
    }

    private func checkMessageSize(_ data: Data) throws {
        guard data.count <= maximumMessageSize else {
            throw RivetDeviceGatewayError.messageTooLarge(
                actual: data.count,
                maximum: maximumMessageSize
            )
        }
    }

    private func cancellationWasRequested(remoteRequestID: UInt64, token: UUID) -> Bool {
        guard let entry = pending[remoteRequestID], entry.token == token else {
            return true
        }
        return entry.cancellationRequested || closed
    }

    private func finish(remoteRequestID: UInt64, token: UUID) {
        guard pending[remoteRequestID]?.token == token else {
            return
        }
        pending.removeValue(forKey: remoteRequestID)
    }
}

/// Owns the bounded set of authenticated sessions. Network discovery, TLS,
/// pairing storage, and wire decoding intentionally sit outside this core.
public actor RivetDeviceGateway: RivetDeviceSessionRevoker {
    private let host: any RivetDeviceGatewayHost
    private let maximumSessions: Int
    private let maximumMessageSize: Int
    private let maximumPendingRequestsPerSession: Int
    private var sessions: [UUID: RivetDeviceGatewaySession] = [:]

    public init(
        host: any RivetDeviceGatewayHost,
        maximumSessions: Int = rivetDeviceDefaultMaximumSessions,
        maximumMessageSize: Int = rivetDeviceDefaultMaximumMessageSize,
        maximumPendingRequestsPerSession: Int = rivetDeviceDefaultMaximumPendingRequests
    ) {
        precondition(maximumSessions > 0, "Rivet device session limit must be positive")
        precondition(maximumMessageSize > 0, "Rivet device message limit must be positive")
        precondition(
            maximumPendingRequestsPerSession > 0,
            "Rivet device pending-request limit must be positive"
        )
        self.host = host
        self.maximumSessions = maximumSessions
        self.maximumMessageSize = maximumMessageSize
        self.maximumPendingRequestsPerSession = maximumPendingRequestsPerSession
    }

    public func openSession(
        id: UUID = UUID(),
        pairedDeviceID: UUID,
        scopes: [RivetDeviceScope]
    ) throws -> RivetDeviceGatewaySession {
        guard sessions[id] == nil else {
            throw RivetDeviceGatewayError.duplicateSession(id)
        }
        guard sessions.count < maximumSessions else {
            throw RivetDeviceGatewayError.sessionLimit(maximumSessions)
        }
        let session = try RivetDeviceGatewaySession(
            id: id,
            pairedDeviceID: pairedDeviceID,
            scopes: scopes,
            host: host,
            maximumMessageSize: maximumMessageSize,
            maximumPendingRequests: maximumPendingRequestsPerSession
        )
        sessions[id] = session
        return session
    }

    public func session(id: UUID) -> RivetDeviceGatewaySession? {
        sessions[id]
    }

    public func closeSession(id: UUID) async {
        guard let session = sessions.removeValue(forKey: id) else {
            return
        }
        await session.disconnect()
    }

    public func closeAllSessions() async {
        let activeSessions = Array(sessions.values)
        sessions.removeAll(keepingCapacity: true)
        for session in activeSessions {
            await session.disconnect()
        }
    }

    public func revokeSessions(deviceID: UUID) async {
        let revoked = sessions.filter { $0.value.pairedDeviceID == deviceID }
        for (sessionID, _) in revoked {
            sessions.removeValue(forKey: sessionID)
        }
        for (_, session) in revoked {
            await session.disconnect()
        }
    }

    public func sessionCount() -> Int {
        sessions.count
    }
}
