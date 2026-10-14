import Foundation
import RivetDevice

public let rivetDeviceSessionPostTLSTimeout: TimeInterval = 10

public protocol RivetDeviceSessionUUIDGenerator: Sendable {
    func nextUUID() -> UUID
}

public struct RivetDeviceSessionSystemUUIDGenerator: RivetDeviceSessionUUIDGenerator {
    public init() {}

    public func nextUUID() -> UUID {
        UUID()
    }
}

public struct RivetDeviceSessionAcceptance: Sendable, Equatable {
    public let sessionID: UUID
    public let deviceID: UUID
    public let applicationID: String
    public let scopeNames: [String]
    public let maximumPayload: Int
    public let maximumPending: Int

    public init(
        sessionID: UUID,
        deviceID: UUID,
        applicationID: String,
        scopeNames: [String],
        maximumPayload: Int,
        maximumPending: Int
    ) {
        self.sessionID = sessionID
        self.deviceID = deviceID
        self.applicationID = applicationID
        self.scopeNames = scopeNames
        self.maximumPayload = maximumPayload
        self.maximumPending = maximumPending
    }
}

public enum RivetDeviceSessionServerAction: Sendable, Equatable {
    case send(RivetDeviceSessionMessage)
    case showPairingCode(attemptID: UUID, code: String, expiresAt: Date)
    case accepted(RivetDeviceSessionAcceptance)
    case close
}

public enum RivetDeviceSessionStateError: Error, Sendable, Equatable,
    CustomStringConvertible {
    case protocolViolation
    case sessionClosed
    case pairingNotActive

    public var description: String {
        switch self {
        case .protocolViolation:
            "invalid Rivet device-session message order"
        case .sessionClosed:
            "Rivet device session is closed"
        case .pairingNotActive:
            "Rivet device pairing is not awaiting desktop action"
        }
    }
}

private struct RivetDeviceSessionAuthenticationContext: Sendable {
    let applicationID: String
    let deviceID: UUID
    let clientNonce: Data
    let serverNonce: Data
    let credential: Data
    let candidate: RivetDeviceStoredPairing?
}

private struct RivetDeviceSessionPairingContext: Sendable {
    let windowID: UUID
    let attemptID: UUID
    let expiresAt: Date
}

private enum RivetDeviceSessionServerState: Sendable {
    case awaitingStart(deadline: Date)
    case awaitingAuthProof(
        context: RivetDeviceSessionAuthenticationContext,
        deadline: Date
    )
    case awaitingPairDecision(
        context: RivetDeviceSessionPairingContext,
        deadline: Date
    )
    case awaitingDesktopConfirmation(context: RivetDeviceSessionPairingContext)
    case accepted(RivetDeviceSessionAcceptance)
    case closed
}

