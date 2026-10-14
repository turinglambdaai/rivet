import Foundation
import RivetDevice
import RivetDeviceSession
import Testing
@testable import RivetDeviceAppleTransport

private let sessionClientApplicationID = "com.example.session-client"
private let sessionClientFingerprint = Data(
    repeating: 0x51,
    count: rivetDeviceFingerprintSize
)
private let sessionClientObservedFingerprint = Data(
    repeating: 0x77,
    count: rivetDeviceFingerprintSize
)
private let sessionClientClientNonce = Data(
    repeating: 0xa2,
    count: rivetDevicePairingNonceSize
)
private let sessionClientServerNonce = Data(
    repeating: 0x62,
    count: rivetDevicePairingNonceSize
)
private let sessionClientCredential = Data(
    repeating: 0x63,
    count: rivetDeviceCredentialSize
)
private let sessionClientNewCredential = Data(
    repeating: 0xb5,
    count: rivetDeviceCredentialSize
)
private let sessionClientDeviceID = UUID(
    uuidString: "00112233-4455-6677-8899-aabbccddeeff"
)!
private let sessionClientWindowID = UUID(
    uuidString: "10213243-5465-7687-98a9-bacbdcedfe0f"
)!
private let sessionClientAttemptID = UUID(
    uuidString: "aabbccdd-eeff-0011-2233-445566778899"
)!
private let sessionClientSessionID = UUID(
    uuidString: "ffeeddcc-bbaa-9988-7766-554433221100"
)!

private actor SessionClientRandom: RivetDeviceRandomBytesGenerator {
    func randomBytes(count: Int) async throws -> Data {
        guard count == rivetDevicePairingNonceSize else {
            throw RivetDeviceAppleSessionClientError.invalidConfiguration
        }
        return sessionClientClientNonce
    }
}

private actor SessionClientCredentialStore:
    RivetDeviceAppleSessionCredentialStore {
    enum Mode {
        case succeed
        case fail
    }

    let mode: Mode
    private(set) var saves: [(deviceID: UUID, credential: Data,
                              serverFingerprint: Data)] = []
    var recorder: SessionClientRecorder?

    init(
        mode: Mode = .succeed,
        recorder: SessionClientRecorder? = nil
    ) {
        self.mode = mode
        self.recorder = recorder
    }

    func savePairingCredential(
        deviceID: UUID,
        credential: Data,
        serverFingerprint: Data
    ) async throws {
        if case .fail = mode {
            throw RivetDeviceAppleSessionClientError.invalidState
        }
        saves.append((deviceID, credential, serverFingerprint))
        await recorder?.recordSaved()
    }
}

/// Single ordered log so tests can pin that the pairing code is surfaced
/// before the decision, and the credential is persisted before acceptance.
private actor SessionClientRecorder {
    enum Event: Equatable {
        case code(String)
        case saved
        case accepted
    }

    private(set) var events: [Event] = []
    private(set) var acceptances: [RivetDeviceSessionClientAcceptance] = []
    private(set) var applicationBytes: [Data] = []

    func record(code: String) {
        events.append(.code(code))
    }

    func recordSaved() {
        events.append(.saved)
    }

    func record(acceptance: RivetDeviceSessionClientAcceptance, bytes: Data?) {
        events.append(.accepted)
        acceptances.append(acceptance)
        if let bytes {
            applicationBytes.append(bytes)
        }
    }
}

