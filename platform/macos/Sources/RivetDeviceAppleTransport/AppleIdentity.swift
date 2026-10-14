import Foundation
import Network
import RivetDevice
import Security

public enum RivetDeviceAppleIdentityError: Error, Sendable, Equatable,
    CustomStringConvertible {
    case invalidApplicationID
    case invalidIdentity
    case keychainUnavailable
    case keychainInteractionNotAllowed
    case keychainMissingEntitlement
    case cryptographicFailure

    public var description: String {
        switch self {
        case .invalidApplicationID:
            "invalid Rivet device application identity"
        case .invalidIdentity:
            "invalid Rivet device TLS identity"
        case .keychainUnavailable:
            "Rivet device identity Keychain is unavailable"
        case .keychainInteractionNotAllowed:
            "Rivet device identity Keychain interaction is not allowed"
        case .keychainMissingEntitlement:
            "Rivet device identity Keychain entitlement is missing"
        case .cryptographicFailure:
            "Rivet device TLS identity generation failed"
        }
    }
}

/// A per-install server identity prepared for Network.framework. The private
/// key is never exported through this value; only its public SPKI fingerprint
/// is visible to pairing and diagnostics code.
public struct RivetDeviceAppleServerIdentity: @unchecked Sendable {
    public let fingerprint: Data
    package let parameters: NWParameters

    package init(parameters: NWParameters, fingerprint: Data) throws {
        guard fingerprint.count == rivetDeviceFingerprintSize else {
            throw RivetDeviceAppleIdentityError.invalidIdentity
        }
        self.parameters = parameters
        self.fingerprint = fingerprint
    }
}

package protocol RivetDeviceAppleIdentityClient: Sendable {
    func load(label: String) throws -> RivetDeviceAppleServerIdentity?
    func create(label: String, now: Date) throws -> RivetDeviceAppleServerIdentity
    func remove(label: String) throws
}

/// Serializes load/create/rotation so concurrent enable requests cannot mint
/// different identities for one application install.
public final class RivetDeviceAppleIdentityStore: @unchecked Sendable {
    private let label: String
    private let client: any RivetDeviceAppleIdentityClient
    private let now: @Sendable () -> Date
    private let lock = NSLock()

    public convenience init(applicationID: String) throws {
        try self.init(
            applicationID: applicationID,
            client: RivetDeviceSystemIdentityClient(),
            now: Date.init
        )
    }

    package init(
        applicationID: String,
        client: any RivetDeviceAppleIdentityClient,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        guard Self.isValidApplicationID(applicationID) else {
            throw RivetDeviceAppleIdentityError.invalidApplicationID
        }
        label = "dev.rivet.device.identity.\(applicationID)"
        self.client = client
        self.now = now
    }

    public func loadOrCreate() throws -> RivetDeviceAppleServerIdentity {
        try lock.withLock {
            if let identity = try client.load(label: label) {
                return identity
            }
            return try client.create(label: label, now: now())
        }
    }

    /// Rotation is deliberately explicit because every stored pin becomes
    /// invalid and all devices must pair again.
    public func rotate() throws -> RivetDeviceAppleServerIdentity {
        try lock.withLock {
            try client.remove(label: label)
            return try client.create(label: label, now: now())
        }
    }

    private static func isValidApplicationID(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 128
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0)
                    || ".-_".unicodeScalars.contains($0)
            }
    }
}

