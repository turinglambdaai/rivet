import Foundation
import RivetDevice
import Testing
@testable import RivetDeviceSession

private let clientApplicationID = "com.example.app"
private let clientDeviceID = UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!
private let clientWindowID = UUID(uuidString: "10213243-5465-7687-98a9-bacbdcedfe0f")!
private let clientAttemptID = UUID(uuidString: "ffeeddcc-bbaa-9988-7766-554433221100")!
private let clientSessionID = UUID(uuidString: "01234567-89ab-cdef-0123-456789abcdef")!
private let clientFingerprint = Data(repeating: 0xa1, count: rivetDeviceFingerprintSize)
private let clientNonce = Data(repeating: 0xa2, count: rivetDevicePairingNonceSize)
private let clientServerNonce = Data(repeating: 0xa3, count: rivetDevicePairingNonceSize)
private let clientCredential = Data(repeating: 0xa4, count: rivetDeviceCredentialSize)
private let clientNow = Date(timeIntervalSince1970: 20_000)

@Test func reconnectClientProducesProofAndAcceptsOnlyAfterServerAccept() async throws {
    let client = try RivetDeviceSessionClient(
        reconnectApplicationID: clientApplicationID,
        deviceID: clientDeviceID,
        credential: clientCredential,
        serverFingerprint: clientFingerprint,
        clientNonce: clientNonce,
        startedAt: clientNow
    )
    #expect(try await client.start(now: clientNow) == [.send(.authenticate(
        applicationID: clientApplicationID,
        deviceID: clientDeviceID,
        clientNonce: clientNonce
    ))])

    let proofActions = try await client.receive(
        .authChallenge(serverNonce: clientServerNonce),
        now: clientNow.addingTimeInterval(1)
    )
    let expectedProof = try RivetDeviceSessionAuthentication.proof(
        credential: clientCredential,
        applicationID: clientApplicationID,
        serverFingerprint: clientFingerprint,
        deviceID: clientDeviceID,
        clientNonce: clientNonce,
        serverNonce: clientServerNonce
    )
    #expect(proofActions == [.send(.authProof(expectedProof))])
    #expect(await client.acceptance() == nil)

    let expectedAcceptance = RivetDeviceSessionClientAcceptance(
        sessionID: clientSessionID,
        deviceID: clientDeviceID,
        scopeNames: ["reader"],
        maximumPayload: rivetDeviceDefaultMaximumMessageSize,
        maximumPending: rivetDeviceDefaultMaximumPendingRequests
    )
    #expect(try await client.receive(.accept(
        sessionID: clientSessionID,
        scopeNames: ["reader"],
        maximumPayload: rivetDeviceDefaultMaximumMessageSize,
        maximumPending: rivetDeviceDefaultMaximumPendingRequests
    ), now: clientNow.addingTimeInterval(2)) == [.accepted(expectedAcceptance)])
    #expect(await client.acceptance() == expectedAcceptance)
}

@Test func pairingClientRequiresCredentialPersistenceBeforeAcceptance() async throws {
    let client = try RivetDeviceSessionClient(
        pairingApplicationID: clientApplicationID,
        windowID: clientWindowID,
        deviceName: "Test Phone",
        serverFingerprint: clientFingerprint,
        clientNonce: clientNonce,
        startedAt: clientNow
    )
    #expect(try await client.start(now: clientNow) == [.send(.pairStart(
        applicationID: clientApplicationID,
        windowID: clientWindowID,
        deviceName: "Test Phone",
        clientNonce: clientNonce
    ))])

    let code = try RivetDevicePairingTranscript.verificationCode(
        applicationID: clientApplicationID,
        serverFingerprint: clientFingerprint,
        clientNonce: clientNonce,
        serverNonce: clientServerNonce
    )
    #expect(try await client.receive(.pairChallenge(
        attemptID: clientAttemptID,
        serverNonce: clientServerNonce
    ), now: clientNow.addingTimeInterval(1)) == [
        .showPairingCode(attemptID: clientAttemptID, code: code)
    ])
    #expect(try await client.confirmPairing(
        true,
        now: clientNow.addingTimeInterval(2)
    ) == [.send(.pairDecision(attemptID: clientAttemptID, confirmed: true))])

    let credential = Data(repeating: 0xb5, count: rivetDeviceCredentialSize)
    #expect(try await client.receive(.paired(
        deviceID: clientDeviceID,
        credential: credential,
        sessionID: clientSessionID,
        scopeNames: ["controller", "reader"],
        maximumPayload: rivetDeviceDefaultMaximumMessageSize,
        maximumPending: rivetDeviceDefaultMaximumPendingRequests
    ), now: clientNow.addingTimeInterval(3)) == [.persistPairing(
        deviceID: clientDeviceID,
        credential: credential,
        serverFingerprint: clientFingerprint
    )])
    #expect(await client.acceptance() == nil)

    let expectedAcceptance = RivetDeviceSessionClientAcceptance(
        sessionID: clientSessionID,
        deviceID: clientDeviceID,
        scopeNames: ["controller", "reader"],
        maximumPayload: rivetDeviceDefaultMaximumMessageSize,
        maximumPending: rivetDeviceDefaultMaximumPendingRequests
    )
    #expect(try await client.pairingPersisted() == [.accepted(expectedAcceptance)])
    #expect(await client.acceptance() == expectedAcceptance)
}

