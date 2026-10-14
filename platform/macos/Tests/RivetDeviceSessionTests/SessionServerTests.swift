import Foundation
import RivetDevice
import Testing
@testable import RivetDeviceSession

private enum SessionServerTestError: Error {
    case exhaustedRandomValues
    case wrongRandomValueSize
    case forcedStoreFailure
}

private actor SessionServerMemoryStore: RivetDevicePairingStore {
    private var pairings: [UUID: RivetDeviceStoredPairing] = [:]
    private var failLoads = false

    init(_ initialPairings: [RivetDeviceStoredPairing] = []) {
        pairings = Dictionary(
            uniqueKeysWithValues: initialPairings.map { ($0.device.id, $0) }
        )
    }

    func setFailLoads(_ value: Bool) {
        failLoads = value
    }

    func save(_ pairing: RivetDeviceStoredPairing) async throws {
        pairings[pairing.device.id] = pairing
    }

    func load(deviceID: UUID) async throws -> RivetDeviceStoredPairing? {
        if failLoads {
            throw SessionServerTestError.forcedStoreFailure
        }
        return pairings[deviceID]
    }

    func pairedDevices() async throws -> [RivetDevicePairedDevice] {
        pairings.values.map(\.device)
    }

    func remove(deviceID: UUID) async throws {
        pairings.removeValue(forKey: deviceID)
    }
}

private actor SessionServerRandomBytes: RivetDeviceRandomBytesGenerator {
    private var values: [Data]

    init(_ values: [Data]) {
        self.values = values
    }

    func randomBytes(count: Int) async throws -> Data {
        guard !values.isEmpty else {
            throw SessionServerTestError.exhaustedRandomValues
        }
        let value = values.removeFirst()
        guard value.count == count else {
            throw SessionServerTestError.wrongRandomValueSize
        }
        return value
    }
}

private final class SessionServerUUIDs: RivetDeviceSessionUUIDGenerator,
    @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID]

    init(_ values: [UUID]) {
        self.values = values
    }

    func nextUUID() -> UUID {
        lock.withLock {
            precondition(!values.isEmpty)
            return values.removeFirst()
        }
    }
}

private let serverApplicationID = "com.example.app"
private let serverFingerprint = Data(repeating: 0x71, count: rivetDeviceFingerprintSize)
private let serverClientNonce = Data(repeating: 0x72, count: rivetDevicePairingNonceSize)
private let serverNonce = Data(repeating: 0x73, count: rivetDevicePairingNonceSize)
private let serverDummyCredential = Data(repeating: 0x74, count: rivetDeviceCredentialSize)
private let serverCredential = Data(repeating: 0x75, count: rivetDeviceCredentialSize)
private let serverSessionID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
private let serverNow = Date(timeIntervalSince1970: 10_000)

private func makeServerPairing(
    id: UUID = UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!,
    applicationID: String = serverApplicationID,
    fingerprint: Data = serverFingerprint,
    credential: Data = serverCredential
) -> RivetDeviceStoredPairing {
    RivetDeviceStoredPairing(
        device: RivetDevicePairedDevice(
            id: id,
            applicationID: applicationID,
            name: "Test Phone",
            scopeNames: ["reader", "controller"],
            serverFingerprint: fingerprint,
            createdAt: serverNow.addingTimeInterval(-100),
            lastUsedAt: serverNow.addingTimeInterval(-100)
        ),
        credential: credential
    )
}

private func makeSessionServer(
    store: SessionServerMemoryStore,
    coordinatorRandom: SessionServerRandomBytes = SessionServerRandomBytes([]),
    serverRandom: SessionServerRandomBytes = SessionServerRandomBytes([
        serverNonce,
        serverDummyCredential
    ]),
    sessionIDs: [UUID] = [serverSessionID],
    startedAt: Date = serverNow
) throws -> RivetDeviceSessionServer {
    let coordinator = RivetDevicePairingCoordinator(
        store: store,
        random: coordinatorRandom
    )
    return try RivetDeviceSessionServer(
        applicationID: serverApplicationID,
        serverFingerprint: serverFingerprint,
        store: store,
        pairingCoordinator: coordinator,
        random: serverRandom,
        uuidGenerator: SessionServerUUIDs(sessionIDs),
        startedAt: startedAt
    )
}

