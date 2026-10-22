import Foundation
import Network
import RivetDevice
import RivetDeviceAppleSecurity
import RivetDeviceAppleTransport
import RivetDeviceSession

public enum RivetDeviceAppleCompanionError: Error, Equatable, Sendable {
    case invalidConfiguration
    case staleSelection
    case pairingWindowClosed
    case sessionAlreadyActive
    case noActiveSession
    case pairingNotFound
    case applicationMismatch
    case pairingAlreadyExists
    case invalidPairing
    case invalidScopes
    case sessionNoLongerActive
}

public struct RivetDeviceAppleCompanionConfiguration: Equatable, Sendable {
    public let applicationID: String
    public let deviceName: String
    public let postTLSTimeout: TimeInterval
    public let pairingResponseTimeout: TimeInterval

    public init(
        applicationID: String,
        deviceName: String,
        postTLSTimeout: TimeInterval = rivetDeviceSessionPostTLSTimeout,
        pairingResponseTimeout: TimeInterval = rivetDeviceDefaultPairingWindowDuration
    ) throws {
        guard isValidDeviceAPIName(applicationID),
              isValidDeviceDisplayName(deviceName),
              postTLSTimeout.isFinite, postTLSTimeout > 0,
              pairingResponseTimeout.isFinite, pairingResponseTimeout > 0 else {
            throw RivetDeviceAppleCompanionError.invalidConfiguration
        }
        self.applicationID = applicationID
        self.deviceName = deviceName
        self.postTLSTimeout = postTLSTimeout
        self.pairingResponseTimeout = pairingResponseTimeout
    }
}

public enum RivetDeviceAppleCompanionConnectIntent: Equatable, Sendable {
    /// The caller must supply the pairing-window ID obtained through an
    /// explicit host-side pairing flow. A Bonjour hint alone is insufficient.
    case pair(windowID: UUID)
    /// Reconnect with a stored credential and its pinned server fingerprint.
    case reconnect(deviceID: UUID)
}

public enum RivetDeviceAppleCompanionEvent: Equatable, Sendable {
    case discovery(RivetDeviceAppleBonjourBrowserEvent)
    case pairingCode(RivetDeviceApplePairingCode)
    case connected(RivetDeviceSessionClientAcceptance)
    case sessionEnded
    case sessionFailed
}

public actor RivetDeviceApplePairingCredentialStoreAdapter:
    RivetDeviceAppleSessionCredentialStore {
    private let store: any RivetDevicePairingStore
    private let applicationID: String
    private let deviceName: String
    private let now: @Sendable () -> Date
    private var newlyPairedDevices = Set<UUID>()

    init(
        store: any RivetDevicePairingStore,
        applicationID: String,
        deviceName: String,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        guard isValidDeviceAPIName(applicationID),
              isValidDeviceDisplayName(deviceName) else {
            throw RivetDeviceAppleCompanionError.invalidConfiguration
        }
        self.store = store
        self.applicationID = applicationID
        self.deviceName = deviceName
        self.now = now
    }

    public func savePairingCredential(
        deviceID: UUID,
        credential: Data,
        serverFingerprint: Data
    ) async throws {
        guard credential.count == rivetDeviceCredentialSize,
              serverFingerprint.count == rivetDeviceFingerprintSize else {
            throw RivetDeviceAppleCompanionError.invalidPairing
        }
        guard try await store.load(deviceID: deviceID) == nil else {
            throw RivetDeviceAppleCompanionError.pairingAlreadyExists
        }
        let timestamp = now()
        let device = RivetDevicePairedDevice(
            id: deviceID,
            applicationID: applicationID,
            name: deviceName,
            scopeNames: [],
            serverFingerprint: serverFingerprint,
            createdAt: timestamp,
            lastUsedAt: timestamp
        )
        try await store.save(RivetDeviceStoredPairing(
            device: device,
            credential: credential
        ))
        newlyPairedDevices.insert(deviceID)
    }

    /// Update non-secret metadata before the authenticated stream is handed to
    /// the product. A new credential is already persisted by the session gate.
    func recordAcceptance(
        _ acceptance: RivetDeviceSessionClientAcceptance
    ) async throws {
        guard acceptance.scopeNames.count <= 64,
              Set(acceptance.scopeNames).count == acceptance.scopeNames.count,
              acceptance.scopeNames.allSatisfy(isValidDeviceAPIName) else {
            throw RivetDeviceAppleCompanionError.invalidScopes
        }
        guard let stored = try await store.load(deviceID: acceptance.deviceID) else {
            throw RivetDeviceAppleCompanionError.pairingNotFound
        }
        guard stored.device.applicationID == applicationID,
              stored.device.serverFingerprint.count == rivetDeviceFingerprintSize else {
            throw RivetDeviceAppleCompanionError.applicationMismatch
        }
        let lastUsedAt = max(now(), stored.device.createdAt)
        let device = RivetDevicePairedDevice(
            id: stored.device.id,
            applicationID: stored.device.applicationID,
            name: stored.device.name,
            scopeNames: acceptance.scopeNames,
            serverFingerprint: stored.device.serverFingerprint,
            createdAt: stored.device.createdAt,
            lastUsedAt: lastUsedAt
        )
        do {
            try await store.save(RivetDeviceStoredPairing(
                device: device,
                credential: stored.credential
            ))
        } catch {
            if newlyPairedDevices.remove(acceptance.deviceID) != nil {
                try? await store.remove(deviceID: acceptance.deviceID)
            }
            throw error
        }
        newlyPairedDevices.remove(acceptance.deviceID)
    }
}

