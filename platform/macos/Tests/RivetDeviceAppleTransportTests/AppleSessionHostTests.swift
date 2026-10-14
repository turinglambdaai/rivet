#if os(macOS)
import Foundation
import RivetDevice
import RivetDeviceSession
import Testing
@testable import RivetDeviceAppleTransport

private let sessionHostApplicationID = "com.example.session-host"
private let sessionHostFingerprint = Data(
    repeating: 0x51,
    count: rivetDeviceFingerprintSize
)
private let sessionHostClientNonce = Data(
    repeating: 0x61,
    count: rivetDevicePairingNonceSize
)
private let sessionHostServerNonce = Data(
    repeating: 0x62,
    count: rivetDevicePairingNonceSize
)
private let sessionHostCredential = Data(
    repeating: 0x63,
    count: rivetDeviceCredentialSize
)
private let sessionHostDummyCredential = Data(
    repeating: 0x64,
    count: rivetDeviceCredentialSize
)
private let sessionHostDeviceID = UUID(
    uuidString: "00112233-4455-6677-8899-aabbccddeeff"
)!
private let sessionHostSessionID = UUID(
    uuidString: "ffeeddcc-bbaa-9988-7766-554433221100"
)!

private actor SessionHostStore: RivetDevicePairingStore {
    private var values: [UUID: RivetDeviceStoredPairing]

    init(_ values: [RivetDeviceStoredPairing] = []) {
        self.values = Dictionary(uniqueKeysWithValues: values.map {
            ($0.device.id, $0)
        })
    }

    func save(_ pairing: RivetDeviceStoredPairing) async throws {
        values[pairing.device.id] = pairing
    }

    func load(deviceID: UUID) async throws -> RivetDeviceStoredPairing? {
        values[deviceID]
    }

    func pairedDevices() async throws -> [RivetDevicePairedDevice] {
        values.values.map(\.device)
    }

    func remove(deviceID: UUID) async throws {
        values[deviceID] = nil
    }
}

private actor SessionHostRandom: RivetDeviceRandomBytesGenerator {
    private var values: [Data]

    init(_ values: [Data]) {
        self.values = values
    }

    func randomBytes(count: Int) async throws -> Data {
        guard !values.isEmpty else {
            throw RivetDeviceAppleSessionHostError.invalidState
        }
        let value = values.removeFirst()
        guard value.count == count else {
            throw RivetDeviceAppleSessionHostError.invalidConfiguration
        }
        return value
    }
}

private final class SessionHostUUIDs: RivetDeviceSessionUUIDGenerator,
    @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID]

    init(_ values: [UUID]) {
        self.values = values
    }

    func nextUUID() -> UUID {
        lock.withLock { values.removeFirst() }
    }
}

