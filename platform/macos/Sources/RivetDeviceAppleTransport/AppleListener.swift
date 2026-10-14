#if os(macOS)
import Foundation
import Network
import RivetDevice

public enum RivetDeviceAppleListenerState: Sendable, Equatable {
    case disabled
    case starting
    case ready(port: UInt16)
    case failed
    case terminated
}

public struct RivetDeviceAppleListenerSnapshot: Sendable, Equatable {
    public let state: RivetDeviceAppleListenerState
    public let activeConnections: Int
    public let rejectedConnections: UInt64
    public let serverFingerprint: Data?
    public let advertisementID: String?
    public let pairingWindowOpen: Bool

    public init(
        state: RivetDeviceAppleListenerState,
        activeConnections: Int,
        rejectedConnections: UInt64,
        serverFingerprint: Data?,
        advertisementID: String?,
        pairingWindowOpen: Bool
    ) {
        self.state = state
        self.activeConnections = activeConnections
        self.rejectedConnections = rejectedConnections
        self.serverFingerprint = serverFingerprint
        self.advertisementID = advertisementID
        self.pairingWindowOpen = pairingWindowOpen
    }
}

public enum RivetDeviceAppleListenerError: Error, Sendable, Equatable,
    CustomStringConvertible {
    case invalidConfiguration
    case invalidState
    case identityUnavailable
    case advertisementFailed
    case startTimedOut
    case startFailed

    public var description: String {
        switch self {
        case .invalidConfiguration:
            "invalid Rivet device listener configuration"
        case .invalidState:
            "Rivet device listener is in the wrong state"
        case .identityUnavailable:
            "Rivet device listener identity is unavailable"
        case .advertisementFailed:
            "Rivet device Bonjour advertisement is invalid"
        case .startTimedOut:
            "Rivet device listener start timed out"
        case .startFailed:
            "Rivet device listener failed to start"
        }
    }
}

package protocol RivetDeviceApplePendingConnection: Sendable {
    func makeConnection(timeout: TimeInterval) throws -> RivetDeviceAppleConnection
    func cancel()
}

package enum RivetDeviceAppleListenerDriverStop: Sendable {
    case failed
    case cancelled
}

package protocol RivetDeviceAppleListenerDriver: Sendable {
    func start(
        timeout: TimeInterval,
        queue: DispatchQueue,
        onConnection: @escaping @Sendable (
            any RivetDeviceApplePendingConnection
        ) -> Void,
        onStop: @escaping @Sendable (RivetDeviceAppleListenerDriverStop) -> Void
    ) async throws -> UInt16
    func setBonjourService(_ service: RivetDeviceAppleBonjourService?)
    func cancel()
}

package protocol RivetDeviceAppleListenerDriverFactory: Sendable {
    func make(parameters: NWParameters) throws -> any RivetDeviceAppleListenerDriver
}

package struct RivetDeviceSystemListenerDriverFactory:
    RivetDeviceAppleListenerDriverFactory {
    package init() {}

    package func make(
        parameters: NWParameters
    ) throws -> any RivetDeviceAppleListenerDriver {
        try RivetDeviceSystemListenerDriver(parameters: parameters)
    }
}

private struct ActiveConnection {
    let connection: RivetDeviceAppleConnection
    var task: Task<Void, Never>?
}

