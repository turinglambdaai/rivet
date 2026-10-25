import Foundation
import RivetDevice
import RivetDeviceSession
import RivetRuntime

public enum RivetDeviceAppleRVT1ClientError: Error, Equatable, Sendable {
    case alreadyStarted
    case invalidHello
    case invalidResponse
    case invalidState
    case handshakeTimedOut
    case handshakeFailed(String)
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
    private let helloTimeout: TimeInterval
    private var nextRequestID: UInt64 = 1
    private var pending: [UInt64: RivetDeviceApplePendingRequest] = [:]
    private var started = false
    private var stopped = false
    private var readerTask: Task<Void, Never>?
    private var eventHandler: EventHandler?
    private var terminated = false
    private var terminalError: (any Error)?
    private var terminationWaiters: [CheckedContinuation<Void, Never>] = []
    // Guards the one-shot hello deadline: the watchdog fires only when this
    // token still names the in-flight handshake attempt.
    private var helloAttempt = 0
    private var helloTimedOut = false

    public init(connection: RivetDeviceAppleConnection,
                maximumPendingRequests: Int = rivetDeviceDefaultMaximumPendingRequests,
                helloTimeout: TimeInterval = rivetDeviceSessionPostTLSTimeout) {
        precondition(maximumPendingRequests > 0)
        precondition(helloTimeout.isFinite && helloTimeout > 0)
        channel = RivetDeviceAppleRVT1Channel(connection: connection)
        self.maximumPendingRequests = maximumPendingRequests
        self.helloTimeout = helloTimeout
    }

    package init(stream: any RivetDeviceAppleApplicationByteStream,
                 maximumPendingRequests: Int = rivetDeviceDefaultMaximumPendingRequests,
                 helloTimeout: TimeInterval = rivetDeviceSessionPostTLSTimeout) {
        precondition(maximumPendingRequests > 0)
        precondition(helloTimeout.isFinite && helloTimeout > 0)
        channel = RivetDeviceAppleRVT1Channel(stream: stream)
        self.maximumPendingRequests = maximumPendingRequests
        self.helloTimeout = helloTimeout
    }

    public func start(onEvent: EventHandler? = nil) async throws {
        guard !started, !stopped else {
            throw RivetDeviceAppleRVT1ClientError.alreadyStarted
        }
        // A peer that RVD1 authenticated but then goes silent must not hold
        // the session open forever: the hello read carries the same post-TLS
        // deadline policy the RVD1 session layer applies (issue #312).
        helloTimedOut = false
        helloAttempt += 1
        let attempt = helloAttempt
        let timeout = helloTimeout
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            await self?.expireHello(unlessAttemptIs: attempt)
        }
        defer { watchdog.cancel() }
        let hello: RivetFrame
        do {
            hello = try await withTaskCancellationHandler {
                try await channel.receive()
            } onCancel: {
                Task { await self.stop() }
            }
        } catch {
            helloAttempt += 1
            stopped = true
            await channel.close()
            if Task.isCancelled { throw CancellationError() }
            if helloTimedOut {
                throw RivetDeviceAppleRVT1ClientError.handshakeTimedOut
            }
            throw Self.typedHandshakeError(error)
        }
        // Invalidate the watchdog before any further await so a deadline
        // that raced the hello cannot close a session that already holds it.
        helloAttempt += 1
        watchdog.cancel()
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

    /// Closes the channel so the suspended hello read fails promptly, and
    /// marks the handshake as deadline-expired for the catch above.
    private func expireHello(unlessAttemptIs attempt: Int) async {
        guard helloAttempt == attempt, !stopped else { return }
        helloAttempt += 1
        helloTimedOut = true
        await channel.close()
    }

    private static func typedHandshakeError(
        _ error: any Error
    ) -> RivetDeviceAppleRVT1ClientError {
        if let clientError = error as? RivetDeviceAppleRVT1ClientError {
            return clientError
        }
        return .handshakeFailed(String(describing: error))
    }

    /// Runs the RVT1 session until the peer disconnects or this client stops.
    /// Unlike start(), this keeps an application-handler task alive for the
    /// full connection lifetime, which is useful for companion coordinators.
    public func run(onEvent: EventHandler? = nil) async throws {
        do {
            try await withTaskCancellationHandler {
                try await start(onEvent: onEvent)
                await withCheckedContinuation {
                    (continuation: CheckedContinuation<Void, Never>) in
                    if terminated {
                        continuation.resume()
                    } else {
                        terminationWaiters.append(continuation)
                    }
                }
            } onCancel: {
                Task { await self.stop() }
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        if let terminalError { throw terminalError }
        try Task.checkCancellation()
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
        guard !stopped else {
            if let readerTask { await readerTask.value }
            return
        }
        stopped = true
        let task = readerTask
        readerTask = nil
        task?.cancel()
        failAll(RivetDeviceAppleRVT1ClientError.stopped)
        if started { try? await channel.send(RivetFrame(type: .shutdown, id: 0)) }
        await channel.close()
        if let task {
            await task.value
        } else {
            markTerminated()
        }
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
            if !stopped && !isNormalTermination(error) { terminalError = error }
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
        defer { markTerminated() }
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
            if !stopped && !isNormalTermination(error) { terminalError = error }
            stopped = true
            failAll(error)
            await channel.close()
        }
    }

    private func markTerminated() {
        guard !terminated else { return }
        terminated = true
        let waiters = terminationWaiters
        terminationWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
    }

    private func failConnection(_ error: any Error) async {
        if !stopped && !isNormalTermination(error) { terminalError = error }
        stopped = true
        failAll(error)
        await channel.close()
    }

    private func isNormalTermination(_ error: any Error) -> Bool {
        if let clientError = error as? RivetDeviceAppleRVT1ClientError,
           clientError == .stopped {
            return true
        }
        if let channelError = error as? RivetDeviceAppleRVT1ChannelError,
           channelError == .closed {
            return true
        }
        return false
    }

    private func failAll(_ error: any Error) {
        let requests = Array(pending.values)
        pending.removeAll(keepingCapacity: true)
        for request in requests { request.continuation?.resume(throwing: error) }
    }
}