private final class SessionClientByteConnection: RivetDeviceAppleByteConnection,
    @unchecked Sendable {
    private struct PendingReceive {
        let maximumLength: Int
        let continuation: CheckedContinuation<Data?, any Error>
    }

    private let lock = NSLock()
    private var chunks: [Data]
    private var pending: PendingReceive?
    private var sentValues: [Data] = []
    private var cancellationCount = 0
    private let observation: RivetDeviceAppleTLSObservation
    private let startError: RivetDeviceAppleTransportError?

    init(
        chunks: [Data] = [],
        observation: RivetDeviceAppleTLSObservation,
        startError: RivetDeviceAppleTransportError? = nil
    ) {
        self.chunks = chunks
        self.observation = observation
        self.startError = startError
    }

    func start(timeout: TimeInterval) async throws
        -> RivetDeviceAppleTLSObservation {
        if let startError {
            throw startError
        }
        return observation
    }

    func send(_ data: Data) async throws {
        lock.withLock { sentValues.append(data) }
    }

    func receive(maximumLength: Int) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            let immediate: Data?? = lock.withLock {
                if cancellationCount > 0 {
                    return .some(nil)
                }
                if !chunks.isEmpty {
                    return .some(take(maximumLength: maximumLength))
                }
                pending = PendingReceive(
                    maximumLength: maximumLength,
                    continuation: continuation
                )
                return nil
            }
            if let immediate {
                continuation.resume(returning: immediate)
            }
        }
    }

    func cancel() {
        let continuation: CheckedContinuation<Data?, any Error>? = lock.withLock {
            cancellationCount += 1
            let value = pending?.continuation
            pending = nil
            return value
        }
        continuation?.resume(returning: nil)
    }

    func feed(_ data: Data) {
        let delivery: (CheckedContinuation<Data?, any Error>, Data)? = lock.withLock {
            chunks.append(data)
            guard let pending else {
                return nil
            }
            self.pending = nil
            return (
                pending.continuation,
                take(maximumLength: pending.maximumLength)
            )
        }
        delivery?.0.resume(returning: delivery?.1)
    }

    var sent: [Data] {
        lock.withLock { sentValues }
    }

    var cancellations: Int {
        lock.withLock { cancellationCount }
    }

    var isWaitingForReceive: Bool {
        lock.withLock { pending != nil }
    }

    private func take(maximumLength: Int) -> Data {
        let chunk = chunks.removeFirst()
        guard chunk.count > maximumLength else {
            return chunk
        }
        let split = chunk.index(chunk.startIndex, offsetBy: maximumLength)
        chunks.insert(Data(chunk[split...]), at: 0)
        return Data(chunk[..<split])
    }
}

private func sessionClientObservation(
    serverFingerprint: Data?
) -> RivetDeviceAppleTLSObservation {
    RivetDeviceAppleTLSObservation(
        applicationProtocol: rivetDeviceAppleApplicationProtocol,
        protocolVersion: 0x0304,
        cipherSuite: 0x1301,
        serverFingerprint: serverFingerprint
    )
}

private func sessionClientStoredPairing() -> RivetDeviceStoredPairing {
    let createdAt = Date(timeIntervalSince1970: 20_000)
    return RivetDeviceStoredPairing(
        device: RivetDevicePairedDevice(
            id: sessionClientDeviceID,
            applicationID: sessionClientApplicationID,
            name: "Test Desktop",
            scopeNames: ["reader"],
            serverFingerprint: sessionClientFingerprint,
            createdAt: createdAt,
            lastUsedAt: createdAt
        ),
        credential: sessionClientCredential
    )
}

private func decodeSessionClientMessages(
    _ records: [Data]
) throws -> [RivetDeviceSessionMessage] {
    try records.map { record in
        var decoder = RivetDeviceSessionRecordDecoder()
        let messages = try decoder.append(record)
        try decoder.finish()
        return try #require(messages.first)
    }
}

private func waitForSessionClient(
    _ predicate: @escaping @Sendable () async -> Bool
) async {
    for _ in 0..<500 {
        if await predicate() {
            return
        }
        await Task.yield()
    }
}

/// Connection factory that records every configured TLS policy and serves a
/// pre-built fake byte connection, keeping the test deterministic.
private final class SessionClientConnectionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var contexts: [RivetDeviceAppleClientTLSContext] = []
    let driver: SessionClientByteConnection

    init(driver: SessionClientByteConnection) {
        self.driver = driver
    }

    lazy var factory: RivetDeviceAppleSessionClient.ConnectionFactory = {
        [self] tls in
        lock.withLock { contexts.append(tls) }
        return try RivetDeviceAppleConnection(driver: driver)
    }

    var configured: [RivetDeviceAppleClientTLSContext] {
        lock.withLock { contexts }
    }
}

private func sessionClientAcceptMessage() throws -> Data {
    try encodeRivetDeviceSessionRecord(.accept(
        sessionID: sessionClientSessionID,
        scopeNames: ["reader"],
        maximumPayload: rivetDeviceDefaultMaximumMessageSize,
        maximumPending: rivetDeviceDefaultMaximumPendingRequests
    ))
}

