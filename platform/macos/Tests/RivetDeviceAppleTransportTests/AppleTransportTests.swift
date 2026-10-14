import CryptoKit
import Foundation
import RivetDevice
import RivetDeviceSession
import Testing
@testable import RivetDeviceAppleTransport

private let transportFingerprint = Data(
    repeating: 0x55,
    count: rivetDeviceFingerprintSize
)

private final class FakeByteConnection: RivetDeviceAppleByteConnection,
    @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data]
    private var sentRecords: [Data] = []
    private var cancelled = false

    private let startResult: Result<
        RivetDeviceAppleTLSObservation,
        RivetDeviceAppleTransportError
    >

    init(
        chunks: [Data] = [],
        startResult: Result<
            RivetDeviceAppleTLSObservation,
            RivetDeviceAppleTransportError
        > = .success(RivetDeviceAppleTLSObservation(
            applicationProtocol: rivetDeviceAppleApplicationProtocol,
            protocolVersion: 0x0303,
            cipherSuite: 0x1301,
            serverFingerprint: transportFingerprint
        ))
    ) {
        self.chunks = chunks
        self.startResult = startResult
    }

    func start(timeout: TimeInterval) async throws -> RivetDeviceAppleTLSObservation {
        try startResult.get()
    }

    func send(_ data: Data) async throws {
        lock.withLock { sentRecords.append(data) }
    }

    func receive(maximumLength: Int) async throws -> Data? {
        lock.withLock {
            guard !chunks.isEmpty else {
                return nil
            }
            let chunk = chunks.removeFirst()
            guard chunk.count > maximumLength else {
                return chunk
            }
            let split = chunk.index(chunk.startIndex, offsetBy: maximumLength)
            let prefix = Data(chunk[..<split])
            chunks.insert(Data(chunk[split...]), at: 0)
            return prefix
        }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }

    var sent: [Data] {
        lock.withLock { sentRecords }
    }

    var wasCancelled: Bool {
        lock.withLock { cancelled }
    }
}

private final class BlockingStartConnection: RivetDeviceAppleByteConnection,
    @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<
        RivetDeviceAppleTLSObservation,
        any Error
    >?
    private var cancelled = false

    var hasStarted: Bool {
        lock.withLock { continuation != nil }
    }

    func start(timeout: TimeInterval) async throws -> RivetDeviceAppleTLSObservation {
        try await withCheckedThrowingContinuation { continuation in
            let cancelImmediately = lock.withLock {
                if cancelled {
                    return true
                }
                self.continuation = continuation
                return false
            }
            if cancelImmediately {
                continuation.resume(
                    throwing: RivetDeviceAppleTransportError.connectionClosed
                )
            }
        }
    }

    func send(_ data: Data) async throws {}

    func receive(maximumLength: Int) async throws -> Data? {
        nil
    }

    func cancel() {
        let continuation = lock.withLock {
            cancelled = true
            let value = self.continuation
            self.continuation = nil
            return value
        }
        continuation?.resume(
            throwing: RivetDeviceAppleTransportError.connectionClosed
        )
    }
}

@Test func extractsAndHashesExactSubjectPublicKeyInfo() throws {
    let spki = derSequence(
        derSequence(derOID([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01])),
        derBitString(Data([0x01, 0x02, 0x03, 0x04]))
    )
    let certificate = syntheticCertificate(spki: spki, versioned: true)
    #expect(try RivetDeviceAppleSPKI.subjectPublicKeyInfo(
        certificateDER: certificate
    ) == spki)
    #expect(try RivetDeviceAppleSPKI.fingerprint(
        certificateDER: certificate
    ) == Data(SHA256.hash(data: spki)))

    let v1Certificate = syntheticCertificate(spki: spki, versioned: false)
    #expect(try RivetDeviceAppleSPKI.subjectPublicKeyInfo(
        certificateDER: v1Certificate
    ) == spki)
}

@Test func rejectsMalformedOrAmbiguousCertificateDER() throws {
    let spki = derSequence(derSequence(), derBitString(Data([1])))
    let certificate = syntheticCertificate(spki: spki, versioned: true)
    #expect(throws: RivetDeviceAppleCertificateError.malformedDER) {
        try RivetDeviceAppleSPKI.subjectPublicKeyInfo(
            certificateDER: certificate + Data([0])
        )
    }
    #expect(throws: RivetDeviceAppleCertificateError.malformedDER) {
        try RivetDeviceAppleSPKI.subjectPublicKeyInfo(
            certificateDER: Data([0x30, 0x80, 0, 0])
        )
    }
    #expect(throws: (any Error).self) {
        try RivetDeviceAppleSPKI.subjectPublicKeyInfo(
            certificateDER: Data(certificate.dropLast())
        )
    }
}

@Test func clientTLSPolicyRequiresAFullPin() throws {
    #expect(throws: RivetDeviceAppleTransportError.invalidConfiguration) {
        try RivetDeviceAppleClientTLSContext(
            authentication: .pinned(Data(repeating: 0, count: 31))
        )
    }
    _ = try RivetDeviceAppleClientTLSContext(
        authentication: .pinned(transportFingerprint)
    )
    _ = try RivetDeviceAppleClientTLSContext(
        authentication: .provisionalPairing
    )

    let singleUse = try RivetDeviceAppleClientTLSContext(
        authentication: .pinned(transportFingerprint)
    )
    _ = try RivetDeviceAppleConnection(
        endpoint: .hostPort(host: "127.0.0.1", port: 9),
        tls: singleUse
    )
    #expect(throws: RivetDeviceAppleTransportError.invalidConfiguration) {
        try RivetDeviceAppleConnection(
            endpoint: .hostPort(host: "127.0.0.1", port: 9),
            tls: singleUse
        )
    }

    #expect(RivetDeviceAppleTLS.acceptsCipherSuite(0x1301))
    #expect(RivetDeviceAppleTLS.acceptsCipherSuite(0xc02f))
    #expect(!RivetDeviceAppleTLS.acceptsCipherSuite(0x002f))
}