@Test func deviceSessionServerAuthenticatesReconnectAndUpdatesLastUsed() async throws {
    let pairing = makeServerPairing()
    let store = SessionServerMemoryStore([pairing])
    let server = try makeSessionServer(store: store)

    let challengeActions = try await server.receive(.authenticate(
        applicationID: serverApplicationID,
        deviceID: pairing.device.id,
        clientNonce: serverClientNonce
    ), now: serverNow)
    #expect(challengeActions == [.send(.authChallenge(serverNonce: serverNonce))])

    let proof = try RivetDeviceSessionAuthentication.proof(
        credential: serverCredential,
        applicationID: serverApplicationID,
        serverFingerprint: serverFingerprint,
        deviceID: pairing.device.id,
        clientNonce: serverClientNonce,
        serverNonce: serverNonce
    )
    let acceptedAt = serverNow.addingTimeInterval(1)
    let acceptedActions = try await server.receive(.authProof(proof), now: acceptedAt)
    let expectedAcceptance = RivetDeviceSessionAcceptance(
        sessionID: serverSessionID,
        deviceID: pairing.device.id,
        applicationID: serverApplicationID,
        scopeNames: ["controller", "reader"],
        maximumPayload: rivetDeviceDefaultMaximumMessageSize,
        maximumPending: rivetDeviceDefaultMaximumPendingRequests
    )
    #expect(acceptedActions == [
        .send(.accept(
            sessionID: serverSessionID,
            scopeNames: ["controller", "reader"],
            maximumPayload: rivetDeviceDefaultMaximumMessageSize,
            maximumPending: rivetDeviceDefaultMaximumPendingRequests
        )),
        .accepted(expectedAcceptance)
    ])
    #expect(await server.acceptance() == expectedAcceptance)
    #expect(try await store.load(deviceID: pairing.device.id)?.device.lastUsedAt == acceptedAt)

    await #expect(throws: RivetDeviceSessionStateError.protocolViolation) {
        try await server.receive(.authProof(proof), now: acceptedAt)
    }
    await #expect(throws: RivetDeviceSessionStateError.sessionClosed) {
        try await server.receive(.authProof(proof), now: acceptedAt)
    }
}

@Test func authenticationFailuresHaveOnePublicSequenceAndCode() async throws {
    let known = makeServerPairing()
    let cases: [(SessionServerMemoryStore, String, Data, UUID)] = [
        (SessionServerMemoryStore(), serverApplicationID, serverFingerprint, known.device.id),
        (SessionServerMemoryStore([known]), "com.example.other", serverFingerprint, known.device.id),
        (
            SessionServerMemoryStore([makeServerPairing(
                fingerprint: Data(repeating: 0x99, count: rivetDeviceFingerprintSize)
            )]),
            serverApplicationID,
            serverFingerprint,
            known.device.id
        ),
        (
            SessionServerMemoryStore([makeServerPairing(credential: Data())]),
            serverApplicationID,
            serverFingerprint,
            known.device.id
        )
    ]

    for (store, requestedApplicationID, fingerprint, deviceID) in cases {
        let coordinator = RivetDevicePairingCoordinator(store: store)
        let server = try RivetDeviceSessionServer(
            applicationID: serverApplicationID,
            serverFingerprint: fingerprint,
            store: store,
            pairingCoordinator: coordinator,
            random: SessionServerRandomBytes([serverNonce, serverDummyCredential]),
            uuidGenerator: SessionServerUUIDs([serverSessionID]),
            startedAt: serverNow
        )
        let first = try await server.receive(.authenticate(
            applicationID: requestedApplicationID,
            deviceID: deviceID,
            clientNonce: serverClientNonce
        ), now: serverNow)
        #expect(first == [.send(.authChallenge(serverNonce: serverNonce))])

        let clientProof = try RivetDeviceSessionAuthentication.proof(
            credential: serverCredential,
            applicationID: requestedApplicationID,
            serverFingerprint: fingerprint,
            deviceID: deviceID,
            clientNonce: serverClientNonce,
            serverNonce: serverNonce
        )
        #expect(try await server.receive(
            .authProof(clientProof),
            now: serverNow.addingTimeInterval(1)
        ) == [.send(.reject(.authenticationFailed)), .close])
    }

    let failingStore = SessionServerMemoryStore([known])
    await failingStore.setFailLoads(true)
    let failingServer = try makeSessionServer(store: failingStore)
    #expect(try await failingServer.receive(.authenticate(
        applicationID: serverApplicationID,
        deviceID: known.device.id,
        clientNonce: serverClientNonce
    ), now: serverNow) == [.send(.authChallenge(serverNonce: serverNonce))])
    let proof = try RivetDeviceSessionAuthentication.proof(
        credential: serverCredential,
        applicationID: serverApplicationID,
        serverFingerprint: serverFingerprint,
        deviceID: known.device.id,
        clientNonce: serverClientNonce,
        serverNonce: serverNonce
    )
    #expect(try await failingServer.receive(
        .authProof(proof),
        now: serverNow.addingTimeInterval(1)
    ) == [.send(.reject(.authenticationFailed)), .close])

    let wrongProofServer = try makeSessionServer(
        store: SessionServerMemoryStore([known])
    )
    #expect(try await wrongProofServer.receive(.authenticate(
        applicationID: serverApplicationID,
        deviceID: known.device.id,
        clientNonce: serverClientNonce
    ), now: serverNow) == [.send(.authChallenge(serverNonce: serverNonce))])
    #expect(try await wrongProofServer.receive(
        .authProof(Data(repeating: 0xff, count: rivetDeviceCredentialSize)),
        now: serverNow.addingTimeInterval(1)
    ) == [.send(.reject(.authenticationFailed)), .close])
}