@Test func appleSessionClientReconnectsPinnedAndLendsApplicationBytes()
    async throws {
    let applicationBytes = Data([0x52, 0x56, 0x54, 0x31, 1, 2, 3])
    let proof = try RivetDeviceSessionAuthentication.proof(
        credential: sessionClientCredential,
        applicationID: sessionClientApplicationID,
        serverFingerprint: sessionClientFingerprint,
        deviceID: sessionClientDeviceID,
        clientNonce: sessionClientClientNonce,
        serverNonce: sessionClientServerNonce
    )
    let driver = SessionClientByteConnection(
        chunks: [
            try encodeRivetDeviceSessionRecord(.authChallenge(
                serverNonce: sessionClientServerNonce
            )),
            try sessionClientAcceptMessage(),
            applicationBytes
        ],
        observation: sessionClientObservation(
            serverFingerprint: sessionClientFingerprint
        )
    )
    let connections = SessionClientConnectionRecorder(driver: driver)
    let store = SessionClientCredentialStore()
    let recorder = SessionClientRecorder()
    let client = try RivetDeviceAppleSessionClient(
        intent: .reconnect(pairing: sessionClientStoredPairing()),
        credentialStore: store,
        now: Date.init,
        wait: { interval in try await Task.sleep(for: .seconds(interval)) },
        random: SessionClientRandom(),
        connectionFactory: connections.factory,
        clientFactory: { startedAt, materials in
            guard case .reconnect(let pairing, let clientNonce) = materials
            else {
                Issue.record("reconnect run received pairing materials")
                throw RivetDeviceAppleSessionClientError.invalidState
            }
            return try RivetDeviceSessionClient(
                reconnectApplicationID: pairing.device.applicationID,
                deviceID: pairing.device.id,
                credential: pairing.credential,
                serverFingerprint: pairing.device.serverFingerprint,
                clientNonce: clientNonce,
                startedAt: startedAt
            )
        },
        pairingCodeHandler: { _ in
            Issue.record("reconnect must never show a pairing code")
        },
        applicationHandler: { acceptance, connection in
            let received = try await connection.receiveApplicationBytes(
                maximumLength: 64
            )
            await recorder.record(acceptance: acceptance, bytes: received)
        }
    )

    try await client.run()

    let messages = try decodeSessionClientMessages(driver.sent)
    #expect(messages.count == 2)
    guard case .authenticate(
        let applicationID, let deviceID, let clientNonce
    ) = messages.first else {
        Issue.record("session client did not authenticate first")
        return
    }
    #expect(applicationID == sessionClientApplicationID)
    #expect(deviceID == sessionClientDeviceID)
    #expect(clientNonce == sessionClientClientNonce)
    guard case .authProof(let sentProof) = messages[1] else {
        Issue.record("session client did not answer the auth challenge")
        return
    }
    #expect(sentProof == proof)

    #expect(connections.configured.count == 1)
    #expect(
        connections.configured[0].configuredAuthentication ==
            .pinned(sessionClientFingerprint)
    )
    let acceptance = try #require(await recorder.acceptances.first)
    #expect(acceptance.sessionID == sessionClientSessionID)
    #expect(acceptance.deviceID == sessionClientDeviceID)
    #expect(acceptance.scopeNames == ["reader"])
    #expect(await recorder.applicationBytes == [applicationBytes])
    #expect(await store.saves.isEmpty)
    #expect(driver.cancellations == 1)
}

@Test func appleSessionClientRejectsAuthenticationWithoutPairingFallback()
    async throws {
    let driver = SessionClientByteConnection(
        chunks: [
            try encodeRivetDeviceSessionRecord(.reject(.authenticationFailed))
        ],
        observation: sessionClientObservation(
            serverFingerprint: sessionClientFingerprint
        )
    )
    let connections = SessionClientConnectionRecorder(driver: driver)
    let store = SessionClientCredentialStore()
    let client = try RivetDeviceAppleSessionClient(
        intent: .reconnect(pairing: sessionClientStoredPairing()),
        credentialStore: store,
        now: Date.init,
        wait: { interval in try await Task.sleep(for: .seconds(interval)) },
        random: SessionClientRandom(),
        connectionFactory: connections.factory,
        clientFactory: { startedAt, materials in
            guard case .reconnect(let pairing, let clientNonce) = materials
            else {
                throw RivetDeviceAppleSessionClientError.invalidState
            }
            return try RivetDeviceSessionClient(
                reconnectApplicationID: pairing.device.applicationID,
                deviceID: pairing.device.id,
                credential: pairing.credential,
                serverFingerprint: pairing.device.serverFingerprint,
                clientNonce: clientNonce,
                startedAt: startedAt
            )
        },
        pairingCodeHandler: { _ in
            Issue.record("rejected authentication must not fall back to pairing")
        },
        applicationHandler: { _, _ in
            Issue.record("rejected authentication entered the application protocol")
        }
    )

    await #expect(throws: RivetDeviceAppleSessionClientError.rejected(
        .authenticationFailed
    )) {
        try await client.run()
    }
    let messages = try decodeSessionClientMessages(driver.sent)
    guard case .authenticate = messages.first else {
        Issue.record("expected a single authenticate attempt")
        return
    }
    #expect(messages.count == 1)
    #expect(await store.saves.isEmpty)
    #expect(driver.cancellations > 0)
}

