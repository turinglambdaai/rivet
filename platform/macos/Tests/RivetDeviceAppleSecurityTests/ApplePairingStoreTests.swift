import Foundation
import RivetDevice
import Security
import Testing
@testable import RivetDeviceAppleSecurity

private final class MemoryKeychainClient: RivetDeviceAppleKeychainClient,
    @unchecked Sendable {
    enum Operation: String, Sendable {
        case add
        case update
        case load
        case list
        case remove
    }

    struct Call: Sendable, Equatable {
        let operation: Operation
        let service: String
        let account: String?
        let accessibility: RivetDeviceAppleKeychainAccessibility
        let synchronizable: Bool
    }

    private struct Key: Hashable {
        let service: String
        let account: String
    }

    private let lock = NSLock()
    private var values: [Key: Data] = [:]
    private var recordedCalls: [Call] = []
    private var nextErrors: [Operation: RivetDeviceAppleKeychainClientError] = [:]

    var calls: [Call] {
        lock.withLock { recordedCalls }
    }

    func failNext(
        _ operation: Operation,
        with error: RivetDeviceAppleKeychainClientError
    ) {
        lock.withLock { nextErrors[operation] = error }
    }

    func seed(service: String, account: String, value: Data) {
        lock.withLock { values[Key(service: service, account: account)] = value }
    }

    func value(service: String, account: String) -> Data? {
        lock.withLock { values[Key(service: service, account: account)] }
    }

    func add(
        _ item: RivetDeviceAppleKeychainItem,
        namespace: RivetDeviceAppleKeychainNamespace
    ) throws {
        try lock.withLock {
            try record(.add, account: item.account, namespace: namespace)
            let key = Key(service: namespace.service, account: item.account)
            guard values[key] == nil else {
                throw RivetDeviceAppleKeychainClientError.duplicateItem
            }
            values[key] = item.value
        }
    }

    func update(
        _ item: RivetDeviceAppleKeychainItem,
        namespace: RivetDeviceAppleKeychainNamespace
    ) throws {
        try lock.withLock {
            try record(.update, account: item.account, namespace: namespace)
            let key = Key(service: namespace.service, account: item.account)
            guard values[key] != nil else {
                throw RivetDeviceAppleKeychainClientError.itemNotFound
            }
            values[key] = item.value
        }
    }

    func load(
        account: String,
        namespace: RivetDeviceAppleKeychainNamespace
    ) throws -> Data? {
        try lock.withLock {
            try record(.load, account: account, namespace: namespace)
            return values[Key(service: namespace.service, account: account)]
        }
    }

    func list(
        namespace: RivetDeviceAppleKeychainNamespace
    ) throws -> [RivetDeviceAppleKeychainItem] {
        try lock.withLock {
            try record(.list, account: nil, namespace: namespace)
            return values.compactMap { key, value in
                guard key.service == namespace.service else {
                    return nil
                }
                return RivetDeviceAppleKeychainItem(account: key.account, value: value)
            }
        }
    }

    func remove(
        account: String,
        namespace: RivetDeviceAppleKeychainNamespace
    ) throws {
        try lock.withLock {
            try record(.remove, account: account, namespace: namespace)
            guard values.removeValue(
                forKey: Key(service: namespace.service, account: account)
            ) != nil else {
                throw RivetDeviceAppleKeychainClientError.itemNotFound
            }
        }
    }

    private func record(
        _ operation: Operation,
        account: String?,
        namespace: RivetDeviceAppleKeychainNamespace
    ) throws {
        recordedCalls.append(Call(
            operation: operation,
            service: namespace.service,
            account: account,
            accessibility: namespace.accessibility,
            synchronizable: namespace.synchronizable
        ))
        if let error = nextErrors.removeValue(forKey: operation) {
            throw error
        }
    }
}

private struct TestEnvelope: Codable {
    let version: Int
    let device: RivetDevicePairedDevice
    let credential: Data
}

