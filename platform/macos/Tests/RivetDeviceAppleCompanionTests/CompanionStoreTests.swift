import Foundation
import RivetDevice
import RivetDeviceSession
import Testing
@testable import RivetDeviceAppleCompanion

private actor MemoryPairingStore: RivetDevicePairingStore {
    private var values: [UUID: RivetDeviceStoredPairing] = [:]

    func save(_ pairing: RivetDeviceStoredPairing) async throws {
        values[pairing.device.id] = pairing
    }

    func load(deviceID: UUID) async throws -> RivetDeviceStoredPairing? {
        values[deviceID]
    }

    func pairedDevices() async throws -> [RivetDevicePairedDevice] {
        values.values.map(\.device).sorted { $0.name < $1.name }
    }

    func remove(deviceID: UUID) async throws {
        values.removeValue(forKey: deviceID)
    }
}

@Test func appleCompanionPersistsCredentialBeforeRecordingGrantedScopes() async throws {
    let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
    let store = MemoryPairingStore()
    let adapter = try RivetDeviceApplePairingCredentialStoreAdapter(
        store: store,
        applicationID: "com.example.player",
        deviceName: "Test iPhone",
        now: { timestamp }
    )
    let deviceID = UUID()
    let credential = Data(repeating: 0xA5, count: rivetDeviceCredentialSize)
    let fingerprint = Data(repeating: 0x5A, count: rivetDeviceFingerprintSize)

    try await adapter.savePairingCredential(
        deviceID: deviceID,
        credential: credential,
        serverFingerprint: fingerprint
    )
    let initialValue = try await store.load(deviceID: deviceID)
    let initial = try #require(initialValue)
    #expect(initial.credential == credential)
    #expect(initial.device.serverFingerprint == fingerprint)
    #expect(initial.device.scopeNames.isEmpty)
    #expect(initial.device.createdAt == timestamp)

    let acceptance = RivetDeviceSessionClientAcceptance(
        sessionID: UUID(),
        deviceID: deviceID,
        scopeNames: ["playback.read", "playback.seek"],
        maximumPayload: 64 * 1024,
        maximumPending: 8
    )
    try await adapter.recordAcceptance(acceptance)

    let acceptedValue = try await store.load(deviceID: deviceID)
    let accepted = try #require(acceptedValue)
    #expect(accepted.credential == credential)
    #expect(accepted.device.scopeNames == ["playback.read", "playback.seek"])
    #expect(accepted.device.createdAt == timestamp)
    #expect(accepted.device.lastUsedAt == timestamp)
}

@Test func appleCompanionCannotOverwriteAnExistingPairingCredential() async throws {
    let store = MemoryPairingStore()
    let adapter = try RivetDeviceApplePairingCredentialStoreAdapter(
        store: store,
        applicationID: "com.example.player",
        deviceName: "Test iPhone",
        now: { Date(timeIntervalSince1970: 1_800_000_000) }
    )
    let deviceID = UUID()
    let original = Data(repeating: 0x11, count: rivetDeviceCredentialSize)
    let replacement = Data(repeating: 0x22, count: rivetDeviceCredentialSize)
    let fingerprint = Data(repeating: 0x33, count: rivetDeviceFingerprintSize)
    try await adapter.savePairingCredential(
        deviceID: deviceID,
        credential: original,
        serverFingerprint: fingerprint
    )

    await #expect(throws: RivetDeviceAppleCompanionError.pairingAlreadyExists) {
        try await adapter.savePairingCredential(
            deviceID: deviceID,
            credential: replacement,
            serverFingerprint: fingerprint
        )
    }
    let persisted = try await store.load(deviceID: deviceID)
    #expect(persisted?.credential == original)
}

@Test func appleCompanionRejectsAcceptanceWithoutAStoredCredential() async throws {
    let store = MemoryPairingStore()
    let adapter = try RivetDeviceApplePairingCredentialStoreAdapter(
        store: store,
        applicationID: "com.example.player",
        deviceName: "Test iPhone"
    )
    let acceptance = RivetDeviceSessionClientAcceptance(
        sessionID: UUID(),
        deviceID: UUID(),
        scopeNames: ["playback.read"],
        maximumPayload: 1024,
        maximumPending: 4
    )
    await #expect(throws: RivetDeviceAppleCompanionError.pairingNotFound) {
        try await adapter.recordAcceptance(acceptance)
    }
}

@Test func appleCompanionConfigurationRejectsInvalidApplicationIDs() throws {
    #expect(throws: RivetDeviceAppleCompanionError.invalidConfiguration) {
        try RivetDeviceAppleCompanionConfiguration(
            applicationID: "not an app id",
            deviceName: "Test iPhone"
        )
    }
    #expect(throws: RivetDeviceAppleCompanionError.invalidConfiguration) {
        try RivetDeviceAppleCompanionConfiguration(
            applicationID: "com.example.player",
            deviceName: " \n "
        )
    }
}
