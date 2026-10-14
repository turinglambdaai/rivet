import Foundation
import Network
import RivetDevice
import Security

public let rivetDeviceAppleApplicationProtocol = "rivet-device/1"
public let rivetDeviceAppleConnectionTimeout: TimeInterval = 30

public enum RivetDeviceAppleServerAuthentication: Sendable, Equatable {
    /// Normal reconnect and QR pairing require the exact server SPKI pin.
    case pinned(Data)
    /// Manual foreground pairing accepts one provisional identity so both
    /// screens can compare a code derived from the observed SPKI fingerprint.
    case provisionalPairing
}

public struct RivetDeviceAppleTLSObservation: Sendable, Equatable {
    public let applicationProtocol: String
    public let protocolVersion: UInt16
    public let cipherSuite: UInt16
    public let serverFingerprint: Data?

    public init(
        applicationProtocol: String,
        protocolVersion: UInt16,
        cipherSuite: UInt16,
        serverFingerprint: Data?
    ) {
        self.applicationProtocol = applicationProtocol
        self.protocolVersion = protocolVersion
        self.cipherSuite = cipherSuite
        self.serverFingerprint = serverFingerprint
    }
}

public enum RivetDeviceAppleTransportError: Error, Sendable, Equatable,
    CustomStringConvertible {
    case invalidConfiguration
    case certificateUnavailable
    case serverPinMismatch
    case tlsNegotiationFailed
    case applicationProtocolMismatch
    case connectionTimedOut
    case connectionFailed
    case connectionClosed
    case concurrentRead
    case invalidReceiveLength
    case invalidPhase

    public var description: String {
        switch self {
        case .invalidConfiguration:
            "invalid Apple device transport configuration"
        case .certificateUnavailable:
            "TLS peer certificate is unavailable"
        case .serverPinMismatch:
            "TLS server identity does not match its pin"
        case .tlsNegotiationFailed:
            "TLS negotiation did not satisfy the Rivet policy"
        case .applicationProtocolMismatch:
            "TLS did not negotiate rivet-device/1"
        case .connectionTimedOut:
            "Rivet device connection timed out"
        case .connectionFailed:
            "Rivet device connection failed"
        case .connectionClosed:
            "Rivet device connection closed"
        case .concurrentRead:
            "Rivet device connection permits only one active read"
        case .invalidReceiveLength:
            "invalid Rivet device receive length"
        case .invalidPhase:
            "Rivet device connection is in the wrong protocol phase"
        }
    }
}

/// Single-use client TLS policy and its verified peer fingerprint. A dedicated
/// context prevents concurrent connections from confusing pin observations.
public final class RivetDeviceAppleClientTLSContext: @unchecked Sendable {
    private let parameters: NWParameters
    private let verifier: PeerVerifier
    private let lock = NSLock()
    private var claimed = false

    public init(
        authentication: RivetDeviceAppleServerAuthentication,
        verificationQueue: DispatchQueue = DispatchQueue(
            label: "dev.rivet.device-tls-verification"
        )
    ) throws {
        if case .pinned(let fingerprint) = authentication,
           fingerprint.count != rivetDeviceFingerprintSize {
            throw RivetDeviceAppleTransportError.invalidConfiguration
        }
        verifier = PeerVerifier(authentication: authentication)
        let tls = NWProtocolTLS.Options()
        configureBaseTLS(tls.securityProtocolOptions)
        let verifier = self.verifier
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions,
            { _, trust, complete in
                complete(verifier.verify(trust))
            },
            verificationQueue
        )
        parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }

    public var verifiedServerFingerprint: Data? {
        verifier.fingerprint
    }

    package func claimParameters() throws -> NWParameters {
        try lock.withLock {
            guard !claimed else {
                throw RivetDeviceAppleTransportError.invalidConfiguration
            }
            claimed = true
            return parameters
        }
    }

    package var verificationError: RivetDeviceAppleTransportError? {
        verifier.failure
    }
}

public enum RivetDeviceAppleTLS {
    public static func serverFingerprint(
        identity: SecIdentity
    ) throws -> Data {
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let certificate else {
            throw RivetDeviceAppleTransportError.certificateUnavailable
        }
        return try RivetDeviceAppleSPKI.fingerprint(
            certificateDER: SecCertificateCopyData(certificate) as Data
        )
    }

    /// Configures a TLS server endpoint. Identity creation and listener
    /// lifecycle are intentionally separate responsibilities.
    public static func serverParameters(identity: SecIdentity) throws -> NWParameters {
        guard let protocolIdentity = sec_identity_create(identity) else {
            throw RivetDeviceAppleTransportError.invalidConfiguration
        }
        let tls = NWProtocolTLS.Options()
        configureBaseTLS(tls.securityProtocolOptions)
        sec_protocol_options_set_local_identity(
            tls.securityProtocolOptions,
            protocolIdentity
        )
        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }

