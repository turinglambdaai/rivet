import CryptoKit
import Foundation

public let rivetDevicePairingNonceSize = 32
public let rivetDeviceCredentialSize = 32
public let rivetDeviceFingerprintSize = 32
public let rivetDeviceDefaultPairingWindowDuration: TimeInterval = 5 * 60
public let rivetDeviceDefaultMaximumPairingFailures = 5

public protocol RivetDeviceRandomBytesGenerator: Sendable {
    func randomBytes(count: Int) async throws -> Data
}

public struct RivetDeviceSystemRandomBytesGenerator: RivetDeviceRandomBytesGenerator {
    public init() {}

    public func randomBytes(count: Int) async throws -> Data {
        precondition(count > 0, "Rivet device random byte count must be positive")
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in
            UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
        })
    }
}

/// Non-secret metadata for a paired device. The credential is deliberately
/// absent so device lists and diagnostics cannot accidentally expose it.
public struct RivetDevicePairedDevice: Codable, Equatable, Sendable {
    public let id: UUID
    public let applicationID: String
    public let name: String
    public let scopeNames: [String]
    public let serverFingerprint: Data
    public let createdAt: Date
    public let lastUsedAt: Date

    public init(
        id: UUID,
        applicationID: String,
        name: String,
        scopeNames: [String],
        serverFingerprint: Data,
        createdAt: Date,
        lastUsedAt: Date
    ) {
        self.id = id
        self.applicationID = applicationID
        self.name = name
        self.scopeNames = scopeNames
        self.serverFingerprint = serverFingerprint
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }
}

/// A credential-bearing value used only at the secure-storage boundary. Do
/// not log it or encode it into ordinary settings alongside device metadata.
public struct RivetDeviceStoredPairing: Equatable, Sendable {
    public let device: RivetDevicePairedDevice
    public let credential: Data

    public init(device: RivetDevicePairedDevice, credential: Data) {
        self.device = device
        self.credential = credential
    }
}

/// Implementations must persist `credential` in platform secure storage and
/// make `save` atomic from the caller's perspective.
public protocol RivetDevicePairingStore: Sendable {
    func save(_ pairing: RivetDeviceStoredPairing) async throws
    func load(deviceID: UUID) async throws -> RivetDeviceStoredPairing?
    func pairedDevices() async throws -> [RivetDevicePairedDevice]
    func remove(deviceID: UUID) async throws
}

public enum RivetDevicePairingError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidApplicationID
    case invalidFingerprintSize
    case invalidNonceSize
    case invalidDeviceName
    case invalidScopeName(String)
    case windowAlreadyOpen
    case windowUnavailable
    case windowExpired
    case attemptInProgress
    case attemptUnavailable
    case authenticationFailed

    public var description: String {
        switch self {
        case .invalidApplicationID:
            return "invalid Rivet device application id"
        case .invalidFingerprintSize:
            return "Rivet device server fingerprint must be 32 bytes"
        case .invalidNonceSize:
            return "Rivet device pairing nonce must be 32 bytes"
        case .invalidDeviceName:
            return "invalid Rivet device display name"
        case .invalidScopeName(let name):
            return "invalid Rivet device scope name: \(name)"
        case .windowAlreadyOpen:
            return "a Rivet device pairing window is already open"
        case .windowUnavailable:
            return "no Rivet device pairing window is open"
        case .windowExpired:
            return "the Rivet device pairing window expired"
        case .attemptInProgress:
            return "a Rivet device pairing attempt is already in progress"
        case .attemptUnavailable:
            return "the Rivet device pairing attempt is unavailable"
        case .authenticationFailed:
            return "Rivet device authentication failed"
        }
    }
}

public struct RivetDevicePairingWindow: Equatable, Sendable {
    public let id: UUID
    public let applicationID: String
    public let expiresAt: Date
    public let failedAttempts: Int
    public let maximumFailedAttempts: Int
    public let activeAttemptID: UUID?
}