private let securityService = "dev.rivet.tests.device-pairing"
private let securityFingerprint = Data(repeating: 0xa1, count: rivetDeviceFingerprintSize)
private let securityCredential = Data(repeating: 0xb2, count: rivetDeviceCredentialSize)

private func makePairing(
    id: UUID = UUID(),
    name: String = "Test Phone",
    applicationID: String = "com.example.app",
    scopeNames: [String] = ["reader"],
    fingerprint: Data = securityFingerprint,
    credential: Data = securityCredential,
    createdAt: Date = Date(timeIntervalSince1970: 1_000),
    lastUsedAt: Date = Date(timeIntervalSince1970: 1_000)
) -> RivetDeviceStoredPairing {
    RivetDeviceStoredPairing(
        device: RivetDevicePairedDevice(
            id: id,
            applicationID: applicationID,
            name: name,
            scopeNames: scopeNames,
            serverFingerprint: fingerprint,
            createdAt: createdAt,
            lastUsedAt: lastUsedAt
        ),
        credential: credential
    )
}

private func encode(_ envelope: TestEnvelope) throws -> Data {
    try JSONEncoder().encode(envelope)
}

@Test func applePairingStoreAddsUpdatesLoadsListsAndRemoves() async throws {
    let client = MemoryKeychainClient()
    let store = try RivetDeviceApplePairingStore(
        service: securityService,
        client: client
    )
    let otherStore = try RivetDeviceApplePairingStore(
        service: "dev.rivet.tests.other",
        client: client
    )
    let deviceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let initial = makePairing(id: deviceID)

    try await store.save(initial)
    #expect(try await store.load(deviceID: deviceID) == initial)
    #expect(client.calls.prefix(2).map(\.operation) == [.update, .add])

    let updated = makePairing(
        id: deviceID,
        name: "Renamed Phone",
        credential: Data(repeating: 0xc3, count: rivetDeviceCredentialSize),
        lastUsedAt: Date(timeIntervalSince1970: 2_000)
    )
    try await store.save(updated)
    #expect(try await store.load(deviceID: deviceID) == updated)

    let other = makePairing(
        id: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
        name: "Other Phone"
    )
    try await otherStore.save(other)
    #expect(try await store.pairedDevices() == [updated.device])
    #expect(try await otherStore.pairedDevices() == [other.device])

    try await store.remove(deviceID: deviceID)
    try await store.remove(deviceID: deviceID)
    #expect(try await store.load(deviceID: deviceID) == nil)

    #expect(client.calls.allSatisfy {
        $0.accessibility == .afterFirstUnlockThisDeviceOnly && !$0.synchronizable
    })
    #expect(client.calls.filter { $0.operation == .update }.count >= 2)
}