package struct RivetDeviceSystemIdentityClient: RivetDeviceAppleIdentityClient {
    package init() {}

    package func load(
        label: String
    ) throws -> RivetDeviceAppleServerIdentity? {
        var certificateResult: CFTypeRef?
        let certificateStatus = SecItemCopyMatching([
            kSecClass: kSecClassCertificate,
            kSecAttrLabel: label,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnRef: kCFBooleanTrue!
        ] as CFDictionary, &certificateResult)
        if certificateStatus == errSecItemNotFound {
            // Repair an interrupted creation that left only its private key.
            try remove(label: label)
            return nil
        }
        try mapStatus(certificateStatus)
        guard let certificateResult,
              CFGetTypeID(certificateResult) == SecCertificateGetTypeID() else {
            throw RivetDeviceAppleIdentityError.invalidIdentity
        }
        let certificate = unsafeDowncast(
            certificateResult,
            to: SecCertificate.self
        )

        var keyResult: CFTypeRef?
        let keyStatus = SecItemCopyMatching([
            kSecClass: kSecClassKey,
            kSecAttrApplicationTag: Data(label.utf8),
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnRef: kCFBooleanTrue!
        ] as CFDictionary, &keyResult)
        if keyStatus == errSecItemNotFound {
            try remove(label: label)
            return nil
        }
        try mapStatus(keyStatus)
        guard let keyResult,
              CFGetTypeID(keyResult) == SecKeyGetTypeID() else {
            throw RivetDeviceAppleIdentityError.invalidIdentity
        }
        let privateKey = unsafeDowncast(keyResult, to: SecKey.self)
        guard let identity = SecIdentityCreate(nil, certificate, privateKey) else {
            throw RivetDeviceAppleIdentityError.invalidIdentity
        }
        return try prepare(identity)
    }

    package func create(
        label: String,
        now: Date
    ) throws -> RivetDeviceAppleServerIdentity {
        let tag = Data(label.utf8)
        var keyError: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecAttrLabel: label,
            kSecPrivateKeyAttrs: [
                kSecAttrIsPermanent: true,
                kSecAttrApplicationTag: tag,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                kSecAttrSynchronizable: false
            ]
        ]
        guard let privateKey = SecKeyCreateRandomKey(
            attributes as CFDictionary,
            &keyError
        ) else {
            throw mapCFError(keyError?.takeRetainedValue())
        }

        do {
            guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
                throw RivetDeviceAppleIdentityError.cryptographicFailure
            }
            var exportError: Unmanaged<CFError>?
            guard let publicBytes = SecKeyCopyExternalRepresentation(
                publicKey,
                &exportError
            ) as Data? else {
                throw mapCFError(exportError?.takeRetainedValue())
            }
            let serial = try secureRandom(count: 16)
            let certificateDER = try RivetDeviceAppleCertificateBuilder.make(
                commonName: label,
                publicKey: publicBytes,
                serial: serial,
                notBefore: now.addingTimeInterval(-300),
                notAfter: now.addingTimeInterval(10 * 365 * 24 * 60 * 60)
            ) { bytes in
                var signatureError: Unmanaged<CFError>?
                guard let signature = SecKeyCreateSignature(
                    privateKey,
                    .ecdsaSignatureMessageX962SHA256,
                    bytes as CFData,
                    &signatureError
                ) as Data? else {
                    throw mapCFError(signatureError?.takeRetainedValue())
                }
                return signature
            }
            guard let certificate = SecCertificateCreateWithData(
                nil,
                certificateDER as CFData
            ) else {
                throw RivetDeviceAppleIdentityError.invalidIdentity
            }
            try mapStatus(SecItemAdd([
                kSecClass: kSecClassCertificate,
                kSecAttrLabel: label,
                kSecValueRef: certificate
            ] as CFDictionary, nil))

            guard let identity = SecIdentityCreate(
                nil,
                certificate,
                privateKey
            ) else {
                throw RivetDeviceAppleIdentityError.invalidIdentity
            }
            return try prepare(identity)
        } catch {
            try? remove(label: label)
            throw error
        }
    }

    package func remove(label: String) throws {
        let certificateStatus = SecItemDelete([
            kSecClass: kSecClassCertificate,
            kSecAttrLabel: label
        ] as CFDictionary)
        if certificateStatus != errSecItemNotFound {
            try mapStatus(certificateStatus)
        }
        let keyStatus = SecItemDelete([
            kSecClass: kSecClassKey,
            kSecAttrApplicationTag: Data(label.utf8),
            kSecAttrKeyClass: kSecAttrKeyClassPrivate
        ] as CFDictionary)
        if keyStatus != errSecItemNotFound {
            try mapStatus(keyStatus)
        }
    }

    private func prepare(
        _ identity: SecIdentity
    ) throws -> RivetDeviceAppleServerIdentity {
        try RivetDeviceAppleServerIdentity(
            parameters: RivetDeviceAppleTLS.serverParameters(identity: identity),
            fingerprint: RivetDeviceAppleTLS.serverFingerprint(identity: identity)
        )
    }

    private func secureRandom(count: Int) throws -> Data {
        var value = Data(count: count)
        let status = value.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw RivetDeviceAppleIdentityError.cryptographicFailure
        }
        return value
    }

    private func mapStatus(_ status: OSStatus) throws {
        guard status != errSecSuccess else {
            return
        }
        switch status {
        case errSecInteractionNotAllowed:
            throw RivetDeviceAppleIdentityError.keychainInteractionNotAllowed
        case errSecMissingEntitlement:
            throw RivetDeviceAppleIdentityError.keychainMissingEntitlement
        case errSecNotAvailable:
            throw RivetDeviceAppleIdentityError.keychainUnavailable
        default:
            throw RivetDeviceAppleIdentityError.cryptographicFailure
        }
    }

    private func mapCFError(_ error: CFError?) -> RivetDeviceAppleIdentityError {
        guard let error else {
            return .cryptographicFailure
        }
        let code = CFErrorGetCode(error)
        switch OSStatus(code) {
        case errSecInteractionNotAllowed:
            return .keychainInteractionNotAllowed
        case errSecMissingEntitlement:
            return .keychainMissingEntitlement
        case errSecNotAvailable:
            return .keychainUnavailable
        default:
            return .cryptographicFailure
        }
    }
}