@Test func appleSessionClientPairingPersistsCredentialBeforeApplication()
    async throws {
    let expectedCode = try RivetDevicePairingTranscript.verificationCode(
        applicationID: sessionClientApplicationID,
        serverFingerprint: sessionClientObservedFingerprint,
        clientNonce: sessionClientClientNonce,
        serverNonce: sessionClientServerNonce
    )
    let driver = SessionClientByteConnection(
        chunks: [
            try encodeRivetDeviceSessionRecord(.pairChallenge(
                attemptID: sessionClientAttemptID,
                serverNonce: sessionClientServerNonce
            ))
        ],
        observation: sessionClientObservation(
            serverFingerprint: sessionClientObservedFingerprint
        )
    )
    let connections = SessionClientConnectionRecorder(driver: driver)
    let recorder = SessionClientRecorder()
    let store = SessionClientCredentialStore(recorder: recorder)
    let client = try RivetDeviceAppleSessionClient(
        intent: .pair(
            applicationID: sessionClientApplicationID,
            windowID: sessionClientWindowID,
            deviceName: "Test Phone"
        ),
        credentialStore: store,
        now: Date.init,
        wait: { interval in try await Task.sleep(for: .seconds(interval)) },
        random: SessionClientRandom(),
        connectionFactory: connections.factory,
        clientFactory: { startedAt, materials in
            guard case .pair(
                let applicationID, let windowID, let deviceName,
                let observedFingerprint, let clientNonce
            ) = materials else {
                Issue.record("pairing run received reconnect materials")
                throw RivetDeviceAppleSessionClientError.invalidState
            }
            return try RivetDeviceSessionClient(
                pairingApplicationID: applicationID,
                windowID: windowID,
                deviceName: deviceName,
                serverFingerprint: observedFingerprint,
                clientNonce: clientNonce,
                startedAt: startedAt
            )
        },
        pairingCodeHandler: { code in
            await recorder.record(code: code.verificationCode)
        },
        applicationHandler: { acceptance, _ in
            await recorder.record(acceptance: acceptance, bytes: nil)
        }
    )

    let run = Task { try await client.run() }
    await waitForSessionClient { await recorder.events.contains(.code(expectedCode)) }
    #expect(await recorder.events == [.code(expectedCode)])

    // The device user compares the code and confirms explicitly.
    try await client.confirmPairing(true)
    let messages = try decodeSessionClientMessages(driver.sent)
    guard case .pairStart(
        let applicationID, let windowID, let deviceName, let clientNonce
    ) = messages.first else {
        Issue.record("session client did not start pairing")
        return
    }
    #expect(applicationID == sessionClientApplicationID)
    #expect(windowID == sessionClientWindowID)
    #expect(deviceName == "Test Phone")
    #expect(clientNonce == sessionClientClientNonce)
    guard case .pairDecision(let attemptID, let confirmed) = messages[1] else {
        Issue.record("confirmed pairing did not send the decision")
        return
    }
    #expect(attemptID == sessionClientAttemptID)
    #expect(confirmed)

    driver.feed(try encodeRivetDeviceSessionRecord(.paired(
        deviceID: sessionClientDeviceID,
        credential: sessionClientNewCredential,
        sessionID: sessionClientSessionID,
        scopeNames: ["reader"],
        maximumPayload: rivetDeviceDefaultMaximumMessageSize,
        maximumPending: rivetDeviceDefaultMaximumPendingRequests
    )))
    try await run.value

    #expect(await recorder.events == [
        .code(expectedCode), .saved, .accepted
    ])
    let acceptance = try #require(await recorder.acceptances.first)
    #expect(acceptance.sessionID == sessionClientSessionID)
    #expect(await store.saves.count == 1)
    let save = try #require(await store.saves.first)
    #expect(save.deviceID == sessionClientDeviceID)
    #expect(save.credential == sessionClientNewCredential)
    #expect(save.serverFingerprint == sessionClientObservedFingerprint)
    #expect(connections.configured.count == 1)
    #expect(
        connections.configured[0].configuredAuthentication ==
            .provisionalPairing
    )
    #expect(driver.cancellations == 1)
}

