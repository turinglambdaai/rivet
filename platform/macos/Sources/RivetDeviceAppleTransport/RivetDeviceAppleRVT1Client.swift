import Foundation
import RivetDevice
import RivetRuntime

public enum RivetDeviceAppleRVT1ClientError: Error, Equatable, Sendable {
    case alreadyStarted
    case invalidHello
    case invalidResponse
    case invalidState
    case tooManyPendingRequests(Int)
    case messageTooLarge(actual: Int, maximum: Int)
    case remote(String)
    case stopped
}

private struct RivetDeviceApplePendingRequest {
    var continuation: CheckedContinuation<RivetValue, Error>?
    var cancelled = false
    var requestSent = false
    var cancelSent = false
}

/// Typed RVT1 client for an authenticated Apple device connection.
public actor RivetDeviceAppleRVT1Client: RivetRPCClient {
    public typealias EventHandler = @Sendable (String, RivetValue) -> Void
    private let channel: RivetDeviceAppleRVT1Channel
    private let maximumPendingRequests: Int
    private var nextRequestID: UInt64 = 1
    private var pending: [UInt64: RivetDeviceApplePendingRequest] = [:]
    private var started = false
    private var stopped = false
    private var readerTask: Task<Void, Never>?
    private var eventHandler: EventHandler?

    public init(connection: RivetDeviceAppleConnection,
                maximumPendingRequests: Int = rivetDeviceDefaultMaximumPendingRequests) {
        precondition(maximumPendingRequests > 0)
        channel = RivetDeviceAppleRVT1Channel(connection: connection)
        self.maximumPendingRequests = maximumPendingRequests
    }

    package init(stream: any RivetDeviceAppleApplicationByteStream,
                 maximumPendingRequests: Int = rivetDeviceDefaultMaximumPendingRequests) {
        precondition(maximumPendingRequests > 0)
        channel = RivetDeviceAppleRVT1Channel(stream: stream)
        self.maximumPendingRequests = maximumPendingRequests
    }

    public func start(onEvent: EventHandler? = nil) async throws {
        guard !started, !stopped else {
            throw RivetDeviceAppleRVT1ClientError.alreadyStarted
        }
        let hello: RivetFrame
        do { hello = try await channel.receive() }
        catch { stopped = true; await channel.close(); throw error }
        guard hello.type == .hello, hello.id == 0 else {
            stopped = true
            await channel.close()
            throw RivetDeviceAppleRVT1ClientError.invalidHello
        }
        do {
            guard try decodeRivetValue(hello.payload) == .list([
                .string("rivet"), .int64(Int64(rivetProtocolVersion))
            ]) else {
                throw RivetDeviceAppleRVT1ClientError.invalidHello
            }
        } catch {
            stopped = true
            await channel.close()
            throw RivetDeviceAppleRVT1ClientError.invalidHello
        }
        eventHandler = onEvent
        started = true
        readerTask = Task { [weak self] in await self?.readLoop() }
    }

    public func call(_ name: String, arguments: [RivetValue] = []) async throws -> RivetValue {
        guard started, !stopped else { throw RivetDeviceAppleRVT1ClientError.invalidState }
        guard pending.count < maximumPendingRequests else {
            throw RivetDeviceAppleRVT1ClientError.tooManyPendingRequests(maximumPendingRequests)
        }
        let payload = try encodeRivetValue(.list([.string(name)] + arguments))
        guard payload.count <= rivetDeviceDefaultMaximumMessageSize else {
            throw RivetDeviceAppleRVT1ClientError.messageTooLarge(
                actual: payload.count, maximum: rivetDeviceDefaultMaximumMessageSize
            )
        }
        let id = allocateRequestID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<RivetValue, Error>) in
                pending[id] = RivetDeviceApplePendingRequest(continuation: continuation)
                Task { await self.sendRequest(id: id, payload: payload) }
            }
        } onCancel: {
            Task { await self.cancelRequest(id: id) }
        }
    }

    public func stop() async {
        guard !stopped else { return }
        stopped = true
        readerTask?.cancel()
        readerTask = nil
        failAll(RivetDeviceAppleRVT1ClientError.stopped)
        if started { try? await channel.send(RivetFrame(type: .shutdown, id: 0)) }
        await channel.close()
    }

    private func allocateRequestID() -> UInt64 {
        for _ in 0...pending.count {
            let candidate = nextRequestID
            nextRequestID = nextRequestID == UInt64.max ? 1 : nextRequestID + 1
            if candidate != 0, pending[candidate] == nil { return candidate }
        }
        preconditionFailure("Rivet request ID allocator invariant violated")
    }

    private func sendRequest(id: UInt64, payload: Data) async {
        guard let entry = pending[id] else { return }
        if entry.cancelled { pending.removeValue(forKey: id); return }
        do {
            try await channel.send(RivetFrame(type: .request, id: id, payload: payload))
            guard var current = pending[id] else { return }
            current.requestSent = true
            if current.cancelled && !current.cancelSent {
                current.cancelSent = true
                pending.removeValue(forKey: id)
                Task {
                    do { try await channel.send(RivetFrame(type: .cancel, id: id)) }
                    catch { await self.failConnection(error) }
                }
            } else { pending[id] = current }
        } catch {
            stopped = true
            failAll(error)
            await channel.close()
        }
    }

    private func cancelRequest(id: UInt64) async {
        guard var entry = pending[id] else { return }
        entry.cancelled = true
        entry.continuation?.resume(throwing: CancellationError())
        entry.continuation = nil
        if entry.requestSent && !entry.cancelSent {
            entry.cancelSent = true
            pending.removeValue(forKey: id)
            Task {
                do { try await channel.send(RivetFrame(type: .cancel, id: id)) }
                catch { await self.failConnection(error) }
            }
        } else { pending[id] = entry }
    }

    private func readLoop() async {
        do {
            while !Task.isCancelled && !stopped {
                let frame = try await channel.receive()
                switch frame.type {
                case .response:
                    guard frame.id != 0 else {
                        throw RivetDeviceAppleRVT1ClientError.invalidResponse
                    }
                    let value = try decodeRivetValue(frame.payload)
                    guard let request = pending.removeValue(forKey: frame.id) else { continue }
                    request.continuation?.resume(returning: value)
                case .error:
                    guard frame.id != 0 else {
                        throw RivetDeviceAppleRVT1ClientError.invalidResponse
                    }
                    guard case .string(let message) = try decodeRivetValue(frame.payload) else {
                        throw RivetDeviceAppleRVT1ClientError.invalidResponse
                    }
                    guard let request = pending.removeValue(forKey: frame.id) else { continue }
                    request.continuation?.resume(
                        throwing: RivetDeviceAppleRVT1ClientError.remote(message)
                    )
                case .event:
                    guard frame.id == 0,
                          case .list(let fields) = try decodeRivetValue(frame.payload),
                          fields.count == 2,
                          case .string(let name) = fields[0] else {
                        throw RivetDeviceAppleRVT1ClientError.invalidResponse
                    }
                    eventHandler?(name, fields[1])
                case .shutdown:
                    guard frame.id == 0, frame.payload.isEmpty else {
                        throw RivetDeviceAppleRVT1ClientError.invalidResponse
                    }
                    throw RivetDeviceAppleRVT1ClientError.stopped
                default:
                    throw RivetDeviceAppleRVT1ClientError.invalidResponse
                }
            }
        } catch {
            stopped = true
            failAll(error)
            await channel.close()
        }
    }

    private func failConnection(_ error: any Error) async {
        stopped = true
        failAll(error)
        await channel.close()
    }

    private func failAll(_ error: any Error) {
        let requests = Array(pending.values)
        pending.removeAll(keepingCapacity: true)
        for request in requests { request.continuation?.resume(throwing: error) }
    }
}
