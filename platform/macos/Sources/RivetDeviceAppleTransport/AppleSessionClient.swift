import Foundation
import Network
import RivetDevice
import RivetDeviceSession

/// The pairing code surfaced to the device user. Confirmation stays explicit:
/// nothing in Rivet approves a pairing on the device's behalf.
public struct RivetDeviceApplePairingCode: Sendable, Equatable {
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

/// What the client attempts against one explicitly selected host endpoint.
/// Discovery results are connection candidates only; the reconnect material
/// comes from product-owned secure storage, never from an advertisement.
public enum RivetDeviceAppleSessionClientIntent: Sendable {
    /// Reconnect with a stored pairing. The stored server fingerprint pins
    /// TLS, and authentication failure never falls back to pairing.
    case reconnect(pairing: RivetDeviceStoredPairing)
    /// Explicit provisional pairing with a freshly selected host. The
    /// observed TLS identity is compared through the pairing transcript and
    /// becomes trusted only after both peers confirm.
    case pair(
        applicationID: String,
        windowID: UUID,
        deviceName: String
    )
}

/// Resolved per-attempt material handed to the injected session-client
/// factory once TLS completes.
public enum RivetDeviceAppleSessionClientMaterials: Sendable {
    case reconnect(pairing: RivetDeviceStoredPairing, clientNonce: Data)
    case pair(
        applicationID: String,
        windowID: UUID,
        deviceName: String,
        observedFingerprint: Data,
        clientNonce: Data
    )
}

public enum RivetDeviceAppleSessionClientError: Error, Sendable, Equatable,
    CustomStringConvertible {
    case invalidConfiguration
    case invalidState
    case rejected(RivetDeviceSessionRejectCode)
    case pairingPersistenceFailed
    case timedOut

    public var description: String {
        switch self {
        case .invalidConfiguration:
            "invalid Rivet Apple session-client configuration"
        case .invalidState:
            "Rivet Apple session client is in the wrong state"
        case .rejected(let code):
            "Rivet device session was rejected: \(code.rawValue)"
        case .pairingPersistenceFailed:
            "the Rivet device pairing credential could not be persisted"
        case .timedOut:
            "Rivet Apple session preface timed out"
        }
    }
}

/// Persists the credential issued by an explicit pairing attempt. The session
/// enters RVT1 only after this succeeds; a failed save must leave no partial
/// trust behind. Loading stored reconnect material stays product-owned.
public protocol RivetDeviceAppleSessionCredentialStore: Sendable {
    func savePairingCredential(
        deviceID: UUID,
        credential: Data,
        serverFingerprint: Data
    ) async throws
}

private enum RivetDeviceAppleSessionClientPhase {
    case idle
    case starting
    case preface
    case waitingForDevice
    case application
    case closed
}

private enum RivetDeviceAppleSessionClientCloseReason {
    case requested
    case server
    case timedOut
    case completed
    case failed
}

/// Drives exactly one explicitly selected Apple transport from TLS setup
/// through the `RVD1` preface. Application bytes are exposed only inside
/// `applicationHandler` after `RivetDeviceSessionClient` has emitted an
/// acceptance, which on the pairing path happens only after the new
/// credential was persisted through the injected secure-storage boundary.
public actor RivetDeviceAppleSessionClient {
    public typealias ClientFactory = @Sendable (
        _ startedAt: Date,
        _ materials: RivetDeviceAppleSessionClientMaterials
    ) throws -> RivetDeviceSessionClient
    public typealias PairingCodeHandler = @Sendable (
        RivetDeviceApplePairingCode
    ) async -> Void
    public typealias ApplicationHandler = @Sendable (
        RivetDeviceSessionClientAcceptance,
        RivetDeviceAppleConnection
    ) async throws -> Void
    package typealias ConnectionFactory = @Sendable (
        _ tls: RivetDeviceAppleClientTLSContext
    ) throws -> RivetDeviceAppleConnection

    private let intent: RivetDeviceAppleSessionClientIntent
    private let credentialStore: any RivetDeviceAppleSessionCredentialStore
    private let postTLSTimeout: TimeInterval
    private let pairingResponseTimeout: TimeInterval
    private let now: @Sendable () -> Date
    private let wait: @Sendable (TimeInterval) async throws -> Void
    private let random: any RivetDeviceRandomBytesGenerator
    private let connectionFactory: ConnectionFactory
    private let clientFactory: ClientFactory
    private let pairingCodeHandler: PairingCodeHandler
    private let applicationHandler: ApplicationHandler

    private var phase = RivetDeviceAppleSessionClientPhase.idle
    private var connection: RivetDeviceAppleConnection?
    private var client: RivetDeviceSessionClient?
    private var nextMessageDeadline: Date?
    private var pairingExpiresAt: Date?
    private var pairingDecisionRequested = false
    private var pairingWaiter: CheckedContinuation<Void, Never>?
    private var pairingDeadlineTask: Task<Void, Never>?
    private var pairingDeadlineToken: UUID?
    private var receiveDeadlineTask: Task<Void, Never>?
    private var receiveDeadlineToken: UUID?
    private var rejection: RivetDeviceSessionRejectCode?
    private var acceptance: RivetDeviceSessionClientAcceptance?
    private var closeReason: RivetDeviceAppleSessionClientCloseReason?
    private var cleanupStarted = false
    private var cleanupFinished = false
    private var cleanupWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        endpoint: NWEndpoint,
        intent: RivetDeviceAppleSessionClientIntent,
        credentialStore: any RivetDeviceAppleSessionCredentialStore,
        postTLSTimeout: TimeInterval = rivetDeviceSessionPostTLSTimeout,
        pairingResponseTimeout: TimeInterval =
            rivetDeviceDefaultPairingWindowDuration,
        clientFactory: @escaping ClientFactory,
        pairingCodeHandler: @escaping PairingCodeHandler,
        applicationHandler: @escaping ApplicationHandler
    ) throws {
        try self.init(
            intent: intent,
            credentialStore: credentialStore,
            postTLSTimeout: postTLSTimeout,
            pairingResponseTimeout: pairingResponseTimeout,
            now: Date.init,
            wait: Self.systemWait,
            random: RivetDeviceSystemRandomBytesGenerator(),
            connectionFactory: { tls in
                try RivetDeviceAppleConnection(endpoint: endpoint, tls: tls)
            },
            clientFactory: clientFactory,
            pairingCodeHandler: pairingCodeHandler,
            applicationHandler: applicationHandler
        )
    }

