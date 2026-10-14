import Foundation
import RivetDevice
import Security

package enum RivetDeviceAppleKeychainAccessibility: Sendable, Equatable {
    case afterFirstUnlockThisDeviceOnly
}

package struct RivetDeviceAppleKeychainNamespace: Sendable, Equatable {
    package let service: String
    package let accessibility: RivetDeviceAppleKeychainAccessibility
    package let synchronizable: Bool

    package init(service: String) {
        self.service = service
        self.accessibility = .afterFirstUnlockThisDeviceOnly
        self.synchronizable = false
    }
}

/// A credential-bearing value used only at the Keychain adapter boundary.
/// Implementations and tests must not log or surface `value`.
package struct RivetDeviceAppleKeychainItem: Sendable, Equatable {
    package let account: String
    package let value: Data

    package init(account: String, value: Data) {
        self.account = account
        self.value = value
    }
}

public enum RivetDeviceAppleKeychainClientError: Error, Sendable, Equatable {
    case duplicateItem
    case itemNotFound
    case interactionNotAllowed
    case missingEntitlement
    case authenticationFailed
    case unavailable
    case unexpectedStatus(Int32)
}

/// The narrow, injectable boundary around Security.framework. Its synchronous
/// operations are serialized by `RivetDeviceApplePairingStore`.
package protocol RivetDeviceAppleKeychainClient: Sendable {
    func add(
        _ item: RivetDeviceAppleKeychainItem,
        namespace: RivetDeviceAppleKeychainNamespace
    ) throws
    func update(
        _ item: RivetDeviceAppleKeychainItem,
        namespace: RivetDeviceAppleKeychainNamespace
    ) throws
    func load(
        account: String,
        namespace: RivetDeviceAppleKeychainNamespace
    ) throws -> Data?
    func list(
        namespace: RivetDeviceAppleKeychainNamespace
    ) throws -> [RivetDeviceAppleKeychainItem]
    func remove(
        account: String,
        namespace: RivetDeviceAppleKeychainNamespace
    ) throws
}

package struct RivetDeviceSystemKeychainClient: RivetDeviceAppleKeychainClient {
    package init() {}

    package func add(
        _ item: RivetDeviceAppleKeychainItem,
        namespace: RivetDeviceAppleKeychainNamespace
    ) throws {
        var query = baseQuery(namespace: namespace)
        query[kSecAttrAccount] = item.account
        query[kSecValueData] = item.value
        query[kSecAttrAccessible] = accessibilityValue(namespace.accessibility)
        try requireSuccess(SecItemAdd(query as CFDictionary, nil))
    }

    package func update(
        _ item: RivetDeviceAppleKeychainItem,
        namespace: RivetDeviceAppleKeychainNamespace
    ) throws {
        var query = baseQuery(namespace: namespace)
        query[kSecAttrAccount] = item.account
        let attributes: [CFString: Any] = [
            kSecValueData: item.value,
            kSecAttrAccessible: accessibilityValue(namespace.accessibility)
        ]
        try requireSuccess(SecItemUpdate(
            query as CFDictionary,
            attributes as CFDictionary
        ))
    }

    package func load(
        account: String,
        namespace: RivetDeviceAppleKeychainNamespace
    ) throws -> Data? {
        var query = baseQuery(namespace: namespace)
        query[kSecAttrAccount] = account
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecReturnData] = kCFBooleanTrue
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        try requireSuccess(status)
        guard let data = result as? Data else {
            throw RivetDeviceAppleKeychainClientError.unexpectedStatus(errSecDecode)
        }
        return data
    }

    package func list(
        namespace: RivetDeviceAppleKeychainNamespace
    ) throws -> [RivetDeviceAppleKeychainItem] {
        var query = baseQuery(namespace: namespace)
        query[kSecMatchLimit] = kSecMatchLimitAll
        query[kSecReturnAttributes] = kCFBooleanTrue
        query[kSecReturnData] = kCFBooleanTrue
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return []
        }
        try requireSuccess(status)
        let dictionaries: [[CFString: Any]]
        if let values = result as? [[CFString: Any]] {
            dictionaries = values
        } else if let value = result as? [CFString: Any] {
            dictionaries = [value]
        } else {
            throw RivetDeviceAppleKeychainClientError.unexpectedStatus(errSecDecode)
        }
        return try dictionaries.map { dictionary in
            guard let account = dictionary[kSecAttrAccount] as? String,
                  let value = dictionary[kSecValueData] as? Data else {
                throw RivetDeviceAppleKeychainClientError.unexpectedStatus(errSecDecode)
            }
            return RivetDeviceAppleKeychainItem(account: account, value: value)
        }
    }

    package func remove(
        account: String,
        namespace: RivetDeviceAppleKeychainNamespace
    ) throws {
        var query = baseQuery(namespace: namespace)
        query[kSecAttrAccount] = account
        let status = SecItemDelete(query as CFDictionary)
        guard status != errSecItemNotFound else {
            return
        }
        try requireSuccess(status)
    }

    package static func clientError(
        for status: OSStatus
    ) -> RivetDeviceAppleKeychainClientError? {
        switch status {
        case errSecSuccess:
            nil
        case errSecDuplicateItem:
            .duplicateItem
        case errSecItemNotFound:
            .itemNotFound
        case errSecInteractionNotAllowed:
            .interactionNotAllowed
        case errSecMissingEntitlement:
            .missingEntitlement
        case errSecAuthFailed:
            .authenticationFailed
        case errSecNotAvailable:
            .unavailable
        default:
            .unexpectedStatus(status)
        }
    }

    private func baseQuery(
        namespace: RivetDeviceAppleKeychainNamespace
    ) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: namespace.service,
            kSecAttrSynchronizable: namespace.synchronizable ? kCFBooleanTrue! : kCFBooleanFalse!
        ]
    }

    private func accessibilityValue(
        _ accessibility: RivetDeviceAppleKeychainAccessibility
    ) -> CFString {
        switch accessibility {
        case .afterFirstUnlockThisDeviceOnly:
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
    }

    private func requireSuccess(_ status: OSStatus) throws {
        if let error = Self.clientError(for: status) {
            throw error
        }
    }
}