/// Shared iOS/iPadOS companion orchestration. Products supply the RVT1
/// application handler; this layer owns explicit Bonjour selection, pinned
/// reconnect versus provisional pairing, Keychain-backed credential gates,
/// and the RVD1 session lifecycle. It never auto-pairs or auto-reconnects.
public actor RivetDeviceAppleCompanion {
    public typealias ApplicationHandler = @Sendable (
        RivetDeviceSessionClientAcceptance,
        RivetDeviceAppleConnection
    ) async throws -> Void

    public nonisolated let events: AsyncStream<RivetDeviceAppleCompanionEvent>

    private let configuration: RivetDeviceAppleCompanionConfiguration
    private let pairingStore: any RivetDevicePairingStore
    private let credentialStore: RivetDeviceApplePairingCredentialStoreAdapter
    private let browser: RivetDeviceAppleBonjourBrowser
    private let eventContinuation: AsyncStream<RivetDeviceAppleCompanionEvent>.Continuation
    private var activeSession: RivetDeviceAppleSessionClient?
    private var activeTask: Task<Void, Never>?
    private var activeToken: UUID?
    private var activeDeviceID: UUID?

    public init(
        configuration: RivetDeviceAppleCompanionConfiguration,
        pairingStore: any RivetDevicePairingStore
    ) throws {
        let credentialStore = try RivetDeviceApplePairingCredentialStoreAdapter(
            store: pairingStore,
            applicationID: configuration.applicationID,
            deviceName: configuration.deviceName
        )
        let (events, continuation) = AsyncStream.makeStream(
            of: RivetDeviceAppleCompanionEvent.self,
            bufferingPolicy: .bufferingNewest(256)
        )
        self.events = events
        eventContinuation = continuation
        self.configuration = configuration
        self.pairingStore = pairingStore
        self.credentialStore = credentialStore
        browser = RivetDeviceAppleBonjourBrowser { event in
            _ = continuation.yield(.discovery(event))
        }
    }

    public func startBrowsing() async throws {
        try await browser.start()
    }

    public func stopBrowsing() async {
        await browser.stop()
    }

    public func discoverySnapshot() async -> RivetDeviceAppleBonjourBrowserSnapshot {
        await browser.snapshot()
    }

    public func pairedDevices() async throws -> [RivetDevicePairedDevice] {
        try await pairingStore.pairedDevices()
    }

    public func removePairing(deviceID: UUID) async throws {
        if activeDeviceID == deviceID {
            await cancelSession()
        }
        try await pairingStore.remove(deviceID: deviceID)
    }

    /// Start one session against a currently visible, explicitly selected
    /// candidate. The supplied handler owns the post-RVD1 RVT1 protocol.
    public func startSession(
        selected: RivetDeviceAppleBonjourDiscovery,
        intent: RivetDeviceAppleCompanionConnectIntent,
        applicationHandler: @escaping ApplicationHandler
    ) async throws {
        guard activeSession == nil else {
            throw RivetDeviceAppleCompanionError.sessionAlreadyActive
        }
        let snapshot = await browser.snapshot()
        guard snapshot.discoveries.contains(selected) else {
            throw RivetDeviceAppleCompanionError.staleSelection
        }

        let sessionIntent: RivetDeviceAppleSessionClientIntent
        var reconnectDeviceID: UUID?
        switch intent {
        case .pair(let windowID):
            guard selected.pairingWindowOpen else {
                throw RivetDeviceAppleCompanionError.pairingWindowClosed
            }
            sessionIntent = .pair(
                applicationID: configuration.applicationID,
                windowID: windowID,
                deviceName: configuration.deviceName
            )
        case .reconnect(let deviceID):
            guard let pairing = try await pairingStore.load(deviceID: deviceID) else {
                throw RivetDeviceAppleCompanionError.pairingNotFound
            }
            guard pairing.device.applicationID == configuration.applicationID else {
                throw RivetDeviceAppleCompanionError.applicationMismatch
            }
            reconnectDeviceID = deviceID
            sessionIntent = .reconnect(pairing: pairing)
        }

        let token = UUID()
        let continuation = eventContinuation
        let credentialStore = self.credentialStore
        let configuration = self.configuration
        let client = try RivetDeviceAppleSessionClient(
            endpoint: selected.endpoint,
            intent: sessionIntent,
            credentialStore: credentialStore,
            postTLSTimeout: configuration.postTLSTimeout,
            pairingResponseTimeout: configuration.pairingResponseTimeout,
            clientFactory: { startedAt, materials in
                switch materials {
                case .reconnect(let pairing, let clientNonce):
                    return try RivetDeviceSessionClient(
                        reconnectApplicationID: pairing.device.applicationID,
                        deviceID: pairing.device.id,
                        credential: pairing.credential,
                        serverFingerprint: pairing.device.serverFingerprint,
                        clientNonce: clientNonce,
                        timeout: configuration.postTLSTimeout,
                        startedAt: startedAt
                    )
                case .pair(
                    let applicationID,
                    let windowID,
                    let deviceName,
                    let observedFingerprint,
                    let clientNonce
                ):
                    return try RivetDeviceSessionClient(
                        pairingApplicationID: applicationID,
                        windowID: windowID,
                        deviceName: deviceName,
                        serverFingerprint: observedFingerprint,
                        clientNonce: clientNonce,
                        timeout: configuration.postTLSTimeout,
                        pairingResponseTimeout: configuration.pairingResponseTimeout,
                        startedAt: startedAt
                    )
                }
            },
            pairingCodeHandler: { code in
                _ = continuation.yield(.pairingCode(code))
            },
            applicationHandler: { [weak self] acceptance, connection in
                try await credentialStore.recordAcceptance(acceptance)
                guard let self else {
                    throw RivetDeviceAppleCompanionError.sessionNoLongerActive
                }
                try await self.sessionAccepted(token: token, acceptance: acceptance)
                try await applicationHandler(acceptance, connection)
            }
        )
        activeSession = client
        activeToken = token
        activeDeviceID = reconnectDeviceID
        activeTask = Task { [weak self] in
            do {
                try await client.run()
                await self?.finishSession(token: token, event: .sessionEnded)
            } catch {
                await self?.finishSession(token: token, event: .sessionFailed)
            }
        }
    }

    public func confirmPairing(_ confirmed: Bool) async throws {
        guard let activeSession else {
            throw RivetDeviceAppleCompanionError.noActiveSession
        }
        try await activeSession.confirmPairing(confirmed)
    }

    public func cancelSession() async {
        guard let activeSession else {
            return
        }
        activeTask?.cancel()
        await activeSession.cancel()
    }

    private func sessionAccepted(
        token: UUID,
        acceptance: RivetDeviceSessionClientAcceptance
    ) throws {
        guard activeToken == token else {
            throw RivetDeviceAppleCompanionError.sessionNoLongerActive
        }
        activeDeviceID = acceptance.deviceID
        _ = eventContinuation.yield(.connected(acceptance))
    }

    private func finishSession(
        token: UUID,
        event: RivetDeviceAppleCompanionEvent
    ) {
        guard activeToken == token else {
            return
        }
        activeSession = nil
        activeTask = nil
        activeToken = nil
        activeDeviceID = nil
        _ = eventContinuation.yield(event)
    }
}
