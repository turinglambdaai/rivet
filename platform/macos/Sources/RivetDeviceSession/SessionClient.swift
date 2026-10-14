import Foundation
import RivetDevice

public struct RivetDeviceSessionClientAcceptance: Sendable, Equatable {
    public let sessionID: UUID
    public let deviceID: UUID
    public let scopeNames: [String]
    public let maximumPayload: Int
    public let maximumPending: Int

    public init(
        sessionID: UUID,
        deviceID: UUID,
        scopeNames: [String],
        maximumPayload: Int,
        maximumPending: Int
    ) {
        self.sessionID = sessionID
        self.deviceID = deviceID
        self.scopeNames = scopeNames
        self.maximumPayload = maximumPayload
        self.maximumPending = maximumPending
    }
}

public enum RivetDeviceSessionClientAction: Sendable, Equatable {
    case send(RivetDeviceSessionMessage)
    case showPairingCode(attemptID: UUID, code: String)
    case persistPairing(
        deviceID: UUID,
        credential: Data,
        serverFingerprint: Data
    )
    case accepted(RivetDeviceSessionClientAcceptance)
    case rejected(RivetDeviceSessionRejectCode)
    case close
}

private struct RivetDeviceSessionReconnectClientContext: Sendable {
    let applicationID: String
    let deviceID: UUID
    let credential: Data
    let serverFingerprint: Data
    let clientNonce: Data
}

private struct RivetDeviceSessionPairingClientContext: Sendable {
    let applicationID: String
    let windowID: UUID
    let deviceName: String
    let serverFingerprint: Data
    let clientNonce: Data
    var attemptID: UUID?
}

private enum RivetDeviceSessionClientState: Sendable {
    case reconnectReady(
        context: RivetDeviceSessionReconnectClientContext,
        deadline: Date
    )
    case awaitingAuthChallenge(
        context: RivetDeviceSessionReconnectClientContext,
        deadline: Date
    )
    case awaitingAccept(deviceID: UUID, deadline: Date)
    case pairingReady(
        context: RivetDeviceSessionPairingClientContext,
        deadline: Date
    )
    case awaitingPairChallenge(
        context: RivetDeviceSessionPairingClientContext,
        deadline: Date
    )
    case awaitingPairDecision(
        context: RivetDeviceSessionPairingClientContext,
        deadline: Date
    )
    case awaitingPaired(deadline: Date)
    case awaitingPersistence(acceptance: RivetDeviceSessionClientAcceptance)
    case accepted(RivetDeviceSessionClientAcceptance)
    case closed
}

