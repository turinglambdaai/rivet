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

/// Identity for one request dispatch. A backend that ignores cancellation
/// never completes its task, so completions are matched by per-dispatch
/// token: a late dispatch for a retired request id cannot answer a newer
/// request that reused the id (issue #312).
private struct RequestDispatch: Sendable {
    let token: UUID
    let task: Task<Void, Never>
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
    private var requestTasks: [UInt64: RequestDispatch] = [:]

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
            try await withTaskCancellationHandler {
                try await self.runLoop()
            } onCancel: {
                Task { await self.close() }
            }
        } catch {
            await close()
            if Task.isCancelled { throw CancellationError() }
            if let channelError = error as? RivetDeviceAppleRVT1ChannelError,
               channelError == .closed {
                return
            }
            throw error
        }
    }

    private func runLoop() async throws {
        let hello = try encodeRivetValue(.list([
            .string("rivet"),
            .int64(Int64(rivetProtocolVersion))
        ]))
        // The hello write suspends while its bytes join the channel's
        // serialized queue, and a product observing those bytes may call
        // sendEvent immediately. Ready must be set before the write so that
        // call does not race this actor's resumption and fail with
        // notRunning; the channel queue keeps hello ahead of any event.
        ready = true
        try await channel.send(RivetFrame(type: .hello, id: 0, payload: hello))
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
            await session.cancel(remoteRequestID: id)
        }
        let tasks = Array(requestTasks.values)
        for dispatch in tasks {
            dispatch.task.cancel()
        }
        await channel.close()
        await gateway.closeSession(id: session.id)
    }

    private func acceptRequest(_ frame: RivetFrame) async throws {
        guard frame.id != 0 else {
            throw RivetDeviceAppleRVT1GatewayServerError.invalidRequestID
        }
        guard !activeIDs.contains(frame.id) else {
            throw RivetDeviceAppleRVT1GatewayServerError.duplicateRequestID(frame.id)
        }
        guard activeIDs.count < rivetDeviceDefaultMaximumPendingRequests else {
            try await sendError(id: frame.id, message: "too many pending requests")
            return
        }
        activeIDs.insert(frame.id)
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
            let token = UUID()
            let dispatch = RequestDispatch(token: token, task: Task { [weak self] in
                do {
                    // A dispatch cancelled before it starts is stopped by
                    // the session's own isCancelled guard, so it never
                    // registers a pending call.
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
                    await self?.completeRequest(
                        id: frame.id, token: token, response: response
                    )
                } catch {
                    await self?.completeRequest(
                        id: frame.id, token: token, error: error
                    )
                }
            })
            requestTasks[frame.id] = dispatch
        } catch {
            activeIDs.remove(frame.id)
            try await sendError(id: frame.id, message: safeMessage(for: error))
        }
    }

    private func cancelRequest(id: UInt64) async {
        guard id != 0, activeIDs.contains(id) else { return }
        // The peer retired this id when it sent the cancel, so the wire slot
        // is freed immediately; a dispatch that ignores cancellation keeps
        // running but its late completion no longer matches (issue #312).
        activeIDs.remove(id)
        requestTasks.removeValue(forKey: id)?.task.cancel()
        await session.cancel(remoteRequestID: id)
    }

    private func completeRequest(
        id: UInt64,
        token: UUID,
        response: Data? = nil,
        error: (any Error)? = nil
    ) async {
        guard requestTasks[id]?.token == token else { return }
        requestTasks.removeValue(forKey: id)
        activeIDs.remove(id)
        guard !closed else { return }
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