public enum RivetDeviceAppleSecurityError: Error, Sendable, Equatable,
    CustomStringConvertible {
    case invalidService
    case malformedAccount
    case accountMismatch
    case malformedEnvelope
    case unsupportedEnvelopeVersion
    case invalidMetadata
    case invalidFingerprintLength
    case invalidCredentialLength
    case duplicateAccount
    case keychain(RivetDeviceAppleKeychainClientError)

    public var description: String {
        switch self {
        case .invalidService:
            "invalid Rivet device Keychain service"
        case .malformedAccount:
            "invalid Rivet device Keychain account"
        case .accountMismatch:
            "Rivet device Keychain account does not match its envelope"
        case .malformedEnvelope:
            "malformed Rivet device Keychain envelope"
        case .unsupportedEnvelopeVersion:
            "unsupported Rivet device Keychain envelope version"
        case .invalidMetadata:
            "invalid Rivet device pairing metadata"
        case .invalidFingerprintLength:
            "invalid Rivet device server fingerprint length"
        case .invalidCredentialLength:
            "invalid Rivet device credential length"
        case .duplicateAccount:
            "duplicate Rivet device Keychain account"
        case .keychain(let error):
            switch error {
            case .duplicateItem:
                "Rivet device Keychain item already exists"
            case .itemNotFound:
                "Rivet device Keychain item was not found"
            case .interactionNotAllowed:
                "Rivet device Keychain interaction is not allowed"
            case .missingEntitlement:
                "Rivet device Keychain entitlement is missing"
            case .authenticationFailed:
                "Rivet device Keychain authentication failed"
            case .unavailable:
                "Rivet device Keychain is unavailable"
            case .unexpectedStatus:
                "Rivet device Keychain operation failed"
            }
        }
    }
}

private struct RivetDeviceApplePairingEnvelope: Codable {
    static let currentVersion = 1

    let version: Int
    let device: RivetDevicePairedDevice
    let credential: Data
}

