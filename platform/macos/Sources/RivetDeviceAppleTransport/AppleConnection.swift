import Foundation
import Network
import RivetDevice
import RivetDeviceSession

package protocol RivetDeviceAppleByteConnection: Sendable {
    func start(timeout: TimeInterval) async throws -> RivetDeviceAppleTLSObservation
    func send(_ data: Data) async throws
    func receive(maximumLength: Int) async throws -> Data?
    func cancel()
}

private enum ConnectionPhase {
    case idle
    case starting
    case preface
    case application
    case closed
}

/// Ordered TLS stream boundary for the `RVD1` preface and the subsequent RVT1
/// byte stream. The connection never interprets ordinary RVT1 bytes as preface
/// records, and callers must explicitly mark successful session acceptance.
public actor RivetDeviceAppleConnection {
    private let driver: any RivetDeviceAppleByteConnection
    private let timeout: TimeInterval
    private var phase = ConnectionPhase.idle
    private var readInProgress = false

    public init(
        endpoint: NWEndpoint,
        tls: RivetDeviceAppleClientTLSContext,
        timeout: TimeInterval = rivetDeviceAppleConnectionTimeout,
        queue: DispatchQueue = DispatchQueue(label: "dev.rivet.device-connection")
    ) throws {
        guard timeout.isFinite, timeout > 0 else {
            throw RivetDeviceAppleTransportError.invalidConfiguration
        }
        driver = NWConnectionDriver(
            connection: NWConnection(
                to: endpoint,
                using: try tls.claimParameters()
            ),
            tls: tls,
            queue: queue
        )
        self.timeout = timeout
    }

    /// Wraps an unstarted connection accepted by a future `NWListener`.
    public init(
        acceptedConnection: NWConnection,
        timeout: TimeInterval = rivetDeviceAppleConnectionTimeout,
        queue: DispatchQueue = DispatchQueue(label: "dev.rivet.device-connection")
    ) throws {
        guard timeout.isFinite, timeout > 0 else {
            throw RivetDeviceAppleTransportError.invalidConfiguration
        }
        driver = NWConnectionDriver(
            connection: acceptedConnection,
            tls: nil,
            queue: queue
        )
        self.timeout = timeout
    }

    package init(
        driver: any RivetDeviceAppleByteConnection,
        timeout: TimeInterval = rivetDeviceAppleConnectionTimeout
    ) throws {
        guard timeout.isFinite, timeout > 0 else {
            throw RivetDeviceAppleTransportError.invalidConfiguration
        }
        self.driver = driver
        self.timeout = timeout
    }

    deinit {
        driver.cancel()
    }

    @discardableResult
    public func start() async throws -> RivetDeviceAppleTLSObservation {
        guard phase == .idle else {
            throw RivetDeviceAppleTransportError.invalidPhase
        }
        phase = .starting
        do {
            let observation = try await driver.start(timeout: timeout)
            guard phase == .starting else {
                driver.cancel()
                throw RivetDeviceAppleTransportError.connectionClosed
            }
            phase = .preface
            return observation
        } catch {
            phase = .closed
            driver.cancel()
            throw error
        }
    }

    public func sendSessionMessage(
        _ message: RivetDeviceSessionMessage
    ) async throws {
        guard phase == .preface else {
            throw RivetDeviceAppleTransportError.invalidPhase
        }
        do {
            try await driver.send(try encodeRivetDeviceSessionRecord(message))
        } catch {
            closeAfterFailure()
            throw error
        }
    }

    public func receiveSessionMessage() async throws -> RivetDeviceSessionMessage {
        guard phase == .preface else {
            throw RivetDeviceAppleTransportError.invalidPhase
        }
        return try await withExclusiveRead {
            do {
                let header = try await readExactly(8)
                var decoder = RivetDeviceSessionRecordDecoder()
                var messages = try decoder.append(header)
                if messages.isEmpty {
                    let payloadLength = Int(header[6]) | (Int(header[7]) << 8)
                    let payload = try await readExactly(payloadLength)
                    messages.append(contentsOf: try decoder.append(payload))
                }
                try decoder.finish()
                guard messages.count == 1, let message = messages.first else {
                    throw RivetDeviceSessionProtocolError.malformedPayload
                }
                return message
            } catch {
                closeAfterFailure()
                throw error
            }
        }
    }

    /// Call only after the client or server session state machine emits its
    /// accepted action. Subsequent bytes are ordinary RVT1 and are never fed
    /// back into the preface decoder.
    public func beginApplicationProtocol() throws {
        guard phase == .preface, !readInProgress else {
            throw RivetDeviceAppleTransportError.invalidPhase
        }
        phase = .application
    }

    public func sendApplicationBytes(_ data: Data) async throws {
        guard phase == .application else {
            throw RivetDeviceAppleTransportError.invalidPhase
        }
        guard !data.isEmpty,
              data.count <= rivetDeviceDefaultMaximumMessageSize + 18 else {
            throw RivetDeviceAppleTransportError.invalidReceiveLength
        }
        do {
            try await driver.send(data)
        } catch {
            closeAfterFailure()
            throw error
        }
    }

    public func receiveApplicationBytes(
        maximumLength: Int
    ) async throws -> Data? {
        guard phase == .application else {
            throw RivetDeviceAppleTransportError.invalidPhase
        }
        guard maximumLength > 0,
              maximumLength <= rivetDeviceDefaultMaximumMessageSize + 18 else {
            throw RivetDeviceAppleTransportError.invalidReceiveLength
        }
        return try await withExclusiveRead {
            do {
                let data = try await driver.receive(maximumLength: maximumLength)
                if data == nil {
                    phase = .closed
                }
                return data
            } catch {
                closeAfterFailure()
                throw error
            }
        }
    }

    public func cancel() {
        phase = .closed
        driver.cancel()
    }

    private func readExactly(_ count: Int) async throws -> Data {
        guard count >= 0, count <= rivetDeviceSessionMaximumRecordSize else {
            throw RivetDeviceAppleTransportError.invalidReceiveLength
        }
        var result = Data()
        while result.count < count {
            let remaining = count - result.count
            guard let part = try await driver.receive(maximumLength: remaining) else {
                throw RivetDeviceSessionProtocolError.truncated
            }
            guard !part.isEmpty, part.count <= remaining else {
                throw RivetDeviceAppleTransportError.connectionFailed
            }
            result.append(part)
        }
        return result
    }

    private func withExclusiveRead<T: Sendable>(
        _ operation: () async throws -> T
    ) async throws -> T {
        guard !readInProgress else {
            throw RivetDeviceAppleTransportError.concurrentRead
        }
        readInProgress = true
        defer { readInProgress = false }
        return try await operation()
    }

    private func closeAfterFailure() {
        phase = .closed
        driver.cancel()
    }
}