@Test func deviceSessionPairingRequiresBothPeersAndIssuesOnce() async throws {
    let store = SessionServerMemoryStore()
    let pairingServerNonce = Data(repeating: 0x81, count: rivetDevicePairingNonceSize)
    let issuedCredential = Data(repeating: 0x82, count: rivetDeviceCredentialSize)
    let coordinatorRandom = SessionServerRandomBytes([pairingServerNonce, issuedCredential])
    let coordinator = RivetDevicePairingCoordinator(
        store: store,
        random: coordinatorRandom
    )
    let window = try await coordinator.openWindow(
        applicationID: serverApplicationID,
        serverFingerprint: serverFingerprint,
        now: serverNow
    )
    let server = try RivetDeviceSessionServer(
        applicationID: serverApplicationID,
        serverFingerprint: serverFingerprint,
        store: store,
        pairingCoordinator: coordinator,
        random: SessionServerRandomBytes([]),
        uuidGenerator: SessionServerUUIDs([serverSessionID]),
        startedAt: serverNow
    )

    let startActions = try await server.receive(.pairStart(
        applicationID: serverApplicationID,
        windowID: window.id,
        deviceName: "New Phone",
        clientNonce: serverClientNonce
    ), now: serverNow)
    guard case .send(.pairChallenge(let attemptID, let returnedNonce)) = startActions[0],
          case .showPairingCode(let shownAttemptID, let code, _) = startActions[1] else {
        Issue.record("expected pairing challenge and verification-code actions")
        return
    }
    #expect(returnedNonce == pairingServerNonce)
    #expect(shownAttemptID == attemptID)
    #expect(code.count == 6)

    #expect(try await server.confirmPairingOnDesktop(
        grantedScopeNames: ["reader", "controller", "reader"],
        now: serverNow.addingTimeInterval(1)
    ).isEmpty)
    let result = try await server.receive(.pairDecision(
        attemptID: attemptID,
        confirmed: true
    ), now: serverNow.addingTimeInterval(2))
    guard case .send(.paired(
        let deviceID,
        let credential,
        let returnedSessionID,
        let scopes,
        _,
        _
    )) = result[0], case .accepted(let acceptance) = result[1] else {
        Issue.record("expected paired and accepted actions")
        return
    }
    #expect(credential == issuedCredential)
    #expect(returnedSessionID == serverSessionID)
    #expect(scopes == ["controller", "reader"])
    #expect(acceptance.deviceID == deviceID)
    #expect(try await store.load(deviceID: deviceID)?.credential == issuedCredential)
}

@Test func deviceSessionPairingRejectsOrAbandonsAttemptsDeterministically() async throws {
    let store = SessionServerMemoryStore()
    let random = SessionServerRandomBytes([
        Data(repeating: 0x91, count: rivetDevicePairingNonceSize),
        Data(repeating: 0x92, count: rivetDevicePairingNonceSize)
    ])
    let coordinator = RivetDevicePairingCoordinator(store: store, random: random)
    let window = try await coordinator.openWindow(
        applicationID: serverApplicationID,
        serverFingerprint: serverFingerprint,
        now: serverNow
    )
    let firstServer = try RivetDeviceSessionServer(
        applicationID: serverApplicationID,
        serverFingerprint: serverFingerprint,
        store: store,
        pairingCoordinator: coordinator,
        random: SessionServerRandomBytes([]),
        startedAt: serverNow
    )
    let firstActions = try await firstServer.receive(.pairStart(
        applicationID: serverApplicationID,
        windowID: window.id,
        deviceName: "Phone",
        clientNonce: serverClientNonce
    ), now: serverNow)
    guard case .send(.pairChallenge(let firstAttemptID, _)) = firstActions[0] else {
        Issue.record("expected first challenge")
        return
    }
    await firstServer.disconnect(now: serverNow.addingTimeInterval(1))

    let secondServer = try RivetDeviceSessionServer(
        applicationID: serverApplicationID,
        serverFingerprint: serverFingerprint,
        store: store,
        pairingCoordinator: coordinator,
        random: SessionServerRandomBytes([]),
        startedAt: serverNow.addingTimeInterval(2)
    )
    let secondActions = try await secondServer.receive(.pairStart(
        applicationID: serverApplicationID,
        windowID: window.id,
        deviceName: "Phone",
        clientNonce: serverClientNonce
    ), now: serverNow.addingTimeInterval(2))
    guard case .send(.pairChallenge(let secondAttemptID, _)) = secondActions[0] else {
        Issue.record("expected second challenge")
        return
    }
    #expect(secondAttemptID != firstAttemptID)
    #expect(try await secondServer.receive(.pairDecision(
        attemptID: secondAttemptID,
        confirmed: false
    ), now: serverNow.addingTimeInterval(3)) == [
        .send(.reject(.pairingRejected)),
        .close
    ])
    guard case .open(let status) = await coordinator.status(now: serverNow) else {
        Issue.record("pairing window should remain open after one rejection")
        return
    }
    #expect(status.failedAttempts == 1)
    #expect(status.activeAttemptID == nil)
}