/// Security.framework-backed storage for a desktop or mobile pairing. Each
/// UUID account contains one versioned envelope and is isolated by `service`.
public actor RivetDeviceApplePairingStore: RivetDevicePairingStore {
    private let namespace: RivetDeviceAppleKeychainNamespace
    private let client: any RivetDeviceAppleKeychainClient
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(service: String) throws {
        try self.init(service: service, client: RivetDeviceSystemKeychainClient())
    }

    package init(
        service: String,
        client: any RivetDeviceAppleKeychainClient
    ) throws {
        guard Self.isValidService(service) else {
            throw RivetDeviceAppleSecurityError.invalidService
        }
        namespace = RivetDeviceAppleKeychainNamespace(service: service)
        self.client = client
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
    }

    public func save(_ pairing: RivetDeviceStoredPairing) async throws {
        try Self.validate(pairing)
        let envelope = RivetDeviceApplePairingEnvelope(
            version: RivetDeviceApplePairingEnvelope.currentVersion,
            device: pairing.device,
            credential: pairing.credential
        )
        let value: Data
        do {
            value = try encoder.encode(envelope)
        } catch {
            throw RivetDeviceAppleSecurityError.malformedEnvelope
        }
        let item = RivetDeviceAppleKeychainItem(
            account: Self.account(for: pairing.device.id),
            value: value
        )

        do {
            try client.update(item, namespace: namespace)
        } catch RivetDeviceAppleKeychainClientError.itemNotFound {
            do {
                try client.add(item, namespace: namespace)
            } catch RivetDeviceAppleKeychainClientError.duplicateItem {
                try mapClientError {
                    try client.update(item, namespace: namespace)
                }
            } catch {
                throw Self.map(error)
            }
        } catch {
            throw Self.map(error)
        }
    }

    public func load(deviceID: UUID) async throws -> RivetDeviceStoredPairing? {
        let account = Self.account(for: deviceID)
        let value: Data?
        do {
            value = try client.load(account: account, namespace: namespace)
        } catch {
            throw Self.map(error)
        }
        guard let value else {
            return nil
        }
        return try decode(value, expectedAccount: account)
    }

    public func pairedDevices() async throws -> [RivetDevicePairedDevice] {
        let items: [RivetDeviceAppleKeychainItem]
        do {
            items = try client.list(namespace: namespace)
        } catch {
            throw Self.map(error)
        }
        var seen = Set<UUID>()
        var devices: [RivetDevicePairedDevice] = []
        for item in items {
            let pairing = try decode(item.value, expectedAccount: item.account)
            guard seen.insert(pairing.device.id).inserted else {
                throw RivetDeviceAppleSecurityError.duplicateAccount
            }
            devices.append(pairing.device)
        }
        return devices.sorted { Self.account(for: $0.id) < Self.account(for: $1.id) }
    }

    public func remove(deviceID: UUID) async throws {
        do {
            try client.remove(
                account: Self.account(for: deviceID),
                namespace: namespace
            )
        } catch RivetDeviceAppleKeychainClientError.itemNotFound {
            return
        } catch {
            throw Self.map(error)
        }
    }

    private func decode(
        _ value: Data,
        expectedAccount: String
    ) throws -> RivetDeviceStoredPairing {
        let envelope: RivetDeviceApplePairingEnvelope
        do {
            envelope = try decoder.decode(RivetDeviceApplePairingEnvelope.self, from: value)
        } catch {
            throw RivetDeviceAppleSecurityError.malformedEnvelope
        }
        guard envelope.version == RivetDeviceApplePairingEnvelope.currentVersion else {
            throw RivetDeviceAppleSecurityError.unsupportedEnvelopeVersion
        }
        guard let accountID = UUID(uuidString: expectedAccount) else {
            throw RivetDeviceAppleSecurityError.malformedAccount
        }
        guard accountID == envelope.device.id else {
            throw RivetDeviceAppleSecurityError.accountMismatch
        }
        let pairing = RivetDeviceStoredPairing(
            device: envelope.device,
            credential: envelope.credential
        )
        try Self.validate(pairing)
        return pairing
    }

    private func mapClientError(_ body: () throws -> Void) throws {
        do {
            try body()
        } catch {
            throw Self.map(error)
        }
    }

    private static func map(_ error: Error) -> Error {
        if let error = error as? RivetDeviceAppleSecurityError {
            return error
        }
        if let error = error as? RivetDeviceAppleKeychainClientError {
            return RivetDeviceAppleSecurityError.keychain(error)
        }
        return RivetDeviceAppleSecurityError.keychain(.unexpectedStatus(errSecInternalError))
    }

    private static func account(for id: UUID) -> String {
        id.uuidString.lowercased()
    }

    private static func isValidService(_ service: String) -> Bool {
        !service.isEmpty
            && service.utf8.count <= 255
            && service == service.trimmingCharacters(in: .whitespacesAndNewlines)
            && !service.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func validate(_ pairing: RivetDeviceStoredPairing) throws {
        let device = pairing.device
        guard isValidDeviceAPIName(device.applicationID),
              isValidDeviceDisplayName(device.name),
              device.scopeNames.count <= 64,
              Set(device.scopeNames).count == device.scopeNames.count,
              device.scopeNames.allSatisfy(isValidDeviceAPIName),
              device.createdAt.timeIntervalSinceReferenceDate.isFinite,
              device.lastUsedAt.timeIntervalSinceReferenceDate.isFinite,
              device.lastUsedAt >= device.createdAt else {
            throw RivetDeviceAppleSecurityError.invalidMetadata
        }
        guard device.serverFingerprint.count == rivetDeviceFingerprintSize else {
            throw RivetDeviceAppleSecurityError.invalidFingerprintLength
        }
        guard pairing.credential.count == rivetDeviceCredentialSize else {
            throw RivetDeviceAppleSecurityError.invalidCredentialLength
        }
    }

}