public enum RivetDevicePairingCloseReason: Equatable, Sendable {
    case cancelled
    case expired
    case tooManyFailures
    case succeeded(deviceID: UUID)
}

public enum RivetDevicePairingStatus: Equatable, Sendable {
    case closed(lastReason: RivetDevicePairingCloseReason?)
    case open(RivetDevicePairingWindow)
}

public struct RivetDevicePairingChallenge: Equatable, Sendable {
    public let windowID: UUID
    public let attemptID: UUID
    public let serverNonce: Data
    public let verificationCode: String
    public let expiresAt: Date
}

public struct RivetDevicePairingResult: Equatable, Sendable {
    public let device: RivetDevicePairedDevice
    /// Send exactly once over the authenticated pairing channel, then discard.
    public let credential: Data
}

/// Defines the byte-exact transcript used by both pairing peers to display the
/// same six-digit short authentication string.
public enum RivetDevicePairingTranscript {
    public static func verificationCode(
        applicationID: String,
        serverFingerprint: Data,
        clientNonce: Data,
        serverNonce: Data
    ) throws -> String {
        guard isValidDeviceAPIName(applicationID) else {
            throw RivetDevicePairingError.invalidApplicationID
        }
        guard serverFingerprint.count == rivetDeviceFingerprintSize else {
            throw RivetDevicePairingError.invalidFingerprintSize
        }
        guard clientNonce.count == rivetDevicePairingNonceSize,
              serverNonce.count == rivetDevicePairingNonceSize else {
            throw RivetDevicePairingError.invalidNonceSize
        }

        var transcript = Data("rivet-device-pairing-v1".utf8)
        appendLengthPrefixed(Data(applicationID.utf8), to: &transcript)
        appendLengthPrefixed(serverFingerprint, to: &transcript)
        appendLengthPrefixed(clientNonce, to: &transcript)
        appendLengthPrefixed(serverNonce, to: &transcript)
        let digest = SHA256.hash(data: transcript)
        let prefix = digest.prefix(4).reduce(UInt32(0)) { value, byte in
            (value << 8) | UInt32(byte)
        }
        return String(format: "%06u", prefix % 1_000_000)
    }

    private static func appendLengthPrefixed(_ value: Data, to output: inout Data) {
        precondition(value.count <= Int(UInt32.max))
        var length = UInt32(value.count).bigEndian
        withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
        output.append(value)
    }
}

private struct RivetDevicePairingAttempt: Sendable {
    let id: UUID
    let deviceName: String
    let clientNonce: Data
    let serverNonce: Data
    var desktopScopeNames: [String]?
    var deviceConfirmed: Bool
    var finalizing: Bool
}

private struct RivetDeviceActivePairingWindow: Sendable {
    let id: UUID
    let applicationID: String
    let serverFingerprint: Data
    let expiresAt: Date
    var failedAttempts: Int
    var attemptStarting: Bool
    var attempt: RivetDevicePairingAttempt?
}