package enum RivetDeviceAppleCertificateBuilder {
    package static func make(
        commonName: String,
        publicKey: Data,
        serial: Data,
        notBefore: Date,
        notAfter: Date,
        sign: (Data) throws -> Data
    ) throws -> Data {
        guard !commonName.isEmpty,
              commonName.utf8.count <= 255,
              publicKey.count == 65,
              publicKey.first == 0x04,
              !serial.isEmpty,
              serial.count <= 20,
              notBefore < notAfter else {
            throw RivetDeviceAppleIdentityError.invalidIdentity
        }

        let signatureAlgorithm = sequence(oid([
            0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02
        ]))
        let name = sequence(set(sequence(
            oid([0x55, 0x04, 0x03]),
            element(tag: 0x0c, content: Data(commonName.utf8))
        )))
        let publicKeyAlgorithm = sequence(
            oid([0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01]),
            oid([0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07])
        )
        let subjectPublicKeyInfo = sequence(
            publicKeyAlgorithm,
            bitString(publicKey)
        )
        let validity = sequence(
            certificateTime(notBefore),
            certificateTime(notAfter)
        )
        let tbsCertificate = sequence(
            element(tag: 0xa0, content: integer(Data([2]))),
            integer(serial),
            signatureAlgorithm,
            name,
            validity,
            name,
            subjectPublicKeyInfo
        )
        let signature = try sign(tbsCertificate)
        guard !signature.isEmpty else {
            throw RivetDeviceAppleIdentityError.cryptographicFailure
        }
        return sequence(tbsCertificate, signatureAlgorithm, bitString(signature))
    }

    private static func certificateTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let year = formatter.calendar.component(.year, from: date)
        if (1950...2049).contains(year) {
            formatter.dateFormat = "yyMMddHHmmss'Z'"
            return element(tag: 0x17, content: Data(formatter.string(from: date).utf8))
        }
        formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        return element(tag: 0x18, content: Data(formatter.string(from: date).utf8))
    }

    private static func integer(_ bytes: Data) -> Data {
        var value = Data(bytes.drop(while: { $0 == 0 }))
        if value.isEmpty {
            value = Data([0])
        } else if value[0] & 0x80 != 0 {
            value.insert(0, at: 0)
        }
        return element(tag: 0x02, content: value)
    }

    private static func oid(_ bytes: [UInt8]) -> Data {
        element(tag: 0x06, content: Data(bytes))
    }

    private static func bitString(_ bytes: Data) -> Data {
        element(tag: 0x03, content: Data([0]) + bytes)
    }

    private static func set(_ children: Data...) -> Data {
        element(tag: 0x31, content: joined(children))
    }

    private static func sequence(_ children: Data...) -> Data {
        element(tag: 0x30, content: joined(children))
    }

    private static func joined(_ values: [Data]) -> Data {
        values.reduce(into: Data()) { $0.append($1) }
    }

    private static func element(tag: UInt8, content: Data) -> Data {
        Data([tag]) + length(content.count) + content
    }

    private static func length(_ value: Int) -> Data {
        precondition(value >= 0)
        if value < 128 {
            return Data([UInt8(value)])
        }
        var remaining = value
        var bytes: [UInt8] = []
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xff), at: 0)
            remaining >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
}