@Test func appleSessionClientSurfacesTheCodeWithoutAutoConfirming() async throws {
    let expectedCode = try RivetDevicePairingTranscript.verificationCode(
        applicationID: sessionClientApplicationID,
        serverFingerprint: sessionClientObservedFingerprint,
        clientNonce: sessionClientClientNonce,
        serverNonce: sessionClientServerNonce
    )
    let driver = SessionClientByteConnection(
        chunks: [
            try encodeRivetDeviceSessionRecord(.pairChallenge(
                attemptID: sessionClientAttemptID,
                serverNonce: sessionClientServerNonce
            ))
        ],
        observation: sessionClientObservation(
            serverFingerprint: sessionClientObservedFingerprint
        )
    )
    let connections = SessionClientConnectionRecorder(driver: driver)
    let store = SessionClientCredentialStore()
    let recorder = SessionClientRecorder()
    let client = try RivetDeviceAppleSessionClient(
        intent: .pair(
            applicationID: sessionClientApplicationID,
            windowID: sessionClientWindowID,
            deviceName: "Test Phone"
        ),
        credentialStore: store,
        now: Date.init,
        wait: { interval in try await Task.sleep(for: .seconds(interval)) },
        random: SessionClientRandom(),
        connectionFactory: connections.factory,
        clientFactory: { startedAt, materials in
            guard case .pair(
                _, let windowID, let deviceName,
                let observedFingerprint, let clientNonce
            ) = materials else {
                throw RivetDeviceAppleSessionClientError.invalidState
            }
            return try RivetDeviceSessionClient(
                pairingApplicationID: sessionClientApplicationID,
                windowID: windowID,
                deviceName: deviceName,
                serverFingerprint: observedFingerprint,
                clientNonce: clientNonce,
                startedAt: startedAt
            )
        },
        pairingCodeHandler: { code in
            await recorder.record(code: code.verificationCode)
        },
        applicationHandler: { _, _ in
            Issue.record("rejected pairing entered the application protocol")
        }
    )

    let run = Task { try await client.run() }
    await waitForSessionClient { await recorder.events.contains(.code(expectedCode)) }
    #expect(try decodeSessionClientMessages(driver.sent).count == 1)

    try await client.confirmPairing(false)
    let messages = try decodeSessionClientMessages(driver.sent)
    guard case .pairDecision(_, let confirmed) = messages.last else {
        Issue.record("explicit rejection did not send the decision")
        return
    }
    #expect(!confirmed)

    driver.feed(try encodeRivetDeviceSessionRecord(.reject(.pairingRejected)))
    await #expect(throws: RivetDeviceAppleSessionClientError.rejected(
        .pairingRejected
    )) {
        try await run.value
    }
    #expect(await store.saves.isEmpty)
    #expect(await recorder.acceptances.isEmpty)
}

@Test func appleSessionClientPairingPersistenceFailureClosesWithoutAcceptance()
    async throws {
    let driver = SessionClientByteConnection(
        chunks: [
            try encodeRivetDeviceSessionRecord(.pairChallenge(
                attemptID: sessionClientAttemptID,
                serverNonce: sessionClientServerNonce
            ))
        ],
        observation: sessionClientObservation(
            serverFingerprint: sessionClientObservedFingerprint
        )
    )
    let connections = SessionClientConnectionRecorder(driver: driver)
    let store = SessionClientCredentialStore(mode: .fail)
    let recorder = SessionClientRecorder()
    let client = try RivetDeviceAppleSessionClient(
        intent: .pair(
            applicationID: sessionClientApplicationID,
            windowID: sessionClientWindowID,
            deviceName: "Test Phone"
        ),
        credentialStore: store,
        now: Date.init,
        wait: { interval in try await Task.sleep(for: .seconds(interval)) },
        random: SessionClientRandom(),
        connectionFactory: connections.factory,
        clientFactory: { startedAt, materials in
            guard case .pair(
                _, let windowID, let deviceName,
                let observedFingerprint, let clientNonce
            ) = materials else {
                throw RivetDeviceAppleSessionClientError.invalidState
            }
            return try RivetDeviceSessionClient(
                pairingApplicationID: sessionClientApplicationID,
                windowID: windowID,
                deviceName: deviceName,
                serverFingerprint: observedFingerprint,
                clientNonce: clientNonce,
                startedAt: startedAt
            )
        },
        pairingCodeHandler: { code in
            await recorder.record(code: code.verificationCode)
        },
        applicationHandler: { _, _ in
            Issue.record("failed persistence entered the application protocol")
        }
    )

    let run = Task { try await client.run() }
    await waitForSessionClient { !(await recorder.events.isEmpty) }
    try await client.confirmPairing(true)
    driver.feed(try encodeRivetDeviceSessionRecord(.paired(
        deviceID: sessionClientDeviceID,
        credential: sessionClientNewCredential,
        sessionID: sessionClientSessionID,
        scopeNames: ["reader"],
        maximumPayload: rivetDeviceDefaultMaximumMessageSize,
        maximumPending: rivetDeviceDefaultMaximumPendingRequests
    )))

    await #expect(throws: RivetDeviceAppleSessionClientError
        .pairingPersistenceFailed) {
        try await run.value
    }
    #expect(await recorder.acceptances.isEmpty)
    #expect(await store.saves.isEmpty)
    #expect(driver.cancellations > 0)
}

