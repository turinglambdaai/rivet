import Foundation
import Testing
@testable import RivetDevice

private enum PairingTestError: Error {
    case exhaustedRandomValues
    case wrongRandomValueSize
}

private actor SequenceRandomBytes: RivetDeviceRandomBytesGenerator {
    private var values: [Data]

    init(_ values: [Data]) {
        self.values = values
    }

    func randomBytes(count: Int) async throws -> Data {
        guard !values.isEmpty else {
            throw PairingTestError.exhaustedRandomValues
        }
        let value = values.removeFirst()
        guard value.count == count else {
            throw PairingTestError.wrongRandomValueSize
        }
        return value
    }
}

private actor MemoryPairingStore: RivetDevicePairingStore {
    private var pairings: [UUID: RivetDeviceStoredPairing] = [:]

    func save(_ pairing: RivetDeviceStoredPairing) async throws {
        pairings[pairing.device.id] = pairing
    }

    func load(deviceID: UUID) async throws -> RivetDeviceStoredPairing? {
        pairings[deviceID]
    }

    func pairedDevices() async throws -> [RivetDevicePairedDevice] {
        pairings.values.map(\.device).sorted { $0.id.uuidString < $1.id.uuidString }
    }

    func remove(deviceID: UUID) async throws {
        pairings.removeValue(forKey: deviceID)
    }
}

private actor RecordingSessionRevoker: RivetDeviceSessionRevoker {
    private(set) var deviceIDs: [UUID] = []

    func revokeSessions(deviceID: UUID) async {
        deviceIDs.append(deviceID)
    }
}

private let pairingApplicationID = "com.example.app"
private let pairingFingerprint = Data(repeating: 0xaa, count: rivetDeviceFingerprintSize)
private let pairingClientNonce = Data(repeating: 0xbb, count: rivetDevicePairingNonceSize)
private let pairingServerNonce = Data(repeating: 0xcc, count: rivetDevicePairingNonceSize)
private let pairingCredential = Data(repeating: 0xdd, count: rivetDeviceCredentialSize)

@Test func pairingTranscriptHasStableGoldenCode() throws {
    let code = try RivetDevicePairingTranscript.verificationCode(
        applicationID: pairingApplicationID,
        serverFingerprint: pairingFingerprint,
        clientNonce: pairingClientNonce,
        serverNonce: pairingServerNonce
    )

    #expect(code == "151848")
    #expect(code.count == 6)
    #expect(try RivetDevicePairingTranscript.verificationCode(
        applicationID: pairingApplicationID,
        serverFingerprint: pairingFingerprint,
        clientNonce: pairingClientNonce,
        serverNonce: Data(repeating: 0xcd, count: rivetDevicePairingNonceSize)
    ) != code)
}