@Test func streamPreservesOrderingAndSwitchesToApplicationBytes() async throws {
    let challenge = RivetDeviceSessionMessage.authChallenge(
        serverNonce: Data(repeating: 0x11, count: rivetDevicePairingNonceSize)
    )
    let accept = RivetDeviceSessionMessage.accept(
        sessionID: UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!,
        scopeNames: ["reader"],
        maximumPayload: rivetDeviceDefaultMaximumMessageSize,
        maximumPending: rivetDeviceDefaultMaximumPendingRequests
    )
    var coalesced = try encodeRivetDeviceSessionRecord(challenge)
    coalesced.append(try encodeRivetDeviceSessionRecord(accept))
    let helloPrefix = Data([0x52, 0x56, 0x54, 0x31, 0x01])
    coalesced.append(helloPrefix)

    let driver = FakeByteConnection(chunks: [Data(coalesced.prefix(3)), Data(coalesced.dropFirst(3))])
    let connection = try RivetDeviceAppleConnection(driver: driver)
    let observation = try await connection.start()
    #expect(observation.serverFingerprint == transportFingerprint)
    #expect(try await connection.receiveSessionMessage() == challenge)
    #expect(try await connection.receiveSessionMessage() == accept)
    try await connection.beginApplicationProtocol()
    #expect(try await connection.receiveApplicationBytes(maximumLength: 64) == helloPrefix)

    let requestBytes = Data([1, 2, 3])
    try await connection.sendApplicationBytes(requestBytes)
    #expect(driver.sent == [requestBytes])
}

@Test func malformedPrefaceFailsClosedAndCannotDowngradeToRVT1() async throws {
    let driver = FakeByteConnection(chunks: [
        Data([0x52, 0x56, 0x54, 0x31, 1, 1, 0, 0])
    ])
    let connection = try RivetDeviceAppleConnection(driver: driver)
    _ = try await connection.start()
    await #expect(throws: RivetDeviceSessionProtocolError.invalidMagic) {
        try await connection.receiveSessionMessage()
    }
    #expect(driver.wasCancelled)
    await #expect(throws: RivetDeviceAppleTransportError.invalidPhase) {
        try await connection.beginApplicationProtocol()
    }
}

@Test func failedStartAndInvalidOperationsCloseOrReject() async throws {
    let failedDriver = FakeByteConnection(startResult: .failure(.connectionTimedOut))
    let failed = try RivetDeviceAppleConnection(driver: failedDriver)
    await #expect(throws: RivetDeviceAppleTransportError.connectionTimedOut) {
        try await failed.start()
    }
    #expect(failedDriver.wasCancelled)

    let driver = FakeByteConnection()
    let connection = try RivetDeviceAppleConnection(driver: driver)
    await #expect(throws: RivetDeviceAppleTransportError.invalidPhase) {
        try await connection.receiveSessionMessage()
    }
    _ = try await connection.start()
    await #expect(throws: RivetDeviceAppleTransportError.invalidPhase) {
        try await connection.receiveApplicationBytes(maximumLength: 1)
    }
}

@Test func startIsSingleFlightAndCancellationCannotResurrectIt() async throws {
    let driver = BlockingStartConnection()
    let connection = try RivetDeviceAppleConnection(driver: driver)
    let firstStart = Task {
        try await connection.start()
    }
    for _ in 0..<100 where !driver.hasStarted {
        await Task.yield()
    }
    #expect(driver.hasStarted)
    await #expect(throws: RivetDeviceAppleTransportError.invalidPhase) {
        try await connection.start()
    }
    await connection.cancel()
    await #expect(throws: RivetDeviceAppleTransportError.connectionClosed) {
        try await firstStart.value
    }
    await #expect(throws: RivetDeviceAppleTransportError.invalidPhase) {
        try await connection.beginApplicationProtocol()
    }
}

private func syntheticCertificate(spki: Data, versioned: Bool) -> Data {
    var tbsFields: [Data] = []
    if versioned {
        tbsFields.append(derElement(tag: 0xa0, content: derInteger(2)))
    }
    tbsFields.append(derInteger(1))
    tbsFields.append(derSequence()) // signature
    tbsFields.append(derSequence()) // issuer
    tbsFields.append(derSequence()) // validity
    tbsFields.append(derSequence()) // subject
    tbsFields.append(spki)
    return derSequence(
        derSequence(tbsFields),
        derSequence(),
        derBitString(Data([0xaa]))
    )
}

private func derSequence(_ elements: Data...) -> Data {
    derSequence(elements)
}

private func derSequence(_ elements: [Data]) -> Data {
    derElement(tag: 0x30, content: elements.reduce(into: Data()) { $0.append($1) })
}

private func derInteger(_ value: UInt8) -> Data {
    derElement(tag: 0x02, content: Data([value]))
}

private func derOID(_ value: [UInt8]) -> Data {
    derElement(tag: 0x06, content: Data(value))
}

private func derBitString(_ value: Data) -> Data {
    derElement(tag: 0x03, content: Data([0]) + value)
}

private func derElement(tag: UInt8, content: Data) -> Data {
    precondition(content.count < 128)
    return Data([tag, UInt8(content.count)]) + content
}