@Test func applePairingStoreRejectsMalformedAndVersionedEnvelopes() async throws {
    let client = MemoryKeychainClient()
    let store = try RivetDeviceApplePairingStore(
        service: securityService,
        client: client
    )
    let deviceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let account = deviceID.uuidString.lowercased()
    let pairing = makePairing(id: deviceID)

    client.seed(service: securityService, account: account, value: Data("not-json".utf8))
    await #expect(throws: RivetDeviceAppleSecurityError.malformedEnvelope) {
        try await store.load(deviceID: deviceID)
    }

    client.seed(
        service: securityService,
        account: account,
        value: try encode(TestEnvelope(
            version: 2,
            device: pairing.device,
            credential: pairing.credential
        ))
    )
    await #expect(throws: RivetDeviceAppleSecurityError.unsupportedEnvelopeVersion) {
        try await store.load(deviceID: deviceID)
    }

    let wrongFingerprint = makePairing(id: deviceID, fingerprint: Data())
    client.seed(
        service: securityService,
        account: account,
        value: try encode(TestEnvelope(
            version: 1,
            device: wrongFingerprint.device,
            credential: wrongFingerprint.credential
        ))
    )
    await #expect(throws: RivetDeviceAppleSecurityError.invalidFingerprintLength) {
        try await store.load(deviceID: deviceID)
    }

    let wrongCredential = makePairing(id: deviceID, credential: Data())
    client.seed(
        service: securityService,
        account: account,
        value: try encode(TestEnvelope(
            version: 1,
            device: wrongCredential.device,
            credential: wrongCredential.credential
        ))
    )
    await #expect(throws: RivetDeviceAppleSecurityError.invalidCredentialLength) {
        try await store.load(deviceID: deviceID)
    }

    let invalidMetadata = makePairing(id: deviceID, applicationID: "bad application id")
    client.seed(
        service: securityService,
        account: account,
        value: try encode(TestEnvelope(
            version: 1,
            device: invalidMetadata.device,
            credential: invalidMetadata.credential
        ))
    )
    await #expect(throws: RivetDeviceAppleSecurityError.invalidMetadata) {
        try await store.load(deviceID: deviceID)
    }

    let otherID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    client.seed(
        service: securityService,
        account: account,
        value: try encode(TestEnvelope(
            version: 1,
            device: makePairing(id: otherID).device,
            credential: securityCredential
        ))
    )
    await #expect(throws: RivetDeviceAppleSecurityError.accountMismatch) {
        try await store.load(deviceID: deviceID)
    }
}

@Test func applePairingStoreMapsSecurityErrorsWithoutSecrets() async throws {
    #expect(RivetDeviceSystemKeychainClient.clientError(for: errSecSuccess) == nil)
    #expect(
        RivetDeviceSystemKeychainClient.clientError(for: errSecDuplicateItem)
            == .duplicateItem
    )
    #expect(
        RivetDeviceSystemKeychainClient.clientError(for: errSecInteractionNotAllowed)
            == .interactionNotAllowed
    )
    #expect(
        RivetDeviceSystemKeychainClient.clientError(for: errSecMissingEntitlement)
            == .missingEntitlement
    )
    #expect(
        RivetDeviceSystemKeychainClient.clientError(for: -9999)
            == .unexpectedStatus(-9999)
    )

    let client = MemoryKeychainClient()
    let store = try RivetDeviceApplePairingStore(
        service: securityService,
        client: client
    )
    client.failNext(.update, with: .interactionNotAllowed)
    await #expect(
        throws: RivetDeviceAppleSecurityError.keychain(.interactionNotAllowed)
    ) {
        try await store.save(makePairing(name: "Never log this device"))
    }

    let secretFragments = ["Never log this device", "b2b2b2b2", securityService]
    let errors: [RivetDeviceAppleSecurityError] = [
        .invalidService,
        .malformedAccount,
        .accountMismatch,
        .malformedEnvelope,
        .unsupportedEnvelopeVersion,
        .invalidMetadata,
        .invalidFingerprintLength,
        .invalidCredentialLength,
        .duplicateAccount,
        .keychain(.interactionNotAllowed),
        .keychain(.unexpectedStatus(-9999))
    ]
    for error in errors {
        for secret in secretFragments {
            #expect(!error.description.contains(secret))
        }
    }
}

@Test func applePairingStoreValidatesWritesAndServiceNames() async throws {
    #expect(throws: RivetDeviceAppleSecurityError.invalidService) {
        try RivetDeviceApplePairingStore(service: " invalid ")
    }
    let client = MemoryKeychainClient()
    let store = try RivetDeviceApplePairingStore(
        service: securityService,
        client: client
    )
    await #expect(throws: RivetDeviceAppleSecurityError.invalidCredentialLength) {
        try await store.save(makePairing(credential: Data()))
    }
    await #expect(throws: RivetDeviceAppleSecurityError.invalidFingerprintLength) {
        try await store.save(makePairing(fingerprint: Data()))
    }
    await #expect(throws: RivetDeviceAppleSecurityError.invalidMetadata) {
        try await store.save(makePairing(scopeNames: ["reader", "reader"]))
    }
    #expect(client.calls.isEmpty)
}