private final class NWConnectionDriver: RivetDeviceAppleByteConnection,
    @unchecked Sendable {
    private let connection: NWConnection
    private let tls: RivetDeviceAppleClientTLSContext?
    private let queue: DispatchQueue

    init(
        connection: NWConnection,
        tls: RivetDeviceAppleClientTLSContext?,
        queue: DispatchQueue
    ) {
        self.connection = connection
        self.tls = tls
        self.queue = queue
    }

    func start(timeout: TimeInterval) async throws -> RivetDeviceAppleTLSObservation {
        let waiter = ConnectionStartWaiter(
            connection: connection,
            requiresServerFingerprint: tls != nil,
            serverFingerprint: { [tls] in
                tls?.verifiedServerFingerprint
            },
            verificationError: { [tls] in
                tls?.verificationError
            }
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let shouldStart = waiter.install(
                    continuation: continuation,
                    timeout: timeout,
                    queue: queue
                )
                guard shouldStart else {
                    return
                }
                connection.stateUpdateHandler = { state in
                    waiter.handle(state)
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            waiter.cancel()
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { continuation in
            connection.send(
                content: data,
                contentContext: .defaultMessage,
                isComplete: true,
                completion: .contentProcessed { error in
                    if error == nil {
                        continuation.resume()
                    } else {
                        continuation.resume(
                            throwing: RivetDeviceAppleTransportError.connectionFailed
                        )
                    }
                }
            )
        }
    }

    func receive(maximumLength: Int) async throws -> Data? {
        guard maximumLength > 0 else {
            throw RivetDeviceAppleTransportError.invalidReceiveLength
        }
        while true {
            let result: (Data?, Bool) = try await withCheckedThrowingContinuation {
                continuation in
                connection.receive(
                    minimumIncompleteLength: 1,
                    maximumLength: maximumLength
                ) { content, _, complete, error in
                    if error != nil {
                        continuation.resume(
                            throwing: RivetDeviceAppleTransportError.connectionFailed
                        )
                    } else {
                        continuation.resume(returning: (content, complete))
                    }
                }
            }
            if let data = result.0, !data.isEmpty {
                return data
            }
            if result.1 {
                return nil
            }
        }
    }

    func cancel() {
        connection.cancel()
    }
}

private final class ConnectionStartWaiter: @unchecked Sendable {
    private let connection: NWConnection
    private let requiresServerFingerprint: Bool
    private let serverFingerprint: @Sendable () -> Data?
    private let verificationError: @Sendable () -> RivetDeviceAppleTransportError?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<
        RivetDeviceAppleTLSObservation,
        any Error
    >?
    private var timeoutWorkItem: DispatchWorkItem?
    private var completed = false
    private var completedResult: Result<
        RivetDeviceAppleTLSObservation,
        RivetDeviceAppleTransportError
    >?

    init(
        connection: NWConnection,
        requiresServerFingerprint: Bool,
        serverFingerprint: @escaping @Sendable () -> Data?,
        verificationError: @escaping @Sendable () -> RivetDeviceAppleTransportError?
    ) {
        self.connection = connection
        self.requiresServerFingerprint = requiresServerFingerprint
        self.serverFingerprint = serverFingerprint
        self.verificationError = verificationError
    }

    func install(
        continuation: CheckedContinuation<RivetDeviceAppleTLSObservation, any Error>,
        timeout: TimeInterval,
        queue: DispatchQueue
    ) -> Bool {
        let earlyResult: Result<
            RivetDeviceAppleTLSObservation,
            RivetDeviceAppleTransportError
        >? = lock.withLock {
            if let completedResult {
                return completedResult
            }
            self.continuation = continuation
            let work = DispatchWorkItem { [weak self] in
                self?.finish(.failure(.connectionTimedOut))
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

    func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            do {
                let fingerprint = serverFingerprint()
                guard !requiresServerFingerprint || fingerprint != nil else {
                    throw RivetDeviceAppleTransportError.certificateUnavailable
                }
                let observation = try RivetDeviceAppleTLS.observation(
                    for: connection,
                    serverFingerprint: fingerprint
                )
                finish(.success(observation))
            } catch {
                finish(.failure(
                    error as? RivetDeviceAppleTransportError
                        ?? .tlsNegotiationFailed
                ))
            }
        case .failed:
            finish(.failure(verificationError() ?? .connectionFailed))
        case .cancelled:
            finish(.failure(.connectionClosed))
        case .setup, .waiting, .preparing:
            break
        @unknown default:
            finish(.failure(.connectionFailed))
        }
    }

    func cancel() {
        finish(.failure(.connectionClosed))
    }

    private func finish(
        _ result: Result<RivetDeviceAppleTLSObservation, RivetDeviceAppleTransportError>
    ) {
        let continuation: CheckedContinuation<
            RivetDeviceAppleTLSObservation,
            any Error
        >? = lock.withLock {
            guard !completed else {
                return nil
            }
            completed = true
            completedResult = result
            timeoutWorkItem?.cancel()
            timeoutWorkItem = nil
            let value = self.continuation
            self.continuation = nil
            return value
        }
        if case .failure = result {
            connection.cancel()
        }
        guard let continuation else {
            return
        }
        resume(continuation, with: result)
    }

    private func resume(
        _ continuation: CheckedContinuation<
            RivetDeviceAppleTLSObservation,
            any Error
        >,
        with result: Result<
            RivetDeviceAppleTLSObservation,
            RivetDeviceAppleTransportError
        >
    ) {
        switch result {
        case .success(let observation):
            continuation.resume(returning: observation)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