/// Transport-independent pairing state. The network adapter supplies TLS
/// identity material and timestamps. A credential is issued only after both
/// the desktop UI and the remote device confirm the same transcript.
public actor RivetDevicePairingCoordinator {
    private let store: any RivetDevicePairingStore
    private let random: any RivetDeviceRandomBytesGenerator
    private let windowDuration: TimeInterval
    private let maximumFailedAttempts: Int
    private var activeWindow: RivetDeviceActivePairingWindow?
    private var lastCloseReason: RivetDevicePairingCloseReason?

    public init(
        store: any RivetDevicePairingStore,
        random: any RivetDeviceRandomBytesGenerator = RivetDeviceSystemRandomBytesGenerator(),
        windowDuration: TimeInterval = rivetDeviceDefaultPairingWindowDuration,
        maximumFailedAttempts: Int = rivetDeviceDefaultMaximumPairingFailures
    ) {
        precondition(windowDuration > 0, "Rivet device pairing duration must be positive")
        precondition(
            maximumFailedAttempts > 0,
            "Rivet device pairing failure limit must be positive"
        )
        self.store = store
        self.random = random
        self.windowDuration = windowDuration
        self.maximumFailedAttempts = maximumFailedAttempts
    }

    @discardableResult
    public func openWindow(
        applicationID: String,
        serverFingerprint: Data,
        now: Date = Date()
    ) throws -> RivetDevicePairingWindow {
        expireIfNeeded(now: now)
        guard activeWindow == nil else {
            throw RivetDevicePairingError.windowAlreadyOpen
        }
        guard isValidDeviceAPIName(applicationID) else {
            throw RivetDevicePairingError.invalidApplicationID
        }
        guard serverFingerprint.count == rivetDeviceFingerprintSize else {
            throw RivetDevicePairingError.invalidFingerprintSize
        }

        activeWindow = RivetDeviceActivePairingWindow(
            id: UUID(),
            applicationID: applicationID,
            serverFingerprint: serverFingerprint,
            expiresAt: now.addingTimeInterval(windowDuration),
            failedAttempts: 0,
            attemptStarting: false,
            attempt: nil
        )
        lastCloseReason = nil
        return snapshot(activeWindow!)
    }

    public func beginAttempt(
        windowID: UUID,
        deviceName: String,
        clientNonce: Data,
        now: Date = Date()
    ) async throws -> RivetDevicePairingChallenge {
        try requireActiveWindow(id: windowID, now: now)
        guard isValidDeviceDisplayName(deviceName) else {
            throw RivetDevicePairingError.invalidDeviceName
        }
        guard clientNonce.count == rivetDevicePairingNonceSize else {
            throw RivetDevicePairingError.invalidNonceSize
        }
        guard var reservedWindow = activeWindow,
              !reservedWindow.attemptStarting,
              reservedWindow.attempt == nil else {
            throw RivetDevicePairingError.attemptInProgress
        }
        reservedWindow.attemptStarting = true
        activeWindow = reservedWindow

        let serverNonce: Data
        do {
            serverNonce = try await random.randomBytes(count: rivetDevicePairingNonceSize)
        } catch {
            clearAttemptReservation(windowID: windowID)
            throw error
        }
        guard serverNonce.count == rivetDevicePairingNonceSize else {
            clearAttemptReservation(windowID: windowID)
            throw RivetDevicePairingError.invalidNonceSize
        }
        guard var window = activeWindow,
              window.id == windowID,
              window.attemptStarting,
              window.attempt == nil else {
            throw RivetDevicePairingError.windowUnavailable
        }
        let attempt = RivetDevicePairingAttempt(
            id: UUID(),
            deviceName: deviceName,
            clientNonce: clientNonce,
            serverNonce: serverNonce,
            desktopScopeNames: nil,
            deviceConfirmed: false,
            finalizing: false
        )
        let code = try RivetDevicePairingTranscript.verificationCode(
            applicationID: window.applicationID,
            serverFingerprint: window.serverFingerprint,
            clientNonce: clientNonce,
            serverNonce: serverNonce
        )
        window.attemptStarting = false
        window.attempt = attempt
        activeWindow = window
        return RivetDevicePairingChallenge(
            windowID: window.id,
            attemptID: attempt.id,
            serverNonce: serverNonce,
            verificationCode: code,
            expiresAt: window.expiresAt
        )
    }

    public func failAttempt(
        windowID: UUID,
        attemptID: UUID,
        now: Date = Date()
    ) throws {
        try requireActiveWindow(id: windowID, now: now)
        guard var window = activeWindow,
              let attempt = window.attempt,
              attempt.id == attemptID else {
            throw RivetDevicePairingError.attemptUnavailable
        }
        guard !attempt.finalizing else {
            throw RivetDevicePairingError.attemptInProgress
        }
        window.attempt = nil
        window.failedAttempts += 1
        if window.failedAttempts >= maximumFailedAttempts {
            activeWindow = nil
            lastCloseReason = .tooManyFailures
        } else {
            activeWindow = window
        }
    }

    public func confirmOnDesktop(
        windowID: UUID,
        attemptID: UUID,
        grantedScopeNames: [String],
        now: Date = Date()
    ) async throws -> RivetDevicePairingResult? {
        try requireActiveWindow(id: windowID, now: now)
        let scopeNames = Array(Set(grantedScopeNames)).sorted()
        if let invalid = scopeNames.first(where: { !isValidDeviceAPIName($0) }) {
            throw RivetDevicePairingError.invalidScopeName(invalid)
        }
        guard var window = activeWindow,
              var attempt = window.attempt,
              attempt.id == attemptID else {
            throw RivetDevicePairingError.attemptUnavailable
        }
        guard !attempt.finalizing else {
            throw RivetDevicePairingError.attemptInProgress
        }
        if let existing = attempt.desktopScopeNames, existing != scopeNames {
            throw RivetDevicePairingError.attemptInProgress
        }
        attempt.desktopScopeNames = scopeNames
        window.attempt = attempt
        activeWindow = window
        return try await finalizeIfConfirmed(
            windowID: windowID,
            attemptID: attemptID,
            now: now
        )
    }

    public func confirmOnDevice(
        windowID: UUID,
        attemptID: UUID,
        now: Date = Date()
    ) async throws -> RivetDevicePairingResult? {
        try requireActiveWindow(id: windowID, now: now)
        guard var window = activeWindow,
              var attempt = window.attempt,
              attempt.id == attemptID else {
            throw RivetDevicePairingError.attemptUnavailable
        }
        guard !attempt.finalizing else {
            throw RivetDevicePairingError.attemptInProgress
        }
        attempt.deviceConfirmed = true
        window.attempt = attempt
        activeWindow = window
        return try await finalizeIfConfirmed(
            windowID: windowID,
            attemptID: attemptID,
            now: now
        )
    }

    public func cancelWindow(windowID: UUID) throws {
        guard let window = activeWindow, window.id == windowID else {
            throw RivetDevicePairingError.windowUnavailable
        }
        guard window.attempt?.finalizing != true else {
            throw RivetDevicePairingError.attemptInProgress
        }
        activeWindow = nil
        lastCloseReason = .cancelled
    }

    public func status(now: Date = Date()) -> RivetDevicePairingStatus {
        expireIfNeeded(now: now)
        guard let activeWindow else {
            return .closed(lastReason: lastCloseReason)
        }
        return .open(snapshot(activeWindow))
    }

    private func requireActiveWindow(id: UUID, now: Date) throws {
        let expiredID = activeWindow?.id
        expireIfNeeded(now: now)
        guard let activeWindow else {
            if expiredID == id, lastCloseReason == .expired {
                throw RivetDevicePairingError.windowExpired
            }
            throw RivetDevicePairingError.windowUnavailable
        }
        guard activeWindow.id == id else {
            throw RivetDevicePairingError.windowUnavailable
        }
    }

    private func expireIfNeeded(now: Date) {
        guard let activeWindow,
              activeWindow.attempt?.finalizing != true,
              now >= activeWindow.expiresAt else {
            return
        }
        self.activeWindow = nil
        lastCloseReason = .expired
    }

    private func snapshot(_ window: RivetDeviceActivePairingWindow) -> RivetDevicePairingWindow {
        RivetDevicePairingWindow(
            id: window.id,
            applicationID: window.applicationID,
            expiresAt: window.expiresAt,
            failedAttempts: window.failedAttempts,
            maximumFailedAttempts: maximumFailedAttempts,
            activeAttemptID: window.attempt?.id
        )
    }

    private func clearAttemptReservation(windowID: UUID) {
        guard var window = activeWindow, window.id == windowID else {
            return
        }
        window.attemptStarting = false
        activeWindow = window
    }

    private func finalizeIfConfirmed(
        windowID: UUID,
        attemptID: UUID,
        now: Date
    ) async throws -> RivetDevicePairingResult? {
        guard var window = activeWindow,
              window.id == windowID,
              var attempt = window.attempt,
              attempt.id == attemptID else {
            throw RivetDevicePairingError.attemptUnavailable
        }
        guard let scopeNames = attempt.desktopScopeNames,
              attempt.deviceConfirmed else {
            return nil
        }
        guard !attempt.finalizing else {
            throw RivetDevicePairingError.attemptInProgress
        }
        attempt.finalizing = true
        window.attempt = attempt
        activeWindow = window

        do {
            let credential = try await random.randomBytes(count: rivetDeviceCredentialSize)
            guard credential.count == rivetDeviceCredentialSize else {
                throw RivetDevicePairingError.authenticationFailed
            }
            let device = RivetDevicePairedDevice(
                id: UUID(),
                applicationID: window.applicationID,
                name: attempt.deviceName,
                scopeNames: scopeNames,
                serverFingerprint: window.serverFingerprint,
                createdAt: now,
                lastUsedAt: now
            )
            try await store.save(RivetDeviceStoredPairing(
                device: device,
                credential: credential
            ))
            activeWindow = nil
            lastCloseReason = .succeeded(deviceID: device.id)
            return RivetDevicePairingResult(device: device, credential: credential)
        } catch {
            if var currentWindow = activeWindow,
               currentWindow.id == windowID,
               var currentAttempt = currentWindow.attempt,
               currentAttempt.id == attemptID {
                currentAttempt.finalizing = false
                currentWindow.attempt = currentAttempt
                activeWindow = currentWindow
            }
            throw error
        }
    }
}