@Test func confirmedPairingPersistsMetadataAndAuthenticatesReconnect() async throws {
    let store = MemoryPairingStore()
    let random = SequenceRandomBytes([pairingServerNonce, pairingCredential])
    let coordinator = RivetDevicePairingCoordinator(store: store, random: random)
    let openedAt = Date(timeIntervalSince1970: 1_000)
    let window = try await coordinator.openWindow(
        applicationID: pairingApplicationID,
        serverFingerprint: pairingFingerprint,
        now: openedAt
    )
    #expect(window.expiresAt == Date(timeIntervalSince1970: 1_300))
    #expect(window.failedAttempts == 0)
    #expect(window.maximumFailedAttempts == 5)

    let challenge = try await coordinator.beginAttempt(
        windowID: window.id,
        deviceName: "Alice’s iPhone",
        clientNonce: pairingClientNonce,
        now: openedAt
    )
    #expect(challenge.serverNonce == pairingServerNonce)
    #expect(challenge.verificationCode == "151848")

    let firstDeviceConfirmation = try await coordinator.confirmOnDevice(
        windowID: window.id,
        attemptID: challenge.attemptID,
        now: openedAt.addingTimeInterval(5)
    )
    #expect(firstDeviceConfirmation == nil)
    #expect(try await store.pairedDevices().isEmpty)
    #expect(try await coordinator.confirmOnDevice(
        windowID: window.id,
        attemptID: challenge.attemptID,
        now: openedAt.addingTimeInterval(6)
    ) == nil)

    let maybeResult = try await coordinator.confirmOnDesktop(
        windowID: window.id,
        attemptID: challenge.attemptID,
        grantedScopeNames: ["controller", "reader", "controller"],
        now: openedAt.addingTimeInterval(10)
    )
    let result = try #require(maybeResult)
    #expect(result.credential == pairingCredential)
    #expect(result.device.scopeNames == ["controller", "reader"])
    #expect(result.device.name == "Alice’s iPhone")
    #expect(
        await coordinator.status(now: openedAt.addingTimeInterval(10))
            == .closed(lastReason: .succeeded(deviceID: result.device.id))
    )

    let stored = try await store.load(deviceID: result.device.id)
    #expect(stored == RivetDeviceStoredPairing(
        device: result.device,
        credential: pairingCredential
    ))

    let revoker = RecordingSessionRevoker()
    let authenticator = RivetDeviceSessionAuthenticator(
        store: store,
        sessionRevoker: revoker
    )
    let reconnectedAt = openedAt.addingTimeInterval(60)
    let authenticated = try await authenticator.authenticate(
        deviceID: result.device.id,
        applicationID: pairingApplicationID,
        serverFingerprint: pairingFingerprint,
        credential: pairingCredential,
        now: reconnectedAt
    )
    #expect(authenticated.lastUsedAt == reconnectedAt)
    #expect(authenticated.createdAt == result.device.createdAt)
    #expect(try await store.load(deviceID: result.device.id)?.device == authenticated)

    await #expect(throws: RivetDevicePairingError.authenticationFailed) {
        try await authenticator.authenticate(
            deviceID: result.device.id,
            applicationID: pairingApplicationID,
            serverFingerprint: pairingFingerprint,
            credential: Data(repeating: 0xee, count: rivetDeviceCredentialSize),
            now: reconnectedAt
        )
    }

    try await authenticator.revoke(deviceID: result.device.id)
    #expect(try await store.load(deviceID: result.device.id) == nil)
    #expect(await revoker.deviceIDs == [result.device.id])
    await #expect(throws: RivetDevicePairingError.authenticationFailed) {
        try await authenticator.authenticate(
            deviceID: result.device.id,
            applicationID: pairingApplicationID,
            serverFingerprint: pairingFingerprint,
            credential: pairingCredential,
            now: reconnectedAt
        )
    }
}

@Test func pairingWindowExpiresCancelsAndClosesAfterBoundedFailures() async throws {
    let store = MemoryPairingStore()
    let random = SequenceRandomBytes(Array(repeating: pairingServerNonce, count: 2))
    let coordinator = RivetDevicePairingCoordinator(
        store: store,
        random: random,
        windowDuration: 10,
        maximumFailedAttempts: 2
    )
    let now = Date(timeIntervalSince1970: 2_000)
    let firstWindow = try await coordinator.openWindow(
        applicationID: pairingApplicationID,
        serverFingerprint: pairingFingerprint,
        now: now
    )

    let firstAttempt = try await coordinator.beginAttempt(
        windowID: firstWindow.id,
        deviceName: "Phone",
        clientNonce: pairingClientNonce,
        now: now
    )
    try await coordinator.failAttempt(
        windowID: firstWindow.id,
        attemptID: firstAttempt.attemptID,
        now: now
    )
    let secondAttempt = try await coordinator.beginAttempt(
        windowID: firstWindow.id,
        deviceName: "Phone",
        clientNonce: pairingClientNonce,
        now: now
    )
    try await coordinator.failAttempt(
        windowID: firstWindow.id,
        attemptID: secondAttempt.attemptID,
        now: now
    )
    #expect(await coordinator.status(now: now) == .closed(lastReason: .tooManyFailures))

    let expiringWindow = try await coordinator.openWindow(
        applicationID: pairingApplicationID,
        serverFingerprint: pairingFingerprint,
        now: now
    )
    await #expect(throws: RivetDevicePairingError.windowExpired) {
        try await coordinator.beginAttempt(
            windowID: expiringWindow.id,
            deviceName: "Phone",
            clientNonce: pairingClientNonce,
            now: now.addingTimeInterval(10)
        )
    }
    #expect(
        await coordinator.status(now: now.addingTimeInterval(10))
            == .closed(lastReason: .expired)
    )

    let cancelledWindow = try await coordinator.openWindow(
        applicationID: pairingApplicationID,
        serverFingerprint: pairingFingerprint,
        now: now.addingTimeInterval(20)
    )
    try await coordinator.cancelWindow(windowID: cancelledWindow.id)
    #expect(
        await coordinator.status(now: now.addingTimeInterval(20))
            == .closed(lastReason: .cancelled)
    )
}