@Test func appleSessionClientTimesOutAndCleansUpIdempotently() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let driver = SessionClientByteConnection(
        observation: sessionClientObservation(
            serverFingerprint: sessionClientFingerprint
        )
    )
    let connections = SessionClientConnectionRecorder(driver: driver)
    let store = SessionClientCredentialStore()
    let client = try RivetDeviceAppleSessionClient(
        intent: .reconnect(pairing: sessionClientStoredPairing()),
        credentialStore: store,
        postTLSTimeout: 1,
        pairingResponseTimeout: 300,
        now: { now },
        wait: { _ in },
        random: SessionClientRandom(),
        connectionFactory: connections.factory,
        clientFactory: { startedAt, materials in
            guard case .reconnect(let pairing, let clientNonce) = materials
            else {
                throw RivetDeviceAppleSessionClientError.invalidState
            }
            return try RivetDeviceSessionClient(
                reconnectApplicationID: pairing.device.applicationID,
                deviceID: pairing.device.id,
                credential: pairing.credential,
                serverFingerprint: pairing.device.serverFingerprint,
                clientNonce: clientNonce,
                timeout: 1,
                startedAt: startedAt
            )
        },
        pairingCodeHandler: { _ in },
        applicationHandler: { _, _ in
            Issue.record("timed-out client entered the application protocol")
        }
    )

    await #expect(throws: RivetDeviceAppleSessionClientError.timedOut) {
        try await client.run()
    }
    let cancellationsAfterTimeout = driver.cancellations
    #expect(cancellationsAfterTimeout > 0)
    await client.cancel()
    await client.cancel()
    #expect(driver.cancellations == cancellationsAfterTimeout)
    await #expect(throws: RivetDeviceAppleSessionClientError.invalidState) {
        try await client.run()
    }
}

@Test func appleSessionClientPairingDecisionTimesOut() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let driver = SessionClientByteConnection(
        observation: sessionClientObservation(
            serverFingerprint: sessionClientObservedFingerprint
        )
    )
    let connections = SessionClientConnectionRecorder(driver: driver)
    let store = SessionClientCredentialStore()
    let recorder = SessionClientRecorder()
    let client = try RivetDeviceAppleSessionClient(
        intent: .pair(
            applicationID: sessionClientApplicationID,
            windowID: sessionClientWindowID,
            deviceName: "Test Phone"
        ),
        credentialStore: store,
        postTLSTimeout: 1,
        pairingResponseTimeout: 300,
        now: { now },
        wait: { _ in },
        random: SessionClientRandom(),
        connectionFactory: connections.factory,
        clientFactory: { startedAt, materials in
            guard case .pair(
                _, let windowID, let deviceName,
                let observedFingerprint, let clientNonce
            ) = materials else {
                throw RivetDeviceAppleSessionClientError.invalidState
            }
            return try RivetDeviceSessionClient(
                pairingApplicationID: sessionClientApplicationID,
                windowID: windowID,
                deviceName: deviceName,
                serverFingerprint: observedFingerprint,
                clientNonce: clientNonce,
                timeout: 1,
                pairingResponseTimeout: 300,
                startedAt: startedAt
            )
        },
        pairingCodeHandler: { code in
            await recorder.record(code: code.verificationCode)
        },
        applicationHandler: { _, _ in
            Issue.record("timed-out pairing entered the application protocol")
        }
    )

    let run = Task { try await client.run() }
    await waitForSessionClient { !(await recorder.events.isEmpty) }
    await #expect(throws: RivetDeviceAppleSessionClientError.timedOut) {
        try await run.value
    }
    #expect(try decodeSessionClientMessages(driver.sent).count == 1)
    #expect(await store.saves.isEmpty)
    #expect(driver.cancellations > 0)
}