/// Disabled-by-default macOS host listener. It owns only connection admission
/// and transport lifetime; session authentication and RVT1 dispatch remain in
/// `RivetDeviceSession` and `RivetDeviceGateway`.
public actor RivetDeviceAppleListener {
    public typealias ConnectionHandler = @Sendable (
        RivetDeviceAppleConnection
    ) async -> Void

    private let identityStore: RivetDeviceAppleIdentityStore
    private let driverFactory: any RivetDeviceAppleListenerDriverFactory
    private let serviceName: String
    private let advertisementIDGenerator: @Sendable () -> String
    private let maximumConnections: Int
    private let connectionTimeout: TimeInterval
    private let startTimeout: TimeInterval
    private let queue: DispatchQueue
    private let handler: ConnectionHandler

    private var state = RivetDeviceAppleListenerState.disabled
    private var generation = UUID()
    private var driver: (any RivetDeviceAppleListenerDriver)?
    private var fingerprint: Data?
    private var advertisement: RivetDeviceAppleBonjourAdvertisement?
    private var pendingConnections: [any RivetDeviceApplePendingConnection] = []
    private var active: [UUID: ActiveConnection] = [:]
    private var rejected: UInt64 = 0

    public init(
        applicationID: String,
        serviceName: String,
        maximumConnections: Int = rivetDeviceDefaultMaximumSessions,
        connectionTimeout: TimeInterval = rivetDeviceAppleConnectionTimeout,
        startTimeout: TimeInterval = rivetDeviceAppleConnectionTimeout,
        handler: @escaping ConnectionHandler
    ) throws {
        try self.init(
            identityStore: RivetDeviceAppleIdentityStore(
                applicationID: applicationID
            ),
            driverFactory: RivetDeviceSystemListenerDriverFactory(),
            serviceName: serviceName,
            advertisementIDGenerator: Self.makeAdvertisementID,
            maximumConnections: maximumConnections,
            connectionTimeout: connectionTimeout,
            startTimeout: startTimeout,
            queue: DispatchQueue(label: "dev.rivet.device-listener"),
            handler: handler
        )
    }

    package init(
        identityStore: RivetDeviceAppleIdentityStore,
        driverFactory: any RivetDeviceAppleListenerDriverFactory,
        serviceName: String,
        advertisementIDGenerator: @escaping @Sendable () -> String =
            RivetDeviceAppleListener.makeAdvertisementID,
        maximumConnections: Int = rivetDeviceDefaultMaximumSessions,
        connectionTimeout: TimeInterval = rivetDeviceAppleConnectionTimeout,
        startTimeout: TimeInterval = rivetDeviceAppleConnectionTimeout,
        queue: DispatchQueue = DispatchQueue(
            label: "dev.rivet.device-listener"
        ),
        handler: @escaping ConnectionHandler
    ) throws {
        guard Self.isValidServiceName(serviceName),
              maximumConnections > 0,
              maximumConnections <= 64,
              connectionTimeout.isFinite,
              connectionTimeout > 0,
              startTimeout.isFinite,
              startTimeout > 0 else {
            throw RivetDeviceAppleListenerError.invalidConfiguration
        }
        self.identityStore = identityStore
        self.driverFactory = driverFactory
        self.serviceName = serviceName
        self.advertisementIDGenerator = advertisementIDGenerator
        self.maximumConnections = maximumConnections
        self.connectionTimeout = connectionTimeout
        self.startTimeout = startTimeout
        self.queue = queue
        self.handler = handler
    }

    deinit {
        driver?.setBonjourService(nil)
        driver?.cancel()
        for entry in active.values {
            entry.task?.cancel()
        }
        for pending in pendingConnections {
            pending.cancel()
        }
    }

    public func snapshot() -> RivetDeviceAppleListenerSnapshot {
        RivetDeviceAppleListenerSnapshot(
            state: state,
            activeConnections: active.count,
            rejectedConnections: rejected,
            serverFingerprint: fingerprint,
            advertisementID: advertisement?.advertisementID,
            pairingWindowOpen: advertisement?.pairingWindowOpen ?? false
        )
    }

    @discardableResult
    public func enable() async throws -> RivetDeviceAppleListenerSnapshot {
        guard state == .disabled else {
            throw RivetDeviceAppleListenerError.invalidState
        }
        state = .starting
        rejected = 0
        fingerprint = nil
        advertisement = nil
        let requestedGeneration = UUID()
        generation = requestedGeneration

        let identity: RivetDeviceAppleServerIdentity
        let newDriver: any RivetDeviceAppleListenerDriver
        do {
            identity = try identityStore.loadOrCreate()
            newDriver = try driverFactory.make(parameters: identity.parameters)
        } catch {
            state = .failed
            throw RivetDeviceAppleListenerError.identityUnavailable
        }
        guard state == .starting, generation == requestedGeneration else {
            newDriver.cancel()
            throw RivetDeviceAppleListenerError.invalidState
        }
        driver = newDriver
        fingerprint = identity.fingerprint
        do {
            advertisement = try RivetDeviceAppleBonjourAdvertisement(
                advertisementID: advertisementIDGenerator(),
                pairingWindowOpen: false
            )
        } catch {
            state = .failed
            driver = nil
            fingerprint = nil
            newDriver.cancel()
            throw RivetDeviceAppleListenerError.advertisementFailed
        }

        do {
            let port = try await newDriver.start(
                timeout: startTimeout,
                queue: queue,
                onConnection: { [weak self] pending in
                    Task {
                        await self?.accept(
                            pending,
                            generation: requestedGeneration
                        )
                    }
                },
                onStop: { [weak self] stop in
                    Task {
                        await self?.driverStopped(
                            stop,
                            generation: requestedGeneration
                        )
                    }
                }
            )
            guard state == .starting, generation == requestedGeneration else {
                newDriver.cancel()
                throw RivetDeviceAppleListenerError.invalidState
            }
            state = .ready(port: port)
            if let advertisement {
                newDriver.setBonjourService(RivetDeviceAppleBonjourService(
                    name: serviceName,
                    advertisement: advertisement
                ))
            }
            let queued = pendingConnections
            pendingConnections.removeAll(keepingCapacity: true)
            for pending in queued {
                accept(pending, generation: requestedGeneration)
            }
            return snapshot()
        } catch {
            if generation == requestedGeneration, state == .starting {
                state = .failed
                driver = nil
                fingerprint = nil
                advertisement = nil
                cancelPendingConnections()
            }
            newDriver.cancel()
            if let error = error as? RivetDeviceAppleListenerError {
                throw error
            }
            if let error = error as? RivetDeviceAppleTransportError,
               error == .connectionTimedOut {
                throw RivetDeviceAppleListenerError.startTimedOut
            }
            throw RivetDeviceAppleListenerError.startFailed
        }
    }

    /// Stops admission immediately and closes every accepted transport before
    /// returning. A later explicit enable creates a fresh listener generation.
    public func disable() async {
        guard state != .terminated else {
            return
        }
        generation = UUID()
        driver?.setBonjourService(nil)
        state = .disabled
        fingerprint = nil
        advertisement = nil
        driver?.cancel()
        driver = nil
        cancelPendingConnections()
        await closeActiveConnections()
    }

    /// Terminal shutdown for application termination. The listener cannot be
    /// enabled again after this call.
    public func terminate() async {
        guard state != .terminated else {
            return
        }
        generation = UUID()
        driver?.setBonjourService(nil)
        state = .terminated
        fingerprint = nil
        advertisement = nil
        driver?.cancel()
        driver = nil
        cancelPendingConnections()
        await closeActiveConnections()
    }

    /// Updates the single non-sensitive pairing hint without restarting the
    /// listener or rotating its ephemeral advertisement identifier.
    public func setPairingWindowOpen(_ isOpen: Bool) throws {
        guard case .ready = state,
              let current = advertisement,
              let driver else {
            throw RivetDeviceAppleListenerError.invalidState
        }
        let updated: RivetDeviceAppleBonjourAdvertisement
        do {
            updated = try RivetDeviceAppleBonjourAdvertisement(
                advertisementID: current.advertisementID,
                pairingWindowOpen: isOpen
            )
        } catch {
            throw RivetDeviceAppleListenerError.advertisementFailed
        }
        advertisement = updated
        driver.setBonjourService(RivetDeviceAppleBonjourService(
            name: serviceName,
            advertisement: updated
        ))
    }

    private func accept(
        _ pending: any RivetDeviceApplePendingConnection,
        generation acceptedGeneration: UUID
    ) {
        guard generation == acceptedGeneration else {
            pending.cancel()
            return
        }
        if state == .starting {
            guard pendingConnections.count + active.count < maximumConnections else {
                rejected &+= 1
                pending.cancel()
                return
            }
            pendingConnections.append(pending)
            return
        }
        guard case .ready = state else {
            pending.cancel()
            return
        }
        guard active.count < maximumConnections else {
            rejected &+= 1
            pending.cancel()
            return
        }

        let connection: RivetDeviceAppleConnection
        do {
            connection = try pending.makeConnection(timeout: connectionTimeout)
        } catch {
            rejected &+= 1
            pending.cancel()
            return
        }

        let id = UUID()
        active[id] = ActiveConnection(connection: connection, task: nil)
        let task = Task { [weak self, handler] in
            await handler(connection)
            await self?.connectionFinished(
                id: id,
                generation: acceptedGeneration
            )
        }
        active[id]?.task = task
    }

    private func connectionFinished(id: UUID, generation finishedGeneration: UUID) async {
        guard generation == finishedGeneration,
              let entry = active.removeValue(forKey: id) else {
            return
        }
        await entry.connection.cancel()
    }

    private func driverStopped(
        _ stop: RivetDeviceAppleListenerDriverStop,
        generation stoppedGeneration: UUID
    ) async {
        guard generation == stoppedGeneration,
              state != .disabled,
              state != .terminated else {
            return
        }
        driver?.setBonjourService(nil)
        switch stop {
        case .failed:
            state = .failed
        case .cancelled:
            state = .disabled
        }
        fingerprint = nil
        advertisement = nil
        driver = nil
        cancelPendingConnections()
        await closeActiveConnections()
    }

    private func cancelPendingConnections() {
        let values = pendingConnections
        pendingConnections.removeAll(keepingCapacity: true)
        for pending in values {
            pending.cancel()
        }
    }

    private func closeActiveConnections() async {
        let entries = Array(active.values)
        active.removeAll(keepingCapacity: true)
        for entry in entries {
            entry.task?.cancel()
            await entry.connection.cancel()
        }
    }

    private static func isValidServiceName(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 63
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.unicodeScalars.contains(
                where: CharacterSet.controlCharacters.contains
            )
    }

    private static func makeAdvertisementID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

private final class RivetDeviceSystemPendingConnection:
    RivetDeviceApplePendingConnection, @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func makeConnection(
        timeout: TimeInterval
    ) throws -> RivetDeviceAppleConnection {
        try RivetDeviceAppleConnection(
            acceptedConnection: connection,
            timeout: timeout,
            queue: queue
        )
    }

    func cancel() {
        connection.cancel()
    }
}