@Test func invalidDesktopScopesConsumeAndReleaseTheAttempt() async throws {
    let store = SessionServerMemoryStore()
    let random = SessionServerRandomBytes([
        Data(repeating: 0x96, count: rivetDevicePairingNonceSize)
    ])
    let coordinator = RivetDevicePairingCoordinator(store: store, random: random)
    let window = try await coordinator.openWindow(
        applicationID: serverApplicationID,
        serverFingerprint: serverFingerprint,
        now: serverNow
    )
    let server = try RivetDeviceSessionServer(
        applicationID: serverApplicationID,
        serverFingerprint: serverFingerprint,
        store: store,
        pairingCoordinator: coordinator,
        random: SessionServerRandomBytes([]),
        startedAt: serverNow
    )
    _ = try await server.receive(.pairStart(
        applicationID: serverApplicationID,
        windowID: window.id,
        deviceName: "Phone",
        clientNonce: serverClientNonce
    ), now: serverNow)
    #expect(try await server.confirmPairingOnDesktop(
        grantedScopeNames: ["invalid scope"],
        now: serverNow.addingTimeInterval(1)
    ) == [.send(.reject(.pairingRejected)), .close])
    guard case .open(let status) = await coordinator.status(now: serverNow) else {
        Issue.record("pairing window should remain open")
        return
    }
    #expect(status.failedAttempts == 1)
    #expect(status.activeAttemptID == nil)
}

@Test func deviceSessionServerEnforcesOrderAndInjectedDeadlines() async throws {
    let store = SessionServerMemoryStore()
    let server = try makeSessionServer(store: store)
    #expect(await server.expire(
        now: serverNow.addingTimeInterval(rivetDeviceSessionPostTLSTimeout)
    ) == [.close])
    await #expect(throws: RivetDeviceSessionStateError.sessionClosed) {
        try await server.receive(.authProof(serverCredential), now: serverNow)
    }

    let invalidServer = try makeSessionServer(store: SessionServerMemoryStore())
    await #expect(throws: RivetDeviceSessionStateError.protocolViolation) {
        try await invalidServer.receive(.authProof(serverCredential), now: serverNow)
    }
    await #expect(throws: RivetDeviceSessionStateError.sessionClosed) {
        try await invalidServer.receive(.authProof(serverCredential), now: serverNow)
    }

    let pairingStore = SessionServerMemoryStore()
    let pairingCoordinator = RivetDevicePairingCoordinator(
        store: pairingStore,
        random: SessionServerRandomBytes([
            Data(repeating: 0xc1, count: rivetDevicePairingNonceSize)
        ])
    )
    let window = try await pairingCoordinator.openWindow(
        applicationID: serverApplicationID,
        serverFingerprint: serverFingerprint,
        now: serverNow
    )
    let pairingServer = try RivetDeviceSessionServer(
        applicationID: serverApplicationID,
        serverFingerprint: serverFingerprint,
        store: pairingStore,
        pairingCoordinator: pairingCoordinator,
        random: SessionServerRandomBytes([]),
        startedAt: serverNow
    )
    _ = try await pairingServer.receive(.pairStart(
        applicationID: serverApplicationID,
        windowID: window.id,
        deviceName: "Phone",
        clientNonce: serverClientNonce
    ), now: serverNow)
    #expect(await pairingServer.expire(
        now: serverNow.addingTimeInterval(rivetDeviceSessionPostTLSTimeout)
    ) == [.close])
    guard case .open(let status) = await pairingCoordinator.status(
        now: serverNow.addingTimeInterval(rivetDeviceSessionPostTLSTimeout)
    ) else {
        Issue.record("pairing window should remain open after preface timeout")
        return
    }
    #expect(status.failedAttempts == 0)
    #expect(status.activeAttemptID == nil)
}