    public static func observation(
        for connection: NWConnection,
        serverFingerprint: Data?
    ) throws -> RivetDeviceAppleTLSObservation {
        guard let metadata = connection.metadata(
            definition: NWProtocolTLS.definition
        ) as? NWProtocolTLS.Metadata else {
            throw RivetDeviceAppleTransportError.tlsNegotiationFailed
        }
        let securityMetadata = metadata.securityProtocolMetadata
        guard let protocolPointer = sec_protocol_metadata_get_negotiated_protocol(
            securityMetadata
        ) else {
            throw RivetDeviceAppleTransportError.applicationProtocolMismatch
        }
        let applicationProtocol = String(cString: protocolPointer)
        guard applicationProtocol == rivetDeviceAppleApplicationProtocol else {
            throw RivetDeviceAppleTransportError.applicationProtocolMismatch
        }
        let version = sec_protocol_metadata_get_negotiated_tls_protocol_version(
            securityMetadata
        )
        guard version.rawValue >= tls_protocol_version_t.TLSv12.rawValue else {
            throw RivetDeviceAppleTransportError.tlsNegotiationFailed
        }
        let cipherSuite = sec_protocol_metadata_get_negotiated_tls_ciphersuite(
            securityMetadata
        )
        guard acceptsCipherSuite(cipherSuite.rawValue) else {
            throw RivetDeviceAppleTransportError.tlsNegotiationFailed
        }
        return RivetDeviceAppleTLSObservation(
            applicationProtocol: applicationProtocol,
            protocolVersion: version.rawValue,
            cipherSuite: cipherSuite.rawValue,
            serverFingerprint: serverFingerprint
        )
    }

    package static func acceptsCipherSuite(_ rawValue: UInt16) -> Bool {
        allowedCipherSuites.contains { $0.rawValue == rawValue }
    }
}

private func configureBaseTLS(_ options: sec_protocol_options_t) {
    sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
    for cipherSuite in allowedCipherSuites {
        sec_protocol_options_append_tls_ciphersuite(options, cipherSuite)
    }
    sec_protocol_options_add_tls_application_protocol(
        options,
        rivetDeviceAppleApplicationProtocol
    )
}

/// TLS 1.3 always provides forward secrecy. The TLS 1.2 entries explicitly
/// require ephemeral ECDH and an AEAD cipher, for both RSA and ECDSA identities.
private let allowedCipherSuites: [tls_ciphersuite_t] = [
    .AES_128_GCM_SHA256,
    .AES_256_GCM_SHA384,
    .CHACHA20_POLY1305_SHA256,
    .ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
    .ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
    .ECDHE_RSA_WITH_AES_128_GCM_SHA256,
    .ECDHE_RSA_WITH_AES_256_GCM_SHA384,
    .ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256,
    .ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256
]

private final class PeerVerifier: @unchecked Sendable {
    private let authentication: RivetDeviceAppleServerAuthentication
    private let lock = NSLock()
    private var storedFingerprint: Data?
    private var storedFailure: RivetDeviceAppleTransportError?

    init(authentication: RivetDeviceAppleServerAuthentication) {
        self.authentication = authentication
    }

    var fingerprint: Data? {
        lock.withLock { storedFingerprint }
    }

    var failure: RivetDeviceAppleTransportError? {
        lock.withLock { storedFailure }
    }

    func verify(_ protocolTrust: sec_trust_t) -> Bool {
        let trust = sec_trust_copy_ref(protocolTrust).takeRetainedValue()
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            recordFailure(.certificateUnavailable)
            return false
        }
        let certificateDER = SecCertificateCopyData(leaf) as Data
        guard let fingerprint = try? RivetDeviceAppleSPKI.fingerprint(
            certificateDER: certificateDER
        ) else {
            recordFailure(.certificateUnavailable)
            return false
        }
        let accepted: Bool
        switch authentication {
        case .pinned(let expected):
            accepted = constantTimeEqual(fingerprint, expected)
        case .provisionalPairing:
            accepted = true
        }
        guard accepted else {
            recordFailure(.serverPinMismatch)
            return false
        }
        lock.withLock {
            storedFingerprint = fingerprint
            storedFailure = nil
        }
        return true
    }

    private func recordFailure(_ error: RivetDeviceAppleTransportError) {
        lock.withLock {
            storedFingerprint = nil
            storedFailure = error
        }
    }
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