/// Pure session-preface policy. A future stream adapter feeds decoded records
/// into this actor and executes its send/close/UI actions.
public actor RivetDeviceSessionServer {
    private let applicationID: String
    private let serverFingerprint: Data
    private let store: any RivetDevicePairingStore
    private let pairingCoordinator: RivetDevicePairingCoordinator
    private let random: any RivetDeviceRandomBytesGenerator
    private let uuidGenerator: any RivetDeviceSessionUUIDGenerator
    private let maximumPayload: Int
    private let maximumPending: Int
    private let postTLSTimeout: TimeInterval
    private var state: RivetDeviceSessionServerState

    public init(
        applicationID: String,
        serverFingerprint: Data,
        store: any RivetDevicePairingStore,
        pairingCoordinator: RivetDevicePairingCoordinator,
        random: any RivetDeviceRandomBytesGenerator = RivetDeviceSystemRandomBytesGenerator(),
        uuidGenerator: any RivetDeviceSessionUUIDGenerator =
            RivetDeviceSessionSystemUUIDGenerator(),
        maximumPayload: Int = rivetDeviceDefaultMaximumMessageSize,
        maximumPending: Int = rivetDeviceDefaultMaximumPendingRequests,
        postTLSTimeout: TimeInterval = rivetDeviceSessionPostTLSTimeout,
        startedAt: Date = Date()
    ) throws {
        guard isValidDeviceAPIName(applicationID),
              serverFingerprint.count == rivetDeviceFingerprintSize,
              maximumPayload > 0,
              maximumPayload <= rivetDeviceDefaultMaximumMessageSize,
              maximumPending > 0,
              maximumPending <= rivetDeviceDefaultMaximumPendingRequests,
              postTLSTimeout > 0 else {
            throw RivetDeviceSessionProtocolError.invalidField
        }
        self.applicationID = applicationID
        self.serverFingerprint = serverFingerprint
        self.store = store
        self.pairingCoordinator = pairingCoordinator
        self.random = random
        self.uuidGenerator = uuidGenerator
        self.maximumPayload = maximumPayload
        self.maximumPending = maximumPending
        self.postTLSTimeout = postTLSTimeout
        state = .awaitingStart(deadline: startedAt.addingTimeInterval(postTLSTimeout))
    }

    public func receive(
        _ message: RivetDeviceSessionMessage,
        now: Date = Date()
    ) async throws -> [RivetDeviceSessionServerAction] {
        let timeoutActions = await expireIfNeeded(now: now)
        if !timeoutActions.isEmpty {
            return timeoutActions
        }

        switch state {
        case .awaitingStart:
            switch message {
            case .authenticate(let requestedApplicationID, let deviceID, let clientNonce):
                return await beginAuthentication(
                    requestedApplicationID: requestedApplicationID,
                    deviceID: deviceID,
                    clientNonce: clientNonce,
                    now: now
                )
            case .pairStart(
                let requestedApplicationID,
                let windowID,
                let deviceName,
                let clientNonce
            ):
                return await beginPairing(
                    requestedApplicationID: requestedApplicationID,
                    windowID: windowID,
                    deviceName: deviceName,
                    clientNonce: clientNonce,
                    now: now
                )
            default:
                throw closeForProtocolViolation()
            }

        case .awaitingAuthProof(let context, _):
            guard case .authProof(let proof) = message else {
                throw closeForProtocolViolation()
            }
            return await finishAuthentication(context: context, proof: proof, now: now)

        case .awaitingPairDecision(let context, _):
            guard case .pairDecision(let attemptID, let confirmed) = message else {
                throw closeForProtocolViolation()
            }
            return await handlePairDecision(
                context: context,
                receivedAttemptID: attemptID,
                confirmed: confirmed,
                now: now
            )

        case .awaitingDesktopConfirmation:
            throw closeForProtocolViolation()
        case .accepted:
            throw closeForProtocolViolation()
        case .closed:
            throw RivetDeviceSessionStateError.sessionClosed
        }
    }

    public func confirmPairingOnDesktop(
        grantedScopeNames: [String],
        now: Date = Date()
    ) async throws -> [RivetDeviceSessionServerAction] {
        let timeoutActions = await expireIfNeeded(now: now)
        if !timeoutActions.isEmpty {
            return timeoutActions
        }
        let context: RivetDeviceSessionPairingContext
        switch state {
        case .awaitingPairDecision(let active, _),
             .awaitingDesktopConfirmation(let active):
            context = active
        case .closed:
            throw RivetDeviceSessionStateError.sessionClosed
        default:
            throw RivetDeviceSessionStateError.pairingNotActive
        }
        let canonicalScopes = canonicalScopeNames(grantedScopeNames)
        guard validScopeNames(canonicalScopes) else {
            try? await pairingCoordinator.failAttempt(
                windowID: context.windowID,
                attemptID: context.attemptID,
                now: now
            )
            return closeWithReject(.pairingRejected)
        }
        do {
            let result = try await pairingCoordinator.confirmOnDesktop(
                windowID: context.windowID,
                attemptID: context.attemptID,
                grantedScopeNames: canonicalScopes,
                now: now
            )
            guard let result else {
                return []
            }
            return finishPairing(result)
        } catch {
            try? await pairingCoordinator.abandonAttempt(
                windowID: context.windowID,
                attemptID: context.attemptID,
                now: now
            )
            return closeWithReject(pairingRejectCode(for: error))
        }
    }

    public func rejectPairingOnDesktop(
        now: Date = Date()
    ) async throws -> [RivetDeviceSessionServerAction] {
        let context = try activePairingContext()
        do {
            try await pairingCoordinator.failAttempt(
                windowID: context.windowID,
                attemptID: context.attemptID,
                now: now
            )
        } catch {
            return closeWithReject(pairingRejectCode(for: error))
        }
        return closeWithReject(.pairingRejected)
    }

    public func expire(now: Date = Date()) async -> [RivetDeviceSessionServerAction] {
        await expireIfNeeded(now: now)
    }

    public func disconnect(now: Date = Date()) async {
        switch state {
        case .awaitingPairDecision(let context, _),
             .awaitingDesktopConfirmation(let context):
            try? await pairingCoordinator.abandonAttempt(
                windowID: context.windowID,
                attemptID: context.attemptID,
                now: now
            )
        default:
            break
        }
        state = .closed
    }

    public func acceptance() -> RivetDeviceSessionAcceptance? {
        guard case .accepted(let acceptance) = state else {
            return nil
        }
        return acceptance
    }

    private func beginAuthentication(
        requestedApplicationID: String,
        deviceID: UUID,
        clientNonce: Data,
        now: Date
    ) async -> [RivetDeviceSessionServerAction] {
        let serverNonce: Data
        let dummyCredential: Data
        do {
            serverNonce = try await random.randomBytes(count: rivetDevicePairingNonceSize)
            dummyCredential = try await random.randomBytes(count: rivetDeviceCredentialSize)
        } catch {
            return closeWithReject(.internalError)
        }
        guard serverNonce.count == rivetDevicePairingNonceSize,
              dummyCredential.count == rivetDeviceCredentialSize else {
            return closeWithReject(.internalError)
        }

        let loaded = try? await store.load(deviceID: deviceID)
        let candidate = loaded.flatMap { pairing -> RivetDeviceStoredPairing? in
            guard pairing.device.id == deviceID,
                  pairing.device.applicationID == requestedApplicationID,
                  requestedApplicationID == applicationID,
                  constantTimeEqual(pairing.device.serverFingerprint, serverFingerprint),
                  pairing.device.serverFingerprint.count == rivetDeviceFingerprintSize,
                  pairing.credential.count == rivetDeviceCredentialSize,
                  validScopeNames(pairing.device.scopeNames) else {
                return nil
            }
            return pairing
        }
        let context = RivetDeviceSessionAuthenticationContext(
            applicationID: requestedApplicationID,
            deviceID: deviceID,
            clientNonce: clientNonce,
            serverNonce: serverNonce,
            credential: candidate?.credential ?? dummyCredential,
            candidate: candidate
        )
        state = .awaitingAuthProof(
            context: context,
            deadline: now.addingTimeInterval(postTLSTimeout)
        )
        return [.send(.authChallenge(serverNonce: serverNonce))]
    }

    private func finishAuthentication(
        context: RivetDeviceSessionAuthenticationContext,
        proof: Data,
        now: Date
    ) async -> [RivetDeviceSessionServerAction] {
        let expectedProof: Data
        do {
            expectedProof = try RivetDeviceSessionAuthentication.proof(
                credential: context.credential,
                applicationID: context.applicationID,
                serverFingerprint: serverFingerprint,
                deviceID: context.deviceID,
                clientNonce: context.clientNonce,
                serverNonce: context.serverNonce
            )
        } catch {
            return closeWithReject(.authenticationFailed)
        }
        guard constantTimeEqual(expectedProof, proof),
              let pairing = context.candidate else {
            return closeWithReject(.authenticationFailed)
        }

        let updatedDevice = RivetDevicePairedDevice(
            id: pairing.device.id,
            applicationID: pairing.device.applicationID,
            name: pairing.device.name,
            scopeNames: pairing.device.scopeNames,
            serverFingerprint: pairing.device.serverFingerprint,
            createdAt: pairing.device.createdAt,
            lastUsedAt: max(now, pairing.device.lastUsedAt)
        )
        do {
            try await store.save(RivetDeviceStoredPairing(
                device: updatedDevice,
                credential: pairing.credential
            ))
        } catch {
            return closeWithReject(.internalError)
        }

        let acceptance = makeAcceptance(device: updatedDevice)
        state = .accepted(acceptance)
        return [
            .send(.accept(
                sessionID: acceptance.sessionID,
                scopeNames: acceptance.scopeNames,
                maximumPayload: acceptance.maximumPayload,
                maximumPending: acceptance.maximumPending
            )),
            .accepted(acceptance)
        ]
    }

    private func beginPairing(
        requestedApplicationID: String,
        windowID: UUID,
        deviceName: String,
        clientNonce: Data,
        now: Date
    ) async -> [RivetDeviceSessionServerAction] {
        guard requestedApplicationID == applicationID else {
            return closeWithReject(.pairingUnavailable)
        }
        do {
            let challenge = try await pairingCoordinator.beginAttempt(
                windowID: windowID,
                deviceName: deviceName,
                clientNonce: clientNonce,
                now: now
            )
            let context = RivetDeviceSessionPairingContext(
                windowID: windowID,
                attemptID: challenge.attemptID,
                expiresAt: challenge.expiresAt
            )
            state = .awaitingPairDecision(
                context: context,
                deadline: now.addingTimeInterval(postTLSTimeout)
            )
            return [
                .send(.pairChallenge(
                    attemptID: challenge.attemptID,
                    serverNonce: challenge.serverNonce
                )),
                .showPairingCode(
                    attemptID: challenge.attemptID,
                    code: challenge.verificationCode,
                    expiresAt: challenge.expiresAt
                )
            ]
        } catch {
            return closeWithReject(pairingRejectCode(for: error))
        }
    }

    private func handlePairDecision(
        context: RivetDeviceSessionPairingContext,
        receivedAttemptID: UUID,
        confirmed: Bool,
        now: Date
    ) async -> [RivetDeviceSessionServerAction] {
        guard receivedAttemptID == context.attemptID, confirmed else {
            try? await pairingCoordinator.failAttempt(
                windowID: context.windowID,
                attemptID: context.attemptID,
                now: now
            )
            return closeWithReject(.pairingRejected)
        }
        do {
            let result = try await pairingCoordinator.confirmOnDevice(
                windowID: context.windowID,
                attemptID: context.attemptID,
                now: now
            )
            guard let result else {
                state = .awaitingDesktopConfirmation(context: context)
                return []
            }
            return finishPairing(result)
        } catch {
            try? await pairingCoordinator.abandonAttempt(
                windowID: context.windowID,
                attemptID: context.attemptID,
                now: now
            )
            return closeWithReject(pairingRejectCode(for: error))
        }
    }

    private func finishPairing(
        _ result: RivetDevicePairingResult
    ) -> [RivetDeviceSessionServerAction] {
        let acceptance = makeAcceptance(device: result.device)
        state = .accepted(acceptance)
        return [
            .send(.paired(
                deviceID: result.device.id,
                credential: result.credential,
                sessionID: acceptance.sessionID,
                scopeNames: acceptance.scopeNames,
                maximumPayload: acceptance.maximumPayload,
                maximumPending: acceptance.maximumPending
            )),
            .accepted(acceptance)
        ]
    }

    private func makeAcceptance(
        device: RivetDevicePairedDevice
    ) -> RivetDeviceSessionAcceptance {
        RivetDeviceSessionAcceptance(
            sessionID: uuidGenerator.nextUUID(),
            deviceID: device.id,
            applicationID: device.applicationID,
            scopeNames: canonicalScopeNames(device.scopeNames),
            maximumPayload: maximumPayload,
            maximumPending: maximumPending
        )
    }

    private func activePairingContext() throws -> RivetDeviceSessionPairingContext {
        switch state {
        case .awaitingPairDecision(let context, _),
             .awaitingDesktopConfirmation(let context):
            context
        case .closed:
            throw RivetDeviceSessionStateError.sessionClosed
        default:
            throw RivetDeviceSessionStateError.pairingNotActive
        }
    }

    private func expireIfNeeded(
        now: Date
    ) async -> [RivetDeviceSessionServerAction] {
        switch state {
        case .awaitingStart(let deadline),
             .awaitingAuthProof(_, let deadline):
            guard now >= deadline else {
                return []
            }
            state = .closed
            return [.close]

        case .awaitingPairDecision(let context, let deadline):
            if now >= context.expiresAt {
                _ = await pairingCoordinator.status(now: now)
                return closeWithReject(.pairingExpired)
            }
            guard now >= deadline else {
                return []
            }
            try? await pairingCoordinator.abandonAttempt(
                windowID: context.windowID,
                attemptID: context.attemptID,
                now: now
            )
            state = .closed
            return [.close]

        case .awaitingDesktopConfirmation(let context):
            guard now >= context.expiresAt else {
                return []
            }
            _ = await pairingCoordinator.status(now: now)
            return closeWithReject(.pairingExpired)

        case .accepted, .closed:
            return []
        }
    }

    private func closeWithReject(
        _ code: RivetDeviceSessionRejectCode
    ) -> [RivetDeviceSessionServerAction] {
        state = .closed
        return [.send(.reject(code)), .close]
    }

    private func closeForProtocolViolation() -> RivetDeviceSessionStateError {
        state = .closed
        return .protocolViolation
    }
}