@Test func cancellingAppleSessionClientRunClosesThePendingRead() async throws {
    let driver = SessionClientByteConnection(
        observation: sessionClientObservation(
            serverFingerprint: sessionClientFingerprint
        )
    )
    let connections = SessionClientConnectionRecorder(driver: driver)
    let store = SessionClientCredentialStore()
    let client = try RivetDeviceAppleSessionClient(
        intent: .reconnect(pairing: sessionClientStoredPairing()),
        credentialStore: store,
        now: Date.init,
        wait: { interval in try await Task.sleep(for: .seconds(interval)) },
        random: SessionClientRandom(),
        connectionFactory: connections.factory,
        clientFactory: { startedAt, materials in
            guard case .reconnect(let pairing, let clientNonce) = materials
            else {
                throw RivetDeviceAppleSessionClientError.invalidState
            }
            return try RivetDeviceSessionClient(
                reconnectApplicationID: pairing.device.applicationID,
                deviceID: pairing.device.id,
                credential: pairing.credential,
                serverFingerprint: pairing.device.serverFingerprint,
                clientNonce: clientNonce,
                startedAt: startedAt
            )
        },
        pairingCodeHandler: { _ in },
        applicationHandler: { _, _ in
            Issue.record("cancelled client entered the application protocol")
        }
    )
    let run = Task { try await client.run() }
    await waitForSessionClient { driver.isWaitingForReceive }
    #expect(driver.isWaitingForReceive)

    run.cancel()
    try await run.value
    #expect(driver.cancellations > 0)
}

@Test func appleSessionClientFailsClosedOnMalformedPreface() async throws {
    let driver = SessionClientByteConnection(
        chunks: [Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07])],
        observation: sessionClientObservation(
            serverFingerprint: sessionClientFingerprint
        )
    )
    let connections = SessionClientConnectionRecorder(driver: driver)
    let store = SessionClientCredentialStore()
    let client = try RivetDeviceAppleSessionClient(
        intent: .reconnect(pairing: sessionClientStoredPairing()),
        credentialStore: store,
        now: Date.init,
        wait: { interval in try await Task.sleep(for: .seconds(interval)) },
        random: SessionClientRandom(),
        connectionFactory: connections.factory,
        clientFactory: { startedAt, materials in
            guard case .reconnect(let pairing, let clientNonce) = materials
            else {
                throw RivetDeviceAppleSessionClientError.invalidState
            }
            return try RivetDeviceSessionClient(
                reconnectApplicationID: pairing.device.applicationID,
                deviceID: pairing.device.id,
                credential: pairing.credential,
                serverFingerprint: pairing.device.serverFingerprint,
                clientNonce: clientNonce,
                startedAt: startedAt
            )
        },
        pairingCodeHandler: { _ in },
        applicationHandler: { _, _ in
            Issue.record("malformed preface entered the application protocol")
        }
    )

    await #expect(throws: RivetDeviceSessionProtocolError.invalidMagic) {
        try await client.run()
    }
    #expect(await store.saves.isEmpty)
    #expect(driver.cancellations > 0)
}

@Test func appleSessionClientPinMismatchNeverFallsBackToPairing() async throws {
    let driver = SessionClientByteConnection(
        observation: sessionClientObservation(
            serverFingerprint: sessionClientObservedFingerprint
        )
    )
    let connections = SessionClientConnectionRecorder(driver: driver)
    let store = SessionClientCredentialStore()
    let client = try RivetDeviceAppleSessionClient(
        intent: .reconnect(pairing: sessionClientStoredPairing()),
        credentialStore: store,
        now: Date.init,
        wait: { interval in try await Task.sleep(for: .seconds(interval)) },
        random: SessionClientRandom(),
        connectionFactory: connections.factory,
        clientFactory: { _, _ in
            Issue.record("pin mismatch constructed a session client")
            throw RivetDeviceAppleSessionClientError.invalidState
        },
        pairingCodeHandler: { _ in
            Issue.record("pin mismatch must not fall back to pairing")
        },
        applicationHandler: { _, _ in
            Issue.record("pin mismatch entered the application protocol")
        }
    )

    await #expect(throws: RivetDeviceAppleTransportError.serverPinMismatch) {
        try await client.run()
    }
    #expect(driver.sent.isEmpty)
    #expect(await store.saves.isEmpty)
    #expect(driver.cancellations > 0)
}