private final class RivetDeviceSystemListenerDriver:
    RivetDeviceAppleListenerDriver, @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var cancelled = false

    init(parameters: NWParameters) throws {
        listener = try NWListener(using: parameters, on: .any)
    }

    func start(
        timeout: TimeInterval,
        queue: DispatchQueue,
        onConnection: @escaping @Sendable (
            any RivetDeviceApplePendingConnection
        ) -> Void,
        onStop: @escaping @Sendable (RivetDeviceAppleListenerDriverStop) -> Void
    ) async throws -> UInt16 {
        let waiter = RivetDeviceAppleListenerStartWaiter(
            listener: listener,
            onStop: onStop
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard waiter.install(
                    continuation: continuation,
                    timeout: timeout,
                    queue: queue
                ) else {
                    return
                }
                listener.newConnectionHandler = { connection in
                    onConnection(RivetDeviceSystemPendingConnection(
                        connection: connection,
                        queue: queue
                    ))
                }
                listener.stateUpdateHandler = { state in
                    waiter.handle(state)
                }
                if lock.withLock({ cancelled }) {
                    waiter.cancel()
                } else {
                    listener.start(queue: queue)
                }
            }
        } onCancel: {
            waiter.cancel()
        }
    }

    func setBonjourService(_ service: RivetDeviceAppleBonjourService?) {
        if let service {
            listener.service = NWListener.Service(
                name: service.name,
                type: service.type,
                txtRecord: service.txtRecord
            )
        } else {
            listener.service = nil
        }
    }

    func cancel() {
        lock.withLock { cancelled = true }
        listener.cancel()
    }
}