    package init(
        intent: RivetDeviceAppleSessionClientIntent,
        credentialStore: any RivetDeviceAppleSessionCredentialStore,
        postTLSTimeout: TimeInterval = rivetDeviceSessionPostTLSTimeout,
        pairingResponseTimeout: TimeInterval =
            rivetDeviceDefaultPairingWindowDuration,
        now: @escaping @Sendable () -> Date,
        wait: @escaping @Sendable (TimeInterval) async throws -> Void,
        random: any RivetDeviceRandomBytesGenerator,
        connectionFactory: @escaping ConnectionFactory,
        clientFactory: @escaping ClientFactory,
        pairingCodeHandler: @escaping PairingCodeHandler,
        applicationHandler: @escaping ApplicationHandler
    ) throws {
        guard postTLSTimeout.isFinite, postTLSTimeout > 0,
              pairingResponseTimeout.isFinite, pairingResponseTimeout > 0
        else {
            throw RivetDeviceAppleSessionClientError.invalidConfiguration
        }
        switch intent {
        case .reconnect(let pairing):
            guard
                pairing.device.serverFingerprint.count ==
                    rivetDeviceFingerprintSize,
                pairing.credential.count == rivetDeviceCredentialSize,
                isValidDeviceAPIName(pairing.device.applicationID)
            else {
                throw RivetDeviceAppleSessionClientError.invalidConfiguration
            }
        case .pair(let applicationID, _, let deviceName):
            guard isValidDeviceAPIName(applicationID),
                  isValidDeviceDisplayName(deviceName) else {
                throw RivetDeviceAppleSessionClientError.invalidConfiguration
            }
        }
        self.intent = intent
        self.credentialStore = credentialStore
        self.postTLSTimeout = postTLSTimeout
        self.pairingResponseTimeout = pairingResponseTimeout
        self.now = now
        self.wait = wait
        self.random = random
        self.connectionFactory = connectionFactory
        self.clientFactory = clientFactory
        self.pairingCodeHandler = pairingCodeHandler
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

    /// Records the device user's explicit decision on the surfaced pairing
    /// code. It never bypasses the transcript, the desktop's own confirmation,
    /// or the credential-persistence gate.
    public func confirmPairing(_ confirmed: Bool) async throws {
        guard phase == .preface || phase == .waitingForDevice,
              let client else {
            throw RivetDeviceAppleSessionClientError.invalidState
        }
        let decidedAt = now()
        let actions = try await client.confirmPairing(confirmed, now: decidedAt)
        pairingDecisionRequested = true
        if confirmed {
            // The desktop user may take until the pairing window to approve;
            // the state machine uses the same bound for awaitingPaired.
            let deadline = decidedAt.addingTimeInterval(pairingResponseTimeout)
            pairingExpiresAt = deadline
            nextMessageDeadline = deadline
        }
        try await execute(actions, closeReason: .server)
        resumePairingWait()
    }

    public func cancel() async {
        await cleanup(reason: .requested)
    }

    private func runSession() async throws {
        guard phase == .idle else {
            throw RivetDeviceAppleSessionClientError.invalidState
        }
        phase = .starting
        do {
            let tlsContext: RivetDeviceAppleClientTLSContext
            switch intent {
            case .reconnect(let pairing):
                tlsContext = try RivetDeviceAppleClientTLSContext(
                    authentication: .pinned(pairing.device.serverFingerprint)
                )
            case .pair:
                tlsContext = try RivetDeviceAppleClientTLSContext(
                    authentication: .provisionalPairing
                )
            }
            let connection = try connectionFactory(tlsContext)
            self.connection = connection
            let observation = try await connection.start()
            guard phase == .starting else {
                await cleanup(reason: closeReason ?? .requested)
                return
            }
            let startedAt = now()
            let clientNonce = try await random.randomBytes(
                count: rivetDevicePairingNonceSize
            )
            let materials: RivetDeviceAppleSessionClientMaterials
            switch intent {
            case .reconnect(let pairing):
                // The TLS verifier already rejects a foreign certificate;
                // this mirror check fails closed on a missing observation.
                guard let observed = observation.serverFingerprint,
                      observed == pairing.device.serverFingerprint else {
                    throw RivetDeviceAppleTransportError.serverPinMismatch
                }
                materials = .reconnect(pairing: pairing, clientNonce: clientNonce)
            case .pair(let applicationID, let windowID, let deviceName):
                guard let observed = observation.serverFingerprint else {
                    throw RivetDeviceAppleTransportError.certificateUnavailable
                }
                materials = .pair(
                    applicationID: applicationID,
                    windowID: windowID,
                    deviceName: deviceName,
                    observedFingerprint: observed,
                    clientNonce: clientNonce
                )
            }
            let client = try clientFactory(startedAt, materials)
            self.client = client
            nextMessageDeadline = startedAt.addingTimeInterval(postTLSTimeout)
            phase = .preface
            scheduleReceiveDeadline()
            try await execute(
                try await client.start(now: startedAt),
                closeReason: .server
            )

            while phase == .preface {
                let message = try await receiveSessionMessage()
                guard phase == .preface else {
                    if closeReason == .timedOut {
                        throw RivetDeviceAppleSessionClientError.timedOut
                    }
                    throw RivetDeviceAppleSessionClientError.invalidState
                }
                let receivedAt = now()
                nextMessageDeadline = receivedAt.addingTimeInterval(
                    postTLSTimeout
                )
                scheduleReceiveDeadline()
                let actions = try await client.receive(message, now: receivedAt)
                try await execute(actions, closeReason: .server)
                if acceptance != nil {
                    cancelReceiveDeadline()
                    break
                }
                if case .pairChallenge = message {
                    cancelReceiveDeadline()
                    try await waitForDevicePairingDecision()
                }
            }

            if let rejection {
                await cleanup(reason: closeReason ?? .server)
                throw RivetDeviceAppleSessionClientError.rejected(rejection)
            }
            guard let acceptance else {
                await cleanup(reason: closeReason ?? .server)
                return
            }
            guard phase == .preface || phase == .waitingForDevice else {
                throw RivetDeviceAppleSessionClientError.invalidState
            }
            try await connection.beginApplicationProtocol()
            phase = .application
            try await applicationHandler(acceptance, connection)
            await cleanup(reason: .completed)
        } catch {
            let reason = closeReason
            await cleanup(reason: reason ?? .failed)
            if let rejection {
                throw RivetDeviceAppleSessionClientError.rejected(rejection)
            }
            switch reason {
            case .requested, .server, .completed:
                return
            case .timedOut:
                throw RivetDeviceAppleSessionClientError.timedOut
            case .failed, nil:
                throw error
            }
        }
    }

    private func receiveSessionMessage() async throws
        -> RivetDeviceSessionMessage {
        guard let connection else {
            throw RivetDeviceAppleSessionClientError.invalidState
        }
        let message = try await connection.receiveSessionMessage()
        guard phase == .preface else {
            if closeReason == .timedOut {
                throw RivetDeviceAppleSessionClientError.timedOut
            }
            throw RivetDeviceAppleSessionClientError.invalidState
        }
        return message
    }

    private func waitForDevicePairingDecision() async throws {
        guard phase == .preface,
              let expiresAt = pairingExpiresAt,
              var deadline = nextMessageDeadline else {
            throw RivetDeviceAppleSessionClientError.invalidState
        }
        if expiresAt < deadline {
            deadline = expiresAt
        }
        phase = .waitingForDevice
        if pairingDecisionRequested {
            phase = .preface
            scheduleReceiveDeadline()
            return
        }
        let token = UUID()
        let delay = max(0, deadline.timeIntervalSince(now()))
        pairingDeadlineToken = token
        let wait = self.wait
        pairingDeadlineTask = Task { [weak self] in
            do {
                try await wait(delay)
            } catch {
                return
            }
            await self?.pairingDeadlineReached(token: token, deadline: deadline)
        }
        await withCheckedContinuation { continuation in
            pairingWaiter = continuation
        }
        pairingDeadlineTask?.cancel()
        pairingDeadlineTask = nil
        pairingDeadlineToken = nil
        if closeReason == .timedOut {
            throw RivetDeviceAppleSessionClientError.timedOut
        }
        if phase == .waitingForDevice {
            phase = .preface
            scheduleReceiveDeadline()
        }
    }

    private func pairingDeadlineReached(token: UUID, deadline: Date) async {
        guard pairingDeadlineToken == token,
              phase == .waitingForDevice,
              let client else {
            return
        }
        pairingDeadlineToken = nil
        closeReason = .timedOut
        let actions = await client.expire(now: deadline)
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
              let client else {
            return
        }
        receiveDeadlineToken = nil
        closeReason = .timedOut
        let actions = await client.expire(now: deadline)
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

    private func execute(
        _ actions: [RivetDeviceSessionClientAction],
        closeReason requestedCloseReason: RivetDeviceAppleSessionClientCloseReason
    ) async throws {
        for action in actions where phase != .closed {
            switch action {
            case .send(let message):
                guard let connection else {
                    throw RivetDeviceAppleSessionClientError.invalidState
                }
                do {
                    try await connection.sendSessionMessage(message)
                } catch {
                    await cleanup(reason: .failed)
                    throw error
                }
            case .showPairingCode(let attemptID, let code):
                if pairingExpiresAt == nil {
                    pairingExpiresAt = now().addingTimeInterval(
                        pairingResponseTimeout
                    )
                }
                await pairingCodeHandler(RivetDeviceApplePairingCode(
                    attemptID: attemptID,
                    verificationCode: code,
                    expiresAt: pairingExpiresAt ?? now()
                ))
            case .persistPairing(let deviceID, let credential,
                                  let serverFingerprint):
                try await persistPairingCredential(
                    deviceID: deviceID,
                    credential: credential,
                    serverFingerprint: serverFingerprint
                )
            case .accepted(let value):
                acceptance = value
            case .rejected(let code):
                rejection = code
            case .close:
                await cleanup(reason: requestedCloseReason)
            }
        }
    }

    /// The credential-persistence gate: RVT1 is accepted only after the new
    /// credential reached secure storage. A failed save closes the session
    /// without an acceptance and never retries on a fallback path.
    private func persistPairingCredential(
        deviceID: UUID,
        credential: Data,
        serverFingerprint: Data
    ) async throws {
        guard let client else {
            throw RivetDeviceAppleSessionClientError.invalidState
        }
        do {
            try await credentialStore.savePairingCredential(
                deviceID: deviceID,
                credential: credential,
                serverFingerprint: serverFingerprint
            )
        } catch {
            _ = try? await client.pairingPersistenceFailed()
            await cleanup(reason: .failed)
            throw RivetDeviceAppleSessionClientError.pairingPersistenceFailed
        }
        try await execute(
            try await client.pairingPersisted(),
            closeReason: .server
        )
    }

    private func resumePairingWait() {
        let continuation = pairingWaiter
        pairingWaiter = nil
        continuation?.resume()
    }

    private func cleanup(
        reason requestedReason: RivetDeviceAppleSessionClientCloseReason
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
        await connection?.cancel()
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