@Test func appleSessionClientFailsClosedWhenFingerprintUnavailable() async throws {
    let driver = SessionClientByteConnection(
        observation: sessionClientObservation(serverFingerprint: nil)
    )
    let connections = SessionClientConnectionRecorder(driver: driver)
    let store = SessionClientCredentialStore()
    let client = try RivetDeviceAppleSessionClient(
        intent: .pair(
            applicationID: sessionClientApplicationID,
            windowID: sessionClientWindowID,
            deviceName: "Test Phone"
        ),
        credentialStore: store,
        now: Date.init,
        wait: { interval in try await Task.sleep(for: .seconds(interval)) },
        random: SessionClientRandom(),
        connectionFactory: connections.factory,
        clientFactory: { _, _ in
            Issue.record("missing fingerprint constructed a session client")
            throw RivetDeviceAppleSessionClientError.invalidState
        },
        pairingCodeHandler: { _ in },
        applicationHandler: { _, _ in
            Issue.record("missing fingerprint entered the application protocol")
        }
    )

    await #expect(throws: RivetDeviceAppleTransportError.certificateUnavailable) {
        try await client.run()
    }
    #expect(driver.sent.isEmpty)
    #expect(await store.saves.isEmpty)
}

@Test func appleSessionClientRejectsInvalidConfiguration() throws {
    let shortPairing = RivetDeviceStoredPairing(
        device: RivetDevicePairedDevice(
            id: sessionClientDeviceID,
            applicationID: sessionClientApplicationID,
            name: "Test Desktop",
            scopeNames: ["reader"],
            serverFingerprint: Data(repeating: 0x51, count: 8),
            createdAt: Date(timeIntervalSince1970: 20_000),
            lastUsedAt: Date(timeIntervalSince1970: 20_000)
        ),
        credential: sessionClientCredential
    )
    let driver = SessionClientByteConnection(
        observation: sessionClientObservation(
            serverFingerprint: sessionClientFingerprint
        )
    )
    let connections = SessionClientConnectionRecorder(driver: driver)

    func makeClient(
        intent: RivetDeviceAppleSessionClientIntent,
        postTLSTimeout: TimeInterval = 10,
        pairingResponseTimeout: TimeInterval = 300
    ) throws -> RivetDeviceAppleSessionClient {
        try RivetDeviceAppleSessionClient(
            intent: intent,
            credentialStore: SessionClientCredentialStore(),
            postTLSTimeout: postTLSTimeout,
            pairingResponseTimeout: pairingResponseTimeout,
            now: Date.init,
            wait: { _ in },
            random: SessionClientRandom(),
            connectionFactory: connections.factory,
            clientFactory: { _, _ in
                throw RivetDeviceAppleSessionClientError.invalidState
            },
            pairingCodeHandler: { _ in },
            applicationHandler: { _, _ in }
        )
    }

    #expect(throws: RivetDeviceAppleSessionClientError.invalidConfiguration) {
        _ = try makeClient(
            intent: .reconnect(pairing: shortPairing)
        )
    }
    #expect(throws: RivetDeviceAppleSessionClientError.invalidConfiguration) {
        _ = try makeClient(
            intent: .reconnect(pairing: sessionClientStoredPairing()),
            postTLSTimeout: 0
        )
    }
    #expect(throws: RivetDeviceAppleSessionClientError.invalidConfiguration) {
        _ = try makeClient(
            intent: .reconnect(pairing: sessionClientStoredPairing()),
            pairingResponseTimeout: 0
        )
    }
    #expect(throws: RivetDeviceAppleSessionClientError.invalidConfiguration) {
        _ = try makeClient(
            intent: .pair(
                applicationID: "not an api name",
                windowID: sessionClientWindowID,
                deviceName: "Test Phone"
            )
        )
    }
    #expect(throws: RivetDeviceAppleSessionClientError.invalidConfiguration) {
        _ = try makeClient(
            intent: .pair(
                applicationID: sessionClientApplicationID,
                windowID: sessionClientWindowID,
                deviceName: ""
            )
        )
    }
}