/// Client-side ordering and credential-persistence gate for the preface. The
/// stream adapter must complete `pairingPersisted()` before handing RVT1 Hello
/// bytes to the ordinary client.
public actor RivetDeviceSessionClient {
    private let serverFingerprint: Data
    private let timeout: TimeInterval
    private let pairingResponseTimeout: TimeInterval
    private var state: RivetDeviceSessionClientState

    public init(
        reconnectApplicationID applicationID: String,
        deviceID: UUID,
        credential: Data,
        serverFingerprint: Data,
        clientNonce: Data,
        timeout: TimeInterval = rivetDeviceSessionPostTLSTimeout,
        startedAt: Date = Date()
    ) throws {
        try Self.validateCommon(
            applicationID: applicationID,
            serverFingerprint: serverFingerprint,
            clientNonce: clientNonce,
            timeout: timeout
        )
        guard credential.count == rivetDeviceCredentialSize else {
            throw RivetDeviceSessionProtocolError.invalidField
        }
        let context = RivetDeviceSessionReconnectClientContext(
            applicationID: applicationID,
            deviceID: deviceID,
            credential: credential,
            serverFingerprint: serverFingerprint,
            clientNonce: clientNonce
        )
        self.serverFingerprint = serverFingerprint
        self.timeout = timeout
        pairingResponseTimeout = rivetDeviceDefaultPairingWindowDuration
        state = .reconnectReady(
            context: context,
            deadline: startedAt.addingTimeInterval(timeout)
        )
    }

    public init(
        pairingApplicationID applicationID: String,
        windowID: UUID,
        deviceName: String,
        serverFingerprint: Data,
        clientNonce: Data,
        timeout: TimeInterval = rivetDeviceSessionPostTLSTimeout,
        pairingResponseTimeout: TimeInterval = rivetDeviceDefaultPairingWindowDuration,
        startedAt: Date = Date()
    ) throws {
        try Self.validateCommon(
            applicationID: applicationID,
            serverFingerprint: serverFingerprint,
            clientNonce: clientNonce,
            timeout: timeout
        )
        guard isValidDeviceDisplayName(deviceName), pairingResponseTimeout > 0 else {
            throw RivetDeviceSessionProtocolError.invalidField
        }
        let context = RivetDeviceSessionPairingClientContext(
            applicationID: applicationID,
            windowID: windowID,
            deviceName: deviceName,
            serverFingerprint: serverFingerprint,
            clientNonce: clientNonce,
            attemptID: nil
        )
        self.serverFingerprint = serverFingerprint
        self.timeout = timeout
        self.pairingResponseTimeout = pairingResponseTimeout
        state = .pairingReady(
            context: context,
            deadline: startedAt.addingTimeInterval(timeout)
        )
    }

    public func start(now: Date = Date()) throws -> [RivetDeviceSessionClientAction] {
        try requireNotExpired(now: now)
        switch state {
        case .reconnectReady(let context, _):
            state = .awaitingAuthChallenge(
                context: context,
                deadline: now.addingTimeInterval(timeout)
            )
            return [.send(.authenticate(
                applicationID: context.applicationID,
                deviceID: context.deviceID,
                clientNonce: context.clientNonce
            ))]
        case .pairingReady(let context, _):
            state = .awaitingPairChallenge(
                context: context,
                deadline: now.addingTimeInterval(timeout)
            )
            return [.send(.pairStart(
                applicationID: context.applicationID,
                windowID: context.windowID,
                deviceName: context.deviceName,
                clientNonce: context.clientNonce
            ))]
        case .closed:
            throw RivetDeviceSessionStateError.sessionClosed
        default:
            throw closeForProtocolViolation()
        }
    }

    public func receive(
        _ message: RivetDeviceSessionMessage,
        now: Date = Date()
    ) throws -> [RivetDeviceSessionClientAction] {
        try requireNotExpired(now: now)
        if case .reject(let code) = message {
            switch state {
            case .awaitingAuthChallenge, .awaitingAccept, .awaitingPairChallenge,
                 .awaitingPairDecision, .awaitingPaired:
                state = .closed
                return [.rejected(code), .close]
            case .reconnectReady, .pairingReady, .awaitingPersistence, .accepted:
                throw closeForProtocolViolation()
            case .closed:
                throw RivetDeviceSessionStateError.sessionClosed
            }
        }

        switch state {
        case .awaitingAuthChallenge(let context, _):
            guard case .authChallenge(let serverNonce) = message else {
                throw closeForProtocolViolation()
            }
            let proof = try RivetDeviceSessionAuthentication.proof(
                credential: context.credential,
                applicationID: context.applicationID,
                serverFingerprint: context.serverFingerprint,
                deviceID: context.deviceID,
                clientNonce: context.clientNonce,
                serverNonce: serverNonce
            )
            state = .awaitingAccept(
                deviceID: context.deviceID,
                deadline: now.addingTimeInterval(timeout)
            )
            return [.send(.authProof(proof))]

        case .awaitingAccept(let deviceID, _):
            guard case .accept(
                let sessionID,
                let scopeNames,
                let maximumPayload,
                let maximumPending
            ) = message else {
                throw closeForProtocolViolation()
            }
            let acceptance = RivetDeviceSessionClientAcceptance(
                sessionID: sessionID,
                deviceID: deviceID,
                scopeNames: scopeNames,
                maximumPayload: maximumPayload,
                maximumPending: maximumPending
            )
            state = .accepted(acceptance)
            return [.accepted(acceptance)]

        case .awaitingPairChallenge(var context, _):
            guard case .pairChallenge(let attemptID, let serverNonce) = message else {
                throw closeForProtocolViolation()
            }
            let code = try RivetDevicePairingTranscript.verificationCode(
                applicationID: context.applicationID,
                serverFingerprint: context.serverFingerprint,
                clientNonce: context.clientNonce,
                serverNonce: serverNonce
            )
            context.attemptID = attemptID
            state = .awaitingPairDecision(
                context: context,
                deadline: now.addingTimeInterval(timeout)
            )
            return [.showPairingCode(attemptID: attemptID, code: code)]

        case .awaitingPaired:
            guard case .paired(
                let deviceID,
                let credential,
                let sessionID,
                let scopeNames,
                let maximumPayload,
                let maximumPending
            ) = message else {
                throw closeForProtocolViolation()
            }
            let acceptance = RivetDeviceSessionClientAcceptance(
                sessionID: sessionID,
                deviceID: deviceID,
                scopeNames: scopeNames,
                maximumPayload: maximumPayload,
                maximumPending: maximumPending
            )
            state = .awaitingPersistence(acceptance: acceptance)
            return [.persistPairing(
                deviceID: deviceID,
                credential: credential,
                serverFingerprint: serverFingerprint
            )]

        case .reconnectReady, .pairingReady, .awaitingPairDecision,
             .awaitingPersistence, .accepted:
            throw closeForProtocolViolation()
        case .closed:
            throw RivetDeviceSessionStateError.sessionClosed
        }
    }

    public func confirmPairing(
        _ confirmed: Bool,
        now: Date = Date()
    ) throws -> [RivetDeviceSessionClientAction] {
        try requireNotExpired(now: now)
        guard case .awaitingPairDecision(let context, _) = state,
              let attemptID = context.attemptID else {
            if case .closed = state {
                throw RivetDeviceSessionStateError.sessionClosed
            }
            throw RivetDeviceSessionStateError.pairingNotActive
        }
        state = .awaitingPaired(
            deadline: now.addingTimeInterval(pairingResponseTimeout)
        )
        return [.send(.pairDecision(attemptID: attemptID, confirmed: confirmed))]
    }

    public func pairingPersisted() throws -> [RivetDeviceSessionClientAction] {
        guard case .awaitingPersistence(let acceptance) = state else {
            if case .closed = state {
                throw RivetDeviceSessionStateError.sessionClosed
            }
            throw RivetDeviceSessionStateError.pairingNotActive
        }
        state = .accepted(acceptance)
        return [.accepted(acceptance)]
    }

    public func pairingPersistenceFailed() throws -> [RivetDeviceSessionClientAction] {
        guard case .awaitingPersistence = state else {
            if case .closed = state {
                throw RivetDeviceSessionStateError.sessionClosed
            }
            throw RivetDeviceSessionStateError.pairingNotActive
        }
        state = .closed
        return [.close]
    }

    public func expire(now: Date = Date()) -> [RivetDeviceSessionClientAction] {
        do {
            try requireNotExpired(now: now)
            return []
        } catch {
            return [.close]
        }
    }

    public func acceptance() -> RivetDeviceSessionClientAcceptance? {
        guard case .accepted(let acceptance) = state else {
            return nil
        }
        return acceptance
    }

    private func requireNotExpired(now: Date) throws {
        let deadline: Date?
        switch state {
        case .reconnectReady(_, let value),
             .awaitingAuthChallenge(_, let value),
             .awaitingAccept(_, let value),
             .pairingReady(_, let value),
             .awaitingPairChallenge(_, let value),
             .awaitingPairDecision(_, let value),
             .awaitingPaired(let value):
            deadline = value
        case .awaitingPersistence, .accepted:
            deadline = nil
        case .closed:
            throw RivetDeviceSessionStateError.sessionClosed
        }
        guard let deadline else {
            return
        }
        guard now < deadline else {
            state = .closed
            throw RivetDeviceSessionStateError.sessionClosed
        }
    }

    private func closeForProtocolViolation() -> RivetDeviceSessionStateError {
        state = .closed
        return .protocolViolation
    }

    private static func validateCommon(
        applicationID: String,
        serverFingerprint: Data,
        clientNonce: Data,
        timeout: TimeInterval
    ) throws {
        guard isValidDeviceAPIName(applicationID),
              serverFingerprint.count == rivetDeviceFingerprintSize,
              clientNonce.count == rivetDevicePairingNonceSize,
              timeout > 0 else {
            throw RivetDeviceSessionProtocolError.invalidField
        }
    }
}