private final class RivetDeviceAppleListenerStartWaiter: @unchecked Sendable {
    private let listener: NWListener
    private let onStop: @Sendable (RivetDeviceAppleListenerDriverStop) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, any Error>?
    private var timeoutWorkItem: DispatchWorkItem?
    private var result: Result<UInt16, RivetDeviceAppleListenerError>?
    private var reachedReady = false
    private var stopDelivered = false

    init(
        listener: NWListener,
        onStop: @escaping @Sendable (RivetDeviceAppleListenerDriverStop) -> Void
    ) {
        self.listener = listener
        self.onStop = onStop
    }

    func install(
        continuation: CheckedContinuation<UInt16, any Error>,
        timeout: TimeInterval,
        queue: DispatchQueue
    ) -> Bool {
        let earlyResult: Result<UInt16, RivetDeviceAppleListenerError>? =
            lock.withLock {
                if let result {
                    return result
                }
                self.continuation = continuation
                let work = DispatchWorkItem { [weak self] in
                    self?.finish(.failure(.startTimedOut))
                }
                timeoutWorkItem = work
                queue.asyncAfter(deadline: .now() + timeout, execute: work)
                return nil
            }
        if let earlyResult {
            resume(continuation, with: earlyResult)
            return false
        }
        return true
    }

    func handle(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener.port?.rawValue else {
                finish(.failure(.startFailed))
                return
            }
            lock.withLock { reachedReady = true }
            finish(.success(port))
        case .failed:
            finish(.failure(.startFailed))
            deliverStop(.failed)
        case .cancelled:
            finish(.failure(.startFailed))
            deliverStop(.cancelled)
        case .setup, .waiting:
            break
        @unknown default:
            finish(.failure(.startFailed))
            deliverStop(.failed)
        }
    }

    func cancel() {
        listener.cancel()
        finish(.failure(.startFailed))
    }

    private func finish(
        _ newResult: Result<UInt16, RivetDeviceAppleListenerError>
    ) {
        let continuation: CheckedContinuation<UInt16, any Error>? = lock.withLock {
            guard result == nil else {
                return nil
            }
            result = newResult
            timeoutWorkItem?.cancel()
            timeoutWorkItem = nil
            let value = self.continuation
            self.continuation = nil
            return value
        }
        if case .failure = newResult {
            listener.cancel()
        }
        guard let continuation else {
            return
        }
        resume(continuation, with: newResult)
    }

    private func deliverStop(_ stop: RivetDeviceAppleListenerDriverStop) {
        let shouldDeliver = lock.withLock {
            guard reachedReady, !stopDelivered else {
                return false
            }
            stopDelivered = true
            return true
        }
        if shouldDeliver {
            onStop(stop)
        }
    }

    private func resume(
        _ continuation: CheckedContinuation<UInt16, any Error>,
        with result: Result<UInt16, RivetDeviceAppleListenerError>
    ) {
        switch result {
        case .success(let port):
            continuation.resume(returning: port)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
#endif