private func pairingRejectCode(for error: Error) -> RivetDeviceSessionRejectCode {
    guard let error = error as? RivetDevicePairingError else {
        return .internalError
    }
    switch error {
    case .windowExpired:
        return .pairingExpired
    case .windowUnavailable, .attemptUnavailable:
        return .pairingUnavailable
    case .windowAlreadyOpen, .attemptInProgress:
        return .serverBusy
    case .invalidApplicationID, .invalidFingerprintSize, .invalidNonceSize,
         .invalidDeviceName, .invalidScopeName:
        return .pairingRejected
    case .authenticationFailed:
        return .internalError
    }
}

private func canonicalScopeNames(_ names: [String]) -> [String] {
    Array(Set(names)).sorted(by: utf8Precedes)
}

private func validScopeNames(_ names: [String]) -> Bool {
    names.count <= rivetDeviceSessionMaximumScopeCount
        && Set(names).count == names.count
        && names.allSatisfy(isValidDeviceAPIName)
}

private func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
    let count = max(lhs.count, rhs.count)
    var difference = lhs.count ^ rhs.count
    for index in 0..<count {
        let left = index < lhs.count ? lhs[index] : 0
        let right = index < rhs.count ? rhs[index] : 0
        difference |= Int(left ^ right)
    }
    return difference == 0
}
