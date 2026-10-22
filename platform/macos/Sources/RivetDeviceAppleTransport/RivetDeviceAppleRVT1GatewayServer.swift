import Foundation
import RivetDevice
import RivetRuntime

public enum RivetDeviceAppleRVT1GatewayServerError: Error, Equatable, Sendable {
    case alreadyStarted
    case notRunning
    case invalidFrame
    case invalidRequest
    case invalidRequestID
    case duplicateRequestID(UInt64)
}

/// Terminates the post-RVD1 RVT1 stream and applies per-pairing gateway
/// permissions before dispatching any RPC to the embedded backend.
public actor RivetDeviceAppleRVT1GatewayServer {
    private enum Route: Sendable {
        case rpc
        case stateRead(String)
        case stateWrite(String)
    }

    private let channel: RivetDeviceAppleRVT1Channel
    private let gateway: RivetDeviceGateway
    private let session: RivetDeviceGatewaySession
    private var started = false
    private var ready = false
    private var stopping = false
    private var closed = false
    private var activeIDs = Set<UInt64>()
    private var cancelledIDs = Set<UInt64>()
    private var requestTasks: [UInt64: Task<Void, Never>] = [:]

    public init(
        connection: RivetDeviceAppleConnection,
        gateway: RivetDeviceGateway,
        session: RivetDeviceGatewaySession
    ) {
        channel = RivetDeviceAppleRVT1Channel(connection: connection)
        self.gateway = gateway
        self.session = session
    }

    package init(
        stream: any RivetDeviceAppleApplicationByteStream,
        gateway: RivetDeviceGateway,
        session: RivetDeviceGatewaySession
    ) {
        channel = RivetDeviceAppleRVT1Channel(stream: stream)
        self.gateway = gateway
        self.session = session
    }

    /// Runs until the client sends Shutdown or the authenticated stream closes.
    /// The gateway session is always revoked when this method exits.
    public func run() async throws {
        guard !started, !closed else {
            throw RivetDeviceAppleRVT1GatewayServerError.alreadyStarted
        }
        started = true
        do {
            let hello = try encodeRivetValue(.list([
                .string("rivet"),
                .int64(Int64(rivetProtocolVersion))
            ]))
            try await channel.send(RivetFrame(type: .hello, id: 0, payload: hello))
            ready = true
            while !stopping {
                let frame = try await channel.receive()
                switch frame.type {
                case .request:
                    try await acceptRequest(frame)
                case .cancel:
                    guard frame.id != 0, frame.payload.isEmpty else {
                        throw RivetDeviceAppleRVT1GatewayServerError.invalidFrame
                    }
                    await cancelRequest(id: frame.id)
                case .shutdown:
                    guard frame.id == 0, frame.payload.isEmpty else {
                        throw RivetDeviceAppleRVT1GatewayServerError.invalidFrame
                    }
                    stopping = true
                default:
                    throw RivetDeviceAppleRVT1GatewayServerError.invalidFrame
                }
            }
            // A peer can shut down while an RPC is waiting on an unresponsive
            // backend. Revoke the session and cancel outstanding work instead
            // of waiting for every response before the connection can close.
            await close()
        } catch {
            await close()
            throw error
        }
    }

    /// Sends an event only if this paired device has the named event grant.
    @discardableResult
    public func sendEvent(name: String, value: RivetValue) async throws -> Bool {
        guard ready, !stopping, !closed else {
            throw RivetDeviceAppleRVT1GatewayServerError.notRunning
        }
        let payload = try encodeRivetValue(.list([.string(name), value]))
        guard let filtered = try await session.filterEvent(name: name, payload: payload) else {
            return false
        }
        guard ready, !stopping, !closed else {
            throw RivetDeviceAppleRVT1GatewayServerError.notRunning
        }
        try await channel.send(RivetFrame(type: .event, id: 0, payload: filtered))
        return true
    }

    /// State changes use the standard $state event and are filtered against
    /// the paired device's read grants.
    @discardableResult
    public func sendStateChange(name: String, value: RivetValue) async throws -> Bool {
        guard ready, !stopping, !closed else {
            throw RivetDeviceAppleRVT1GatewayServerError.notRunning
        }
        let payload = try encodeRivetValue(.list([
            .string("$state"),
            .list([.string(name), value])
        ]))
        guard let filtered = try await session.filterStateChange(
            name: name,
            payload: payload
        ) else {
            return false
        }
        guard ready, !stopping, !closed else {
            throw RivetDeviceAppleRVT1GatewayServerError.notRunning
        }
        try await channel.send(RivetFrame(type: .event, id: 0, payload: filtered))
        return true
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        ready = false
        stopping = true
        let ids = Array(activeIDs)
        for id in ids {
            cancelledIDs.insert(id)
            await session.cancel(remoteRequestID: id)
        }
        let tasks = Array(requestTasks.values)
        for task in tasks {
            task.cancel()
        }
        await channel.close()
        await gateway.closeSession(id: session.id)
    }

    private func acceptRequest(_ frame: RivetFrame) async throws {
        guard frame.id != 0 else {
            throw RivetDeviceAppleRVT1GatewayServerError.invalidRequestID
        }
        guard activeIDs.insert(frame.id).inserted else {
            throw RivetDeviceAppleRVT1GatewayServerError.duplicateRequestID(frame.id)
        }
        do {
            guard case .list(let fields) = try decodeRivetValue(frame.payload),
                  let first = fields.first,
                  case .string(let name) = first else {
                throw RivetDeviceAppleRVT1GatewayServerError.invalidRequest
            }
            let arguments = Array(fields.dropFirst())
            let route: Route
            switch name {
            case "$state/get":
                guard arguments.count == 1,
                      case .string(let stateName) = arguments[0] else {
                    throw RivetDeviceAppleRVT1GatewayServerError.invalidRequest
                }
                route = .stateRead(stateName)
            case "$state/set":
                guard arguments.count == 2,
                      case .string(let stateName) = arguments[0] else {
                    throw RivetDeviceAppleRVT1GatewayServerError.invalidRequest
                }
                route = .stateWrite(stateName)
            default:
                route = .rpc
            }
            let payload = try encodeRivetValue(.list(arguments))
            let session = self.session
            let task = Task { [weak self] in
                do {
                    let response: Data
                    switch route {
                    case .rpc:
                        response = try await session.invokeRPC(
                            remoteRequestID: frame.id,
                            name: name,
                            payload: payload
                        )
                    case .stateRead(let stateName), .stateWrite(let stateName):
                        response = try await session.invokeStateRPC(
                            remoteRequestID: frame.id,
                            name: name,
                            stateName: stateName,
                            payload: payload
                        )
                    }
                    await self?.completeRequest(id: frame.id, response: response)
                } catch {
                    await self?.completeRequest(id: frame.id, error: error)
                }
            }
            requestTasks[frame.id] = task
        } catch {
            activeIDs.remove(frame.id)
            try await sendError(id: frame.id, message: safeMessage(for: error))
        }
    }

    private func cancelRequest(id: UInt64) async {
        guard id != 0, activeIDs.contains(id) else { return }
        cancelledIDs.insert(id)
        // Cancel the dispatch task as well as forwarding cancellation to the
        // session. If dispatch has not entered the gateway yet, its
        // Task.isCancelled guard prevents a cancelled RPC from starting.
        requestTasks[id]?.cancel()
        await session.cancel(remoteRequestID: id)
    }

    private func completeRequest(
        id: UInt64,
        response: Data? = nil,
        error: (any Error)? = nil
    ) async {
        guard activeIDs.contains(id) else { return }
        if cancelledIDs.remove(id) != nil || closed {
            activeIDs.remove(id)
            requestTasks.removeValue(forKey: id)
            return
        }
        activeIDs.remove(id)
        requestTasks.removeValue(forKey: id)
        do {
            if let response {
                try await channel.send(RivetFrame(type: .response, id: id, payload: response))
            } else {
                try await sendError(id: id, message: safeMessage(for: error))
            }
        } catch {
            await close()
        }
    }

    private func sendError(id: UInt64, message: String) async throws {
        let payload = try encodeRivetValue(.string(message))
        try await channel.send(RivetFrame(type: .error, id: id, payload: payload))
    }

    private func safeMessage(for error: (any Error)?) -> String {
        guard let error else { return "request failed" }
        if let gatewayError = error as? RivetDeviceGatewayError {
            switch gatewayError {
            case .forbidden:
                return "operation not permitted"
            case .cancelled:
                return "request cancelled"
            default:
                return "request failed"
            }
        }
        if error is RivetDeviceAppleRVT1GatewayServerError {
            return "invalid request"
        }
        return "request failed"
    }
}