@Test func pairingPersistenceFailureAndRejectCloseTheClient() async throws {
    let client = try RivetDeviceSessionClient(
        pairingApplicationID: clientApplicationID,
        windowID: clientWindowID,
        deviceName: "Test Phone",
        serverFingerprint: clientFingerprint,
        clientNonce: clientNonce,
        startedAt: clientNow
    )
    _ = try await client.start(now: clientNow)
    _ = try await client.receive(.pairChallenge(
        attemptID: clientAttemptID,
        serverNonce: clientServerNonce
    ), now: clientNow.addingTimeInterval(1))
    _ = try await client.confirmPairing(true, now: clientNow.addingTimeInterval(2))
    _ = try await client.receive(.paired(
        deviceID: clientDeviceID,
        credential: clientCredential,
        sessionID: clientSessionID,
        scopeNames: ["reader"],
        maximumPayload: rivetDeviceDefaultMaximumMessageSize,
        maximumPending: rivetDeviceDefaultMaximumPendingRequests
    ), now: clientNow.addingTimeInterval(3))
    #expect(try await client.pairingPersistenceFailed() == [.close])
    await #expect(throws: RivetDeviceSessionStateError.sessionClosed) {
        try await client.pairingPersisted()
    }

    let notPersisting = try RivetDeviceSessionClient(
        reconnectApplicationID: clientApplicationID,
        deviceID: clientDeviceID,
        credential: clientCredential,
        serverFingerprint: clientFingerprint,
        clientNonce: clientNonce,
        startedAt: clientNow
    )
    await #expect(throws: RivetDeviceSessionStateError.pairingNotActive) {
        try await notPersisting.pairingPersistenceFailed()
    }

    let rejected = try RivetDeviceSessionClient(
        reconnectApplicationID: clientApplicationID,
        deviceID: clientDeviceID,
        credential: clientCredential,
        serverFingerprint: clientFingerprint,
        clientNonce: clientNonce,
        startedAt: clientNow
    )
    _ = try await rejected.start(now: clientNow)
    #expect(try await rejected.receive(
        .reject(.authenticationFailed),
        now: clientNow.addingTimeInterval(1)
    ) == [.rejected(.authenticationFailed), .close])
}

@Test func clientStateMachineEnforcesOrderAndInjectedTimeouts() async throws {
    let client = try RivetDeviceSessionClient(
        reconnectApplicationID: clientApplicationID,
        deviceID: clientDeviceID,
        credential: clientCredential,
        serverFingerprint: clientFingerprint,
        clientNonce: clientNonce,
        startedAt: clientNow
    )
    #expect(await client.expire(
        now: clientNow.addingTimeInterval(rivetDeviceSessionPostTLSTimeout)
    ) == [.close])
    await #expect(throws: RivetDeviceSessionStateError.sessionClosed) {
        try await client.start(now: clientNow)
    }

    let invalid = try RivetDeviceSessionClient(
        reconnectApplicationID: clientApplicationID,
        deviceID: clientDeviceID,
        credential: clientCredential,
        serverFingerprint: clientFingerprint,
        clientNonce: clientNonce,
        startedAt: clientNow
    )
    _ = try await invalid.start(now: clientNow)
    await #expect(throws: RivetDeviceSessionStateError.protocolViolation) {
        try await invalid.receive(.accept(
            sessionID: clientSessionID,
            scopeNames: [],
            maximumPayload: rivetDeviceDefaultMaximumMessageSize,
            maximumPending: rivetDeviceDefaultMaximumPendingRequests
        ), now: clientNow.addingTimeInterval(1))
    }
    await #expect(throws: RivetDeviceSessionStateError.sessionClosed) {
        try await invalid.receive(
            .authChallenge(serverNonce: clientServerNonce),
            now: clientNow.addingTimeInterval(2)
        )
    }

    let prematureReject = try RivetDeviceSessionClient(
        reconnectApplicationID: clientApplicationID,
        deviceID: clientDeviceID,
        credential: clientCredential,
        serverFingerprint: clientFingerprint,
        clientNonce: clientNonce,
        startedAt: clientNow
    )
    await #expect(throws: RivetDeviceSessionStateError.protocolViolation) {
        try await prematureReject.receive(
            .reject(.authenticationFailed),
            now: clientNow
        )
    }
}
