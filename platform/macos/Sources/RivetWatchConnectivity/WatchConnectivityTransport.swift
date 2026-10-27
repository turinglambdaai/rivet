#if canImport(WatchConnectivity)
@preconcurrency import WatchConnectivity
import Foundation
import RivetDevice

public final class RivetWatchConnectivityTransport: NSObject, RivetDeviceTransport, @unchecked Sendable {
    private let session: WCSession
    private let router: RivetDeviceRouter?
    private let messagePolicy: RivetWatchMessagePolicy
    private let requestTimeoutNanoseconds: UInt64
    private let outgoingBudget: RivetWatchRequestBudget
    private let incomingBudget: RivetWatchRequestBudget
    private let stateContinuation: AsyncStream<RivetWatchConnectivityState>.Continuation
    public let stateChanges: AsyncStream<RivetWatchConnectivityState>

    public init(
        session: WCSession = .default,
        router: RivetDeviceRouter? = nil,
        messagePolicy: RivetWatchMessagePolicy = RivetWatchMessagePolicy(),
        requestTimeout: TimeInterval = 15,
        maximumConcurrentRequests: Int = 4
    ) {
        precondition(requestTimeout.isFinite && requestTimeout >= 1 && requestTimeout <= 120)
        precondition((1...32).contains(maximumConcurrentRequests))
        self.session = session
        self.router = router
        self.messagePolicy = messagePolicy
        requestTimeoutNanoseconds = UInt64(requestTimeout * 1_000_000_000)
        outgoingBudget = RivetWatchRequestBudget(maximumConcurrentRequests: maximumConcurrentRequests)
        incomingBudget = RivetWatchRequestBudget(maximumConcurrentRequests: maximumConcurrentRequests)
        let (stateChanges, stateContinuation) = AsyncStream.makeStream(
            of: RivetWatchConnectivityState.self,
            bufferingPolicy: .bufferingNewest(16)
        )
        self.stateChanges = stateChanges
        self.stateContinuation = stateContinuation
        super.init()
        session.delegate = self
    }

    deinit {
        stateContinuation.finish()
    }

    public var currentState: RivetWatchConnectivityState {
        guard WCSession.isSupported() else { return .unsupported }
        switch session.activationState {
        case .activated:
            return session.isReachable ? .reachable : .notReachable
        case .notActivated, .inactive:
            return .inactive
        @unknown default:
            return .failed
        }
    }

    public func activate() throws {
        guard WCSession.isSupported() else {
            throw RivetWatchConnectivityError.notSupported
        }
        // Do not enqueue a stale .inactive snapshot if the session was
        // already active/reachable before the SwiftUI consumer subscribed.
        stateContinuation.yield(currentState)
        if session.activationState != .activated {
            session.activate()
        }
    }

    public func send(_ request: Data) async throws -> Data {
        try messagePolicy.validate(request)
        guard WCSession.isSupported() else {
            throw RivetWatchConnectivityError.notSupported
        }
        guard session.activationState == .activated else {
            throw RivetWatchConnectivityError.notActivated
        }
        guard session.isReachable else {
            throw RivetWatchConnectivityError.notReachable
        }
        guard outgoingBudget.acquire() else {
            throw RivetWatchConnectivityError.tooManyPendingRequests
        }
        defer { outgoingBudget.release() }
        let policy = messagePolicy
        let pending = RivetWatchPendingReply()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Data, Error>) in
                guard pending.install(continuation) else { return }
                guard !Task.isCancelled else {
                    pending.complete(.failure(CancellationError()))
                    return
                }
                pending.armTimeout(nanoseconds: requestTimeoutNanoseconds)
                session.sendMessageData(
                    request,
                    replyHandler: { data in
                        if data.isEmpty {
                            pending.complete(.failure(RivetWatchConnectivityError.emptyReply))
                        } else {
                            do {
                                try policy.validate(data)
                                pending.complete(.success(data))
                            } catch {
                                pending.complete(.failure(error))
                            }
                        }
                    },
                    errorHandler: { error in
                        pending.complete(.failure(error))
                    }
                )
            }
        } onCancel: {
            pending.complete(.failure(CancellationError()))
        }
    }
}

extension RivetWatchConnectivityTransport: WCSessionDelegate {
    public func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        stateContinuation.yield(error == nil ? currentState : .failed)
    }

    public func sessionReachabilityDidChange(_ session: WCSession) {
        stateContinuation.yield(currentState)
    }

    public func session(
        _ session: WCSession,
        didReceiveMessageData messageData: Data,
        replyHandler: @escaping (Data) -> Void
    ) {
        let reply = RivetWatchReply(replyHandler)
        guard let router else {
            reply.send(Data())
            return
        }
        do {
            try messagePolicy.validate(messageData)
        } catch {
            reply.send(Data())
            return
        }
        guard incomingBudget.acquire() else {
            reply.send(Data())
            return
        }
        let budget = incomingBudget
        let policy = messagePolicy
        let work = Task {
            defer { budget.release() }
            do {
                let data = try await router.handle(messageData)
                try policy.validate(data)
                reply.send(data)
            } catch {
                reply.send(Data())
            }
        }
        reply.armTimeout(nanoseconds: requestTimeoutNanoseconds) {
            work.cancel()
        }
    }

    #if os(iOS)
    public func sessionDidBecomeInactive(_ session: WCSession) {
        stateContinuation.yield(currentState)
    }

    public func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
        stateContinuation.yield(currentState)
    }
    #endif
}
#endif