private final class SessionHostByteConnection: RivetDeviceAppleByteConnection,
    @unchecked Sendable {
    private struct PendingReceive {
        let maximumLength: Int
        let continuation: CheckedContinuation<Data?, any Error>
    }

    private let lock = NSLock()
    private var chunks: [Data] = []
    private var pending: PendingReceive?
    private var sentValues: [Data] = []
    private var cancellationCount = 0

    init(chunks: [Data] = []) {
        self.chunks = chunks
    }

    func start(timeout: TimeInterval) async throws -> RivetDeviceAppleTLSObservation {
        RivetDeviceAppleTLSObservation(
            applicationProtocol: rivetDeviceAppleApplicationProtocol,
            protocolVersion: 0x0304,
            cipherSuite: 0x1301,
            serverFingerprint: nil
        )
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

private actor SessionHostRecorder {
    private(set) var prompts: [RivetDeviceApplePairingPrompt] = []
    private(set) var acceptances: [RivetDeviceSessionAcceptance] = []
    private(set) var applicationBytes: [Data] = []

    func record(prompt: RivetDeviceApplePairingPrompt) {
        prompts.append(prompt)
    }

    func record(acceptance: RivetDeviceSessionAcceptance, bytes: Data?) {
        acceptances.append(acceptance)
        if let bytes {
            applicationBytes.append(bytes)
        }
    }
}

private func sessionHostStoredPairing(
    now: Date = Date()
) -> RivetDeviceStoredPairing {
    RivetDeviceStoredPairing(
        device: RivetDevicePairedDevice(
            id: sessionHostDeviceID,
            applicationID: sessionHostApplicationID,
            name: "Test Phone",
            scopeNames: ["reader"],
            serverFingerprint: sessionHostFingerprint,
            createdAt: now.addingTimeInterval(-100),
            lastUsedAt: now.addingTimeInterval(-100)
        ),
        credential: sessionHostCredential
    )
}

private func decodeSessionHostMessages(
    _ records: [Data]
) throws -> [RivetDeviceSessionMessage] {
    try records.map { record in
        var decoder = RivetDeviceSessionRecordDecoder()
        let messages = try decoder.append(record)
        try decoder.finish()
        return try #require(messages.first)
    }
}

private func waitForSessionHost(
    _ predicate: @escaping @Sendable () async -> Bool
) async {
    for _ in 0..<500 {
        if await predicate() {
            return
        }
        await Task.yield()
    }
}

@Test func appleSessionHostAuthenticatesBeforeLendingApplicationBytes() async throws {
    let startedAt = Date()
    let pairing = sessionHostStoredPairing(now: startedAt)
    let store = SessionHostStore([pairing])
    let proof = try RivetDeviceSessionAuthentication.proof(
        credential: sessionHostCredential,
        applicationID: sessionHostApplicationID,
        serverFingerprint: sessionHostFingerprint,
        deviceID: sessionHostDeviceID,
        clientNonce: sessionHostClientNonce,
        serverNonce: sessionHostServerNonce
    )
    var input = try encodeRivetDeviceSessionRecord(.authenticate(
        applicationID: sessionHostApplicationID,
        deviceID: sessionHostDeviceID,
        clientNonce: sessionHostClientNonce
    ))
    input.append(try encodeRivetDeviceSessionRecord(.authProof(proof)))
    let applicationBytes = Data([0x52, 0x56, 0x54, 0x31, 1, 2, 3])
    input.append(applicationBytes)

    let bytes = SessionHostByteConnection(chunks: [input])
    let connection = try RivetDeviceAppleConnection(driver: bytes)
    let recorder = SessionHostRecorder()
    let host = try RivetDeviceAppleSessionHost(
        connection: connection,
        serverFactory: { startedAt in
            try RivetDeviceSessionServer(
                applicationID: sessionHostApplicationID,
                serverFingerprint: sessionHostFingerprint,
                store: store,
                pairingCoordinator: RivetDevicePairingCoordinator(store: store),
                random: SessionHostRandom([
                    sessionHostServerNonce,
                    sessionHostDummyCredential
                ]),
                uuidGenerator: SessionHostUUIDs([sessionHostSessionID]),
                startedAt: startedAt
            )
        },
        pairingPromptHandler: { prompt in
            await recorder.record(prompt: prompt)
        },
        applicationHandler: { acceptance, connection in
            let received = try await connection.receiveApplicationBytes(
                maximumLength: 64
            )
            await recorder.record(acceptance: acceptance, bytes: received)
        }
    )

    try await host.run()
    let messages = try decodeSessionHostMessages(bytes.sent)
    #expect(messages.count == 2)
    guard case .authChallenge(let challengeNonce) = messages[0],
          case .accept(
            let acceptedSessionID,
            let scopeNames,
            let maximumPayload,
            let maximumPending
          ) = messages[1] else {
        Issue.record("session host did not complete reconnect authentication")
        return
    }
    #expect(challengeNonce == sessionHostServerNonce)
    #expect(acceptedSessionID == sessionHostSessionID)
    #expect(scopeNames == ["reader"])
    #expect(maximumPayload == rivetDeviceDefaultMaximumMessageSize)
    #expect(maximumPending == rivetDeviceDefaultMaximumPendingRequests)
    #expect(await recorder.prompts.isEmpty)
    #expect(await recorder.acceptances.map(\.sessionID) == [sessionHostSessionID])
    #expect(await recorder.applicationBytes == [applicationBytes])
    #expect(bytes.cancellations == 1)
}

@Test func appleSessionHostRequiresExplicitDesktopPairingConfirmation() async throws {
    let now = Date()
    let store = SessionHostStore()
    let coordinator = RivetDevicePairingCoordinator(
        store: store,
        random: SessionHostRandom([
            sessionHostServerNonce,
            sessionHostCredential
        ])
    )
    let window = try await coordinator.openWindow(
        applicationID: sessionHostApplicationID,
        serverFingerprint: sessionHostFingerprint,
        now: now
    )
    let bytes = SessionHostByteConnection(chunks: [
        try encodeRivetDeviceSessionRecord(.pairStart(
            applicationID: sessionHostApplicationID,
            windowID: window.id,
            deviceName: "Test Phone",
            clientNonce: sessionHostClientNonce
        ))
    ])
    let connection = try RivetDeviceAppleConnection(driver: bytes)
    let recorder = SessionHostRecorder()
    let host = try RivetDeviceAppleSessionHost(
        connection: connection,
        serverFactory: { startedAt in
            try RivetDeviceSessionServer(
                applicationID: sessionHostApplicationID,
                serverFingerprint: sessionHostFingerprint,
                store: store,
                pairingCoordinator: coordinator,
                random: SessionHostRandom([]),
                uuidGenerator: SessionHostUUIDs([sessionHostSessionID]),
                startedAt: startedAt
            )
        },
        pairingPromptHandler: { prompt in
            await recorder.record(prompt: prompt)
        },
        applicationHandler: { acceptance, _ in
            await recorder.record(acceptance: acceptance, bytes: nil)
        }
    )

    let run = Task { try await host.run() }
    await waitForSessionHost { await recorder.prompts.count == 1 }
    #expect(await recorder.prompts.count == 1)
    #expect(await recorder.acceptances.isEmpty)

    let challengeMessages = try decodeSessionHostMessages(bytes.sent)
    guard case .pairChallenge(let attemptID, _) = challengeMessages.first else {
        Issue.record("session host did not send a pairing challenge")
        return
    }
    bytes.feed(try encodeRivetDeviceSessionRecord(.pairDecision(
        attemptID: attemptID,
        confirmed: true
    )))
    for _ in 0..<20 {
        await Task.yield()
    }
    #expect(await recorder.acceptances.isEmpty)

    try await host.confirmPairing(grantedScopeNames: ["reader"])
    try await run.value
    #expect(await recorder.acceptances.map(\.sessionID) == [sessionHostSessionID])

    let messages = try decodeSessionHostMessages(bytes.sent)
    #expect(messages.count == 2)
    guard case .paired(
        let deviceID,
        let credential,
        let acceptedSessionID,
        let scopeNames,
        let maximumPayload,
        let maximumPending
    ) = messages[1] else {
        Issue.record("session host did not finish explicit pairing")
        return
    }
    #expect(credential == sessionHostCredential)
    #expect(acceptedSessionID == sessionHostSessionID)
    #expect(scopeNames == ["reader"])
    #expect(maximumPayload == rivetDeviceDefaultMaximumMessageSize)
    #expect(maximumPending == rivetDeviceDefaultMaximumPendingRequests)
    #expect(try await store.load(deviceID: deviceID)?.credential == credential)
}

@Test func appleSessionHostTimesOutAndCleansUpIdempotently() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let store = SessionHostStore()
    let bytes = SessionHostByteConnection()
    let connection = try RivetDeviceAppleConnection(driver: bytes)
    let host = try RivetDeviceAppleSessionHost(
        connection: connection,
        postTLSTimeout: 1,
        now: { now },
        wait: { _ in },
        serverFactory: { startedAt in
            try RivetDeviceSessionServer(
                applicationID: sessionHostApplicationID,
                serverFingerprint: sessionHostFingerprint,
                store: store,
                pairingCoordinator: RivetDevicePairingCoordinator(store: store),
                random: SessionHostRandom([]),
                uuidGenerator: SessionHostUUIDs([]),
                postTLSTimeout: 1,
                startedAt: startedAt
            )
        },
        pairingPromptHandler: { _ in },
        applicationHandler: { _, _ in
            Issue.record("timed-out host entered the application protocol")
        }
    )

    await #expect(throws: RivetDeviceAppleSessionHostError.timedOut) {
        try await host.run()
    }
    let cancellationsAfterTimeout = bytes.cancellations
    #expect(cancellationsAfterTimeout > 0)
    await host.cancel()
    await host.cancel()
    #expect(bytes.cancellations == cancellationsAfterTimeout)
    await #expect(throws: RivetDeviceAppleSessionHostError.invalidState) {
        try await host.run()
    }
}

@Test func cancellingAppleSessionHostRunClosesThePendingRead() async throws {
    let store = SessionHostStore()
    let bytes = SessionHostByteConnection()
    let connection = try RivetDeviceAppleConnection(driver: bytes)
    let host = try RivetDeviceAppleSessionHost(
        connection: connection,
        postTLSTimeout: 60,
        serverFactory: { startedAt in
            try RivetDeviceSessionServer(
                applicationID: sessionHostApplicationID,
                serverFingerprint: sessionHostFingerprint,
                store: store,
                pairingCoordinator: RivetDevicePairingCoordinator(store: store),
                random: SessionHostRandom([]),
                uuidGenerator: SessionHostUUIDs([]),
                postTLSTimeout: 60,
                startedAt: startedAt
            )
        },
        pairingPromptHandler: { _ in },
        applicationHandler: { _, _ in
            Issue.record("cancelled host entered the application protocol")
        }
    )
    let run = Task { try await host.run() }
    await waitForSessionHost { bytes.isWaitingForReceive }
    #expect(bytes.isWaitingForReceive)

    run.cancel()
    try await run.value
    #expect(bytes.cancellations > 0)
}
#endif