/// Authenticates reconnects without revealing whether a device ID, application
/// ID, fingerprint, or credential was the mismatched field.
public actor RivetDeviceSessionAuthenticator {
    private let store: any RivetDevicePairingStore
    private let sessionRevoker: (any RivetDeviceSessionRevoker)?

    public init(
        store: any RivetDevicePairingStore,
        sessionRevoker: (any RivetDeviceSessionRevoker)? = nil
    ) {
        self.store = store
        self.sessionRevoker = sessionRevoker
    }

    public func authenticate(
        deviceID: UUID,
        applicationID: String,
        serverFingerprint: Data,
        credential: Data,
        now: Date = Date()
    ) async throws -> RivetDevicePairedDevice {
        guard credential.count == rivetDeviceCredentialSize,
              serverFingerprint.count == rivetDeviceFingerprintSize,
              let stored = try await store.load(deviceID: deviceID),
              stored.device.applicationID == applicationID,
              constantTimeEqual(stored.device.serverFingerprint, serverFingerprint),
              constantTimeEqual(stored.credential, credential) else {
            throw RivetDevicePairingError.authenticationFailed
        }

        let updated = RivetDevicePairedDevice(
            id: stored.device.id,
            applicationID: stored.device.applicationID,
            name: stored.device.name,
            scopeNames: stored.device.scopeNames,
            serverFingerprint: stored.device.serverFingerprint,
            createdAt: stored.device.createdAt,
            lastUsedAt: max(now, stored.device.lastUsedAt)
        )
        try await store.save(RivetDeviceStoredPairing(device: updated, credential: stored.credential))
        return updated
    }

    public func revoke(deviceID: UUID) async throws {
        try await store.remove(deviceID: deviceID)
        await sessionRevoker?.revokeSessions(deviceID: deviceID)
    }

    public func revokeAll(applicationID: String) async throws {
        let deviceIDs = try await store.pairedDevices()
            .filter { $0.applicationID == applicationID }
            .map(\.id)
        for deviceID in deviceIDs {
            try await store.remove(deviceID: deviceID)
            await sessionRevoker?.revokeSessions(deviceID: deviceID)
        }
    }
}

package func isValidDeviceDisplayName(_ name: String) -> Bool {
    !name.isEmpty
        && name.utf8.count <= 128
        && name == name.trimmingCharacters(in: .whitespacesAndNewlines)
        && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
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
