#if os(macOS)
import Foundation
import RivetDeviceSession

public struct RivetDeviceApplePairingPrompt: Sendable, Equatable {
    public let attemptID: UUID
    public let verificationCode: String
    public let expiresAt: Date

    public init(
        attemptID: UUID,
        verificationCode: String,
        expiresAt: Date
    ) {
        self.attemptID = attemptID
        self.verificationCode = verificationCode
        self.expiresAt = expiresAt
    }
}

public enum RivetDeviceAppleSessionHostError: Error, Sendable, Equatable,
    CustomStringConvertible {
    case invalidConfiguration
    case invalidState
    case timedOut

    public var description: String {
        switch self {
        case .invalidConfiguration:
            "invalid Rivet Apple session-host configuration"
        case .invalidState:
            "Rivet Apple session host is in the wrong state"
        case .timedOut:
            "Rivet Apple session preface timed out"
        }
    }
}

private enum RivetDeviceAppleSessionHostPhase {
    case idle
    case starting
    case preface
    case waitingForDesktop
    case application
    case closed
}

private enum RivetDeviceAppleSessionHostCloseReason {
    case requested
    case server
    case timedOut
    case completed
    case failed
}

/// Owns exactly one accepted Apple transport from TLS setup through the RVD1
/// preface. Application bytes are exposed only inside `applicationHandler`
/// after `RivetDeviceSessionServer` has emitted an acceptance.
public actor RivetDeviceAppleSessionHost {
    public typealias ServerFactory = @Sendable (
        _ startedAt: Date
    ) throws -> RivetDeviceSessionServer
    public typealias PairingPromptHandler = @Sendable (
        RivetDeviceApplePairingPrompt
    ) async -> Void
    public typealias ApplicationHandler = @Sendable (
        RivetDeviceSessionAcceptance,
        RivetDeviceAppleConnection
    ) async throws -> Void

    private let connection: RivetDeviceAppleConnection
    private let serverFactory: ServerFactory
    private let postTLSTimeout: TimeInterval
    private let now: @Sendable () -> Date
    private let wait: @Sendable (TimeInterval) async throws -> Void
    private let pairingPromptHandler: PairingPromptHandler
    private let applicationHandler: ApplicationHandler

    private var phase = RivetDeviceAppleSessionHostPhase.idle
    private var server: RivetDeviceSessionServer?
    private var acceptance: RivetDeviceSessionAcceptance?
    private var nextMessageDeadline: Date?
    private var pairingExpiresAt: Date?
    private var pairingWaiter: CheckedContinuation<Void, Never>?
    private var pairingDeadlineTask: Task<Void, Never>?
    private var pairingDeadlineToken: UUID?
    private var receiveDeadlineTask: Task<Void, Never>?
    private var receiveDeadlineToken: UUID?
    private var closeReason: RivetDeviceAppleSessionHostCloseReason?
    private var cleanupStarted = false
    private var cleanupFinished = false
    private var cleanupWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        connection: RivetDeviceAppleConnection,
        postTLSTimeout: TimeInterval = rivetDeviceSessionPostTLSTimeout,
        serverFactory: @escaping ServerFactory,
        pairingPromptHandler: @escaping PairingPromptHandler,
        applicationHandler: @escaping ApplicationHandler
    ) throws {
        try self.init(
            connection: connection,
            postTLSTimeout: postTLSTimeout,
            now: Date.init,
            wait: Self.systemWait,
            serverFactory: serverFactory,
            pairingPromptHandler: pairingPromptHandler,
            applicationHandler: applicationHandler
        )
    }

    package init(
        connection: RivetDeviceAppleConnection,
        postTLSTimeout: TimeInterval = rivetDeviceSessionPostTLSTimeout,
        now: @escaping @Sendable () -> Date,
        wait: @escaping @Sendable (TimeInterval) async throws -> Void,
        serverFactory: @escaping ServerFactory,
        pairingPromptHandler: @escaping PairingPromptHandler,
        applicationHandler: @escaping ApplicationHandler
    ) throws {
        guard postTLSTimeout.isFinite, postTLSTimeout > 0 else {
            throw RivetDeviceAppleSessionHostError.invalidConfiguration
        }
        self.connection = connection
        self.postTLSTimeout = postTLSTimeout
        self.now = now
        self.wait = wait
        self.serverFactory = serverFactory
        self.pairingPromptHandler = pairingPromptHandler
        self.applicationHandler = applicationHandler
    }

    /// Runs the preface and, after acceptance, lends the authenticated stream
    /// to the application handler. Returning or throwing closes the stream.
    public func run() async throws {
        try await withTaskCancellationHandler {
            try await runSession()
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    private func runSession() async throws {
        guard phase == .idle else {
            throw RivetDeviceAppleSessionHostError.invalidState
        }
        phase = .starting
        do {
            _ = try await connection.start()
            guard phase == .starting else {
                await cleanup(reason: closeReason ?? .requested)
                return
            }
            let startedAt = now()
            server = try serverFactory(startedAt)
            nextMessageDeadline = startedAt.addingTimeInterval(postTLSTimeout)
            phase = .preface
            scheduleReceiveDeadline()

            while phase == .preface {
                let message = try await receiveSessionMessage()
                guard phase == .preface, let server else {
                    throw RivetDeviceAppleSessionHostError.invalidState
                }
                let receivedAt = now()
                nextMessageDeadline = receivedAt.addingTimeInterval(
                    postTLSTimeout
                )
                scheduleReceiveDeadline()
                let actions = try await server.receive(message, now: receivedAt)
                try await execute(actions, closeReason: .server)
                if acceptance != nil {
                    cancelReceiveDeadline()
                    break
                }
                if case .pairDecision = message, actions.isEmpty {
                    cancelReceiveDeadline()
                    try await waitForDesktopPairingDecision()
                }
            }

            guard let acceptance else {
                await cleanup(reason: closeReason ?? .server)
                return
            }
            guard phase == .preface || phase == .waitingForDesktop else {
                throw RivetDeviceAppleSessionHostError.invalidState
            }
            try await connection.beginApplicationProtocol()
            phase = .application
            try await applicationHandler(acceptance, connection)
            await cleanup(reason: .completed)
        } catch {
            let reason = closeReason
            await cleanup(reason: reason ?? .failed)
            switch reason {
            case .requested, .server, .completed:
                return
            case .timedOut:
                throw RivetDeviceAppleSessionHostError.timedOut
            case .failed, nil:
                throw error
            }
        }
    }

    /// Records the desktop user's explicit approval. It never approves the
    /// device side and never bypasses the session server's scope validation.
    public func confirmPairing(grantedScopeNames: [String]) async throws {
        guard phase == .preface || phase == .waitingForDesktop,
              let server else {
            throw RivetDeviceAppleSessionHostError.invalidState
        }
        let actions = try await server.confirmPairingOnDesktop(
            grantedScopeNames: grantedScopeNames,
            now: now()
        )
        try await execute(actions, closeReason: .server)
        resumePairingWaitIfResolved()
    }

    public func rejectPairing() async throws {
        guard phase == .preface || phase == .waitingForDesktop,
              let server else {
            throw RivetDeviceAppleSessionHostError.invalidState
        }
        let actions = try await server.rejectPairingOnDesktop(now: now())
        try await execute(actions, closeReason: .server)
        resumePairingWaitIfResolved()
    }

    public func cancel() async {
        await cleanup(reason: .requested)
    }

    private func receiveSessionMessage() async throws
        -> RivetDeviceSessionMessage {
        let message = try await connection.receiveSessionMessage()
        guard phase == .preface else {
            if closeReason == .timedOut {
                throw RivetDeviceAppleSessionHostError.timedOut
            }
            throw RivetDeviceAppleSessionHostError.invalidState
        }
        return message
    }

    private func scheduleReceiveDeadline() {
        guard phase == .preface,
              var deadline = nextMessageDeadline else {
            return
        }
        if let pairingExpiresAt, pairingExpiresAt < deadline {
            deadline = pairingExpiresAt
        }
        receiveDeadlineTask?.cancel()
        let token = UUID()
        let delay = max(0, deadline.timeIntervalSince(now()))
        receiveDeadlineToken = token
        let wait = self.wait
        receiveDeadlineTask = Task { [weak self] in
            do {
                try await wait(delay)
            } catch {
                return
            }
            await self?.receiveDeadlineReached(token: token, deadline: deadline)
        }
    }

    private func cancelReceiveDeadline() {
        receiveDeadlineTask?.cancel()
        receiveDeadlineTask = nil
        receiveDeadlineToken = nil
    }

    private func receiveDeadlineReached(token: UUID, deadline: Date) async {
        guard receiveDeadlineToken == token,
              phase == .preface,
              let server else {
            return
        }
        receiveDeadlineToken = nil
        closeReason = .timedOut
        let actions = await server.expire(now: deadline)
        if actions.isEmpty {
            await cleanup(reason: .timedOut)
        } else {
            do {
                try await execute(actions, closeReason: .timedOut)
            } catch {
                await cleanup(reason: .timedOut)
            }
        }
    }

    private func waitForDesktopPairingDecision() async throws {
        guard phase == .preface,
              let expiresAt = pairingExpiresAt else {
            throw RivetDeviceAppleSessionHostError.invalidState
        }
        phase = .waitingForDesktop
        let token = UUID()
        let delay = max(0, expiresAt.timeIntervalSince(now()))
        pairingDeadlineToken = token
        let wait = self.wait
        pairingDeadlineTask = Task { [weak self] in
            do {
                try await wait(delay)
            } catch {
                return
            }
            await self?.pairingDeadlineReached(
                token: token,
                deadline: expiresAt
            )
        }
        await withCheckedContinuation { continuation in
            pairingWaiter = continuation
        }
        pairingDeadlineTask?.cancel()
        pairingDeadlineTask = nil
        pairingDeadlineToken = nil
        if closeReason == .timedOut {
            throw RivetDeviceAppleSessionHostError.timedOut
        }
    }

    private func pairingDeadlineReached(token: UUID, deadline: Date) async {
        guard pairingDeadlineToken == token,
              phase == .waitingForDesktop,
              let server else {
            return
        }
        pairingDeadlineToken = nil
        closeReason = .timedOut
        let actions = await server.expire(now: deadline)
        if actions.isEmpty {
            await cleanup(reason: .timedOut)
        } else {
            do {
                try await execute(actions, closeReason: .timedOut)
            } catch {
                await cleanup(reason: .timedOut)
            }
        }
        resumePairingWait()
    }

    private func execute(
        _ actions: [RivetDeviceSessionServerAction],
        closeReason requestedCloseReason: RivetDeviceAppleSessionHostCloseReason
    ) async throws {
        for action in actions where phase != .closed {
            switch action {
            case .send(let message):
                do {
                    try await connection.sendSessionMessage(message)
                } catch {
                    await cleanup(reason: .failed)
                    throw error
                }
            case .showPairingCode(let attemptID, let code, let expiresAt):
                pairingExpiresAt = expiresAt
                scheduleReceiveDeadline()
                await pairingPromptHandler(RivetDeviceApplePairingPrompt(
                    attemptID: attemptID,
                    verificationCode: code,
                    expiresAt: expiresAt
                ))
            case .accepted(let value):
                acceptance = value
            case .close:
                await cleanup(reason: requestedCloseReason)
            }
        }
    }

    private func resumePairingWaitIfResolved() {
        guard acceptance != nil || phase == .closed else {
            return
        }
        resumePairingWait()
    }

    private func resumePairingWait() {
        let continuation = pairingWaiter
        pairingWaiter = nil
        continuation?.resume()
    }

    private func cleanup(
        reason requestedReason: RivetDeviceAppleSessionHostCloseReason
    ) async {
        if cleanupFinished {
            return
        }
        if cleanupStarted {
            await withCheckedContinuation { continuation in
                cleanupWaiters.append(continuation)
            }
            return
        }
        cleanupStarted = true
        closeReason = closeReason ?? requestedReason
        phase = .closed
        receiveDeadlineTask?.cancel()
        receiveDeadlineTask = nil
        receiveDeadlineToken = nil
        pairingDeadlineTask?.cancel()
        pairingDeadlineTask = nil
        pairingDeadlineToken = nil
        await connection.cancel()
        if let server {
            await server.disconnect(now: now())
        }
        cleanupFinished = true
        resumePairingWait()
        let waiters = cleanupWaiters
        cleanupWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private static func systemWait(_ interval: TimeInterval) async throws {
        guard interval > 0 else {
            return
        }
        try await Task.sleep(for: .seconds(interval))
    }
}
#endif