@Test func pairingRejectsMalformedInputsAndConcurrentAttempts() async throws {
    let store = MemoryPairingStore()
    let random = SequenceRandomBytes([pairingServerNonce])
    let coordinator = RivetDevicePairingCoordinator(store: store, random: random)
    let now = Date(timeIntervalSince1970: 3_000)

    await #expect(throws: RivetDevicePairingError.invalidApplicationID) {
        try await coordinator.openWindow(
            applicationID: "bad application id",
            serverFingerprint: pairingFingerprint,
            now: now
        )
    }
    await #expect(throws: RivetDevicePairingError.invalidFingerprintSize) {
        try await coordinator.openWindow(
            applicationID: pairingApplicationID,
            serverFingerprint: Data(),
            now: now
        )
    }

    let window = try await coordinator.openWindow(
        applicationID: pairingApplicationID,
        serverFingerprint: pairingFingerprint,
        now: now
    )
    await #expect(throws: RivetDevicePairingError.invalidDeviceName) {
        try await coordinator.beginAttempt(
            windowID: window.id,
            deviceName: " Phone ",
            clientNonce: pairingClientNonce,
            now: now
        )
    }
    await #expect(throws: RivetDevicePairingError.invalidNonceSize) {
        try await coordinator.beginAttempt(
            windowID: window.id,
            deviceName: "Phone",
            clientNonce: Data(),
            now: now
        )
    }

    let attempt = try await coordinator.beginAttempt(
        windowID: window.id,
        deviceName: "Phone",
        clientNonce: pairingClientNonce,
        now: now
    )
    await #expect(throws: RivetDevicePairingError.attemptInProgress) {
        try await coordinator.beginAttempt(
            windowID: window.id,
            deviceName: "Another phone",
            clientNonce: pairingClientNonce,
            now: now
        )
    }
    await #expect(throws: RivetDevicePairingError.invalidScopeName("bad scope")) {
        try await coordinator.confirmOnDesktop(
            windowID: window.id,
            attemptID: attempt.attemptID,
            grantedScopeNames: ["bad scope"],
            now: now
        )
    }
}

@Test func authenticationMismatchFieldsShareOneStableFailure() async throws {
    let store = MemoryPairingStore()
    let device = RivetDevicePairedDevice(
        id: UUID(),
        applicationID: pairingApplicationID,
        name: "Phone",
        scopeNames: ["reader"],
        serverFingerprint: pairingFingerprint,
        createdAt: Date(timeIntervalSince1970: 4_000),
        lastUsedAt: Date(timeIntervalSince1970: 4_000)
    )
    try await store.save(RivetDeviceStoredPairing(
        device: device,
        credential: pairingCredential
    ))
    let authenticator = RivetDeviceSessionAuthenticator(store: store)

    for (applicationID, fingerprint, credential) in [
        ("com.example.other", pairingFingerprint, pairingCredential),
        (pairingApplicationID, Data(repeating: 0xab, count: 32), pairingCredential),
        (pairingApplicationID, pairingFingerprint, Data(repeating: 0xde, count: 32))
    ] {
        await #expect(throws: RivetDevicePairingError.authenticationFailed) {
            try await authenticator.authenticate(
                deviceID: device.id,
                applicationID: applicationID,
                serverFingerprint: fingerprint,
                credential: credential
            )
        }
    }
}
