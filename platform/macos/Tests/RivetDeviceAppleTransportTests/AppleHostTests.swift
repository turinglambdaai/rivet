#if os(macOS)
import CryptoKit
import Foundation
import Network
import RivetDevice
import Security
import Testing
@testable import RivetDeviceAppleTransport

private let hostFingerprintA = Data(
    repeating: 0xa1,
    count: rivetDeviceFingerprintSize
)
private let hostFingerprintB = Data(
    repeating: 0xb2,
    count: rivetDeviceFingerprintSize
)

private final class MemoryIdentityClient: RivetDeviceAppleIdentityClient,
    @unchecked Sendable {
    enum Call: Equatable {
        case load(String)
        case create(String)
        case remove(String)
    }

    private let lock = NSLock()
    private var stored: RivetDeviceAppleServerIdentity?
    private var createValues: [RivetDeviceAppleServerIdentity]
    private var recorded: [Call] = []

    init(createValues: [RivetDeviceAppleServerIdentity]) {
        self.createValues = createValues
    }

    var calls: [Call] {
        lock.withLock { recorded }
    }

    func load(label: String) throws -> RivetDeviceAppleServerIdentity? {
        lock.withLock {
            recorded.append(.load(label))
            return stored
        }
    }

    func create(
        label: String,
        now: Date
    ) throws -> RivetDeviceAppleServerIdentity {
        try lock.withLock {
            recorded.append(.create(label))
            guard !createValues.isEmpty else {
                throw RivetDeviceAppleIdentityError.cryptographicFailure
            }
            let value = createValues.removeFirst()
            stored = value
            return value
        }
    }

    func remove(label: String) throws {
        lock.withLock {
            recorded.append(.remove(label))
            stored = nil
        }
    }
}

private final class ListenerByteConnection: RivetDeviceAppleByteConnection,
    @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var wasCancelled: Bool {
        lock.withLock { cancelled }
    }

    func start(timeout: TimeInterval) async throws -> RivetDeviceAppleTLSObservation {
        RivetDeviceAppleTLSObservation(
            applicationProtocol: rivetDeviceAppleApplicationProtocol,
            protocolVersion: 0x0304,
            cipherSuite: 0x1301,
            serverFingerprint: nil
        )
    }

    func send(_ data: Data) async throws {}

    func receive(maximumLength: Int) async throws -> Data? {
        nil
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}

private final class FakePendingConnection: RivetDeviceApplePendingConnection,
    @unchecked Sendable {
    private let lock = NSLock()
    let bytes = ListenerByteConnection()
    private var makeCount = 0
    private var cancelCount = 0

    var connectionsMade: Int {
        lock.withLock { makeCount }
    }

    var cancellations: Int {
        lock.withLock { cancelCount }
    }

    func makeConnection(
        timeout: TimeInterval
    ) throws -> RivetDeviceAppleConnection {
        lock.withLock { makeCount += 1 }
        return try RivetDeviceAppleConnection(driver: bytes, timeout: timeout)
    }

    func cancel() {
        lock.withLock { cancelCount += 1 }
        bytes.cancel()
    }
}

private final class FakeListenerDriver: RivetDeviceAppleListenerDriver,
    @unchecked Sendable {
    enum Event: Equatable {
        case service(RivetDeviceAppleBonjourService?)
        case cancel
    }

    private let lock = NSLock()
    private let port: UInt16
    private var connectionHandler: (@Sendable (
        any RivetDeviceApplePendingConnection
    ) -> Void)?
    private var stopHandler: (@Sendable (
        RivetDeviceAppleListenerDriverStop
    ) -> Void)?
    private var cancelCount = 0
    private var recordedEvents: [Event] = []

    init(port: UInt16) {
        self.port = port
    }

    var cancellations: Int {
        lock.withLock { cancelCount }
    }

    var events: [Event] {
        lock.withLock { recordedEvents }
    }

    func start(
        timeout: TimeInterval,
        queue: DispatchQueue,
        onConnection: @escaping @Sendable (
            any RivetDeviceApplePendingConnection
        ) -> Void,
        onStop: @escaping @Sendable (RivetDeviceAppleListenerDriverStop) -> Void
    ) async throws -> UInt16 {
        lock.withLock {
            connectionHandler = onConnection
            stopHandler = onStop
        }
        return port
    }

    func setBonjourService(_ service: RivetDeviceAppleBonjourService?) {
        lock.withLock { recordedEvents.append(.service(service)) }
    }

    func cancel() {
        lock.withLock {
            cancelCount += 1
            recordedEvents.append(.cancel)
        }
    }

    func emit(_ connection: any RivetDeviceApplePendingConnection) {
        lock.withLock { connectionHandler }?(connection)
    }

    func stop(_ reason: RivetDeviceAppleListenerDriverStop) {
        lock.withLock { stopHandler }?(reason)
    }
}

private final class FakeListenerFactory: RivetDeviceAppleListenerDriverFactory,
    @unchecked Sendable {
    private let lock = NSLock()
    private var drivers: [any RivetDeviceAppleListenerDriver]
    private var makeCount = 0

    init(drivers: [any RivetDeviceAppleListenerDriver]) {
        self.drivers = drivers
    }

    var created: Int {
        lock.withLock { makeCount }
    }

    func make(parameters: NWParameters) throws -> any RivetDeviceAppleListenerDriver {
        try lock.withLock {
            guard !drivers.isEmpty else {
                throw RivetDeviceAppleListenerError.startFailed
            }
            makeCount += 1
            return drivers.removeFirst()
        }
    }
}

private final class BlockingListenerDriver: RivetDeviceAppleListenerDriver,
    @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, any Error>?
    private var connectionHandler: (@Sendable (
        any RivetDeviceApplePendingConnection
    ) -> Void)?
    private var cancelled = false
    private var recordedServices: [RivetDeviceAppleBonjourService?] = []

    var hasStarted: Bool {
        lock.withLock { continuation != nil }
    }

    var services: [RivetDeviceAppleBonjourService?] {
        lock.withLock { recordedServices }
    }

    func start(
        timeout: TimeInterval,
        queue: DispatchQueue,
        onConnection: @escaping @Sendable (
            any RivetDeviceApplePendingConnection
        ) -> Void,
        onStop: @escaping @Sendable (RivetDeviceAppleListenerDriverStop) -> Void
    ) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            let cancelImmediately = lock.withLock {
                connectionHandler = onConnection
                if cancelled {
                    return true
                }
                self.continuation = continuation
                return false
            }
            if cancelImmediately {
                continuation.resume(
                    throwing: RivetDeviceAppleListenerError.startFailed
                )
            }
        }
    }

    func emit(_ connection: any RivetDeviceApplePendingConnection) {
        lock.withLock { connectionHandler }?(connection)
    }

    func becomeReady(port: UInt16) {
        let continuation = lock.withLock {
            let value = self.continuation
            self.continuation = nil
            return value
        }
        continuation?.resume(returning: port)
    }

    func setBonjourService(_ service: RivetDeviceAppleBonjourService?) {
        lock.withLock { recordedServices.append(service) }
    }

    func cancel() {
        let continuation = lock.withLock {
            cancelled = true
            let value = self.continuation
            self.continuation = nil
            return value
        }
        continuation?.resume(
            throwing: RivetDeviceAppleListenerError.startFailed
        )
    }
}

private final class AdvertisementIDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String]

    init(_ values: [String]) {
        self.values = values
    }

    func next() -> String {
        lock.withLock { values.removeFirst() }
    }
}

private func serverIdentity(
    fingerprint: Data
) throws -> RivetDeviceAppleServerIdentity {
    try RivetDeviceAppleServerIdentity(
        parameters: .tcp,
        fingerprint: fingerprint
    )
}

private func waitUntil(
    _ predicate: @escaping @Sendable () async -> Bool
) async {
    for _ in 0..<200 {
        if await predicate() {
            return
        }
        await Task.yield()
    }
}

@Test func identityStorePersistsAndRotatesOneInstallIdentity() throws {
    let client = MemoryIdentityClient(createValues: [
        try serverIdentity(fingerprint: hostFingerprintA),
        try serverIdentity(fingerprint: hostFingerprintB)
    ])
    let store = try RivetDeviceAppleIdentityStore(
        applicationID: "com.example.host",
        client: client,
        now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )

    #expect(try store.loadOrCreate().fingerprint == hostFingerprintA)
    #expect(try store.loadOrCreate().fingerprint == hostFingerprintA)
    #expect(try store.rotate().fingerprint == hostFingerprintB)
    #expect(try store.loadOrCreate().fingerprint == hostFingerprintB)
    #expect(client.calls.map { call in
        switch call {
        case .load: "load"
        case .create: "create"
        case .remove: "remove"
        }
    } == ["load", "create", "load", "remove", "create", "load"])

    #expect(throws: RivetDeviceAppleIdentityError.invalidApplicationID) {
        try RivetDeviceAppleIdentityStore(applicationID: " invalid ")
    }
}

@Test func generatedCertificateContainsTheExactP256SPKI() throws {
    let key = P256.Signing.PrivateKey()
    let certificate = try RivetDeviceAppleCertificateBuilder.make(
        commonName: "dev.rivet.device.identity.com.example.host",
        publicKey: key.publicKey.x963Representation,
        serial: Data([0x80, 0x01]),
        notBefore: Date(timeIntervalSince1970: 1_700_000_000),
        notAfter: Date(timeIntervalSince1970: 1_800_000_000)
    ) { bytes in
        try key.signature(for: bytes).derRepresentation
    }
    #expect(SecCertificateCreateWithData(nil, certificate as CFData) != nil)

    let algorithm = derSequenceForHostTest(
        derElementForHostTest(
            tag: 0x06,
            content: Data([0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01])
        ),
        derElementForHostTest(
            tag: 0x06,
            content: Data([0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07])
        )
    )
    let expectedSPKI = derSequenceForHostTest(
        algorithm,
        derElementForHostTest(
            tag: 0x03,
            content: Data([0]) + key.publicKey.x963Representation
        )
    )
    #expect(try RivetDeviceAppleSPKI.subjectPublicKeyInfo(
        certificateDER: certificate
    ) == expectedSPKI)
}

@Test func bonjourAdvertisementUsesCanonicalPrivacyBoundedTXTRecord() throws {
    let id = "00112233445566778899aabbccddeeff"
    let advertisement = try RivetDeviceAppleBonjourAdvertisement(
        advertisementID: id,
        pairingWindowOpen: false
    )
    let expected = Data([35])
        + Data("id=\(id)".utf8)
        + Data([6])
        + Data("pair=0".utf8)
        + Data([3])
        + Data("v=1".utf8)

    #expect(advertisement.txtRecordData == expected)
    #expect(try RivetDeviceAppleBonjourAdvertisement.decode(
        txtRecordData: expected
    ) == advertisement)
    #expect(expected.count <= rivetDeviceAppleBonjourMaximumTXTRecordSize)

    #expect(throws: RivetDeviceAppleBonjourError.invalidAdvertisementID) {
        try RivetDeviceAppleBonjourAdvertisement(
            advertisementID: id.uppercased(),
            pairingWindowOpen: false
        )
    }
    #expect(throws: RivetDeviceAppleBonjourError.invalidTXTRecord) {
        try RivetDeviceAppleBonjourAdvertisement.decode(
            txtRecordData: Data([3]) + Data("v=1".utf8)
                + Data([35]) + Data("id=\(id)".utf8)
                + Data([6]) + Data("pair=0".utf8)
        )
    }
    #expect(throws: RivetDeviceAppleBonjourError.unsupportedProtocolVersion) {
        try RivetDeviceAppleBonjourAdvertisement.decode(
            txtRecordData: Data([35]) + Data("id=\(id)".utf8)
                + Data([6]) + Data("pair=0".utf8)
                + Data([3]) + Data("v=2".utf8)
        )
    }
    #expect(throws: RivetDeviceAppleBonjourError.txtRecordTooLarge) {
        try RivetDeviceAppleBonjourAdvertisement.decode(
            txtRecordData: Data(
                repeating: 0,
                count: rivetDeviceAppleBonjourMaximumTXTRecordSize + 1
            )
        )
    }
}

@Test func listenerIsDisabledByDefaultAndCapsBeforeTransportAllocation() async throws {
    let identityClient = MemoryIdentityClient(createValues: [
        try serverIdentity(fingerprint: hostFingerprintA)
    ])
    let identityStore = try RivetDeviceAppleIdentityStore(
        applicationID: "com.example.host",
        client: identityClient
    )
    let driver = FakeListenerDriver(port: 43123)
    let factory = FakeListenerFactory(drivers: [driver])
    let listener = try RivetDeviceAppleListener(
        identityStore: identityStore,
        driverFactory: factory,
        serviceName: "Test Rivet",
        maximumConnections: 2
    ) { _ in
        try? await Task.sleep(for: .seconds(60))
    }

    #expect(await listener.snapshot() == RivetDeviceAppleListenerSnapshot(
        state: .disabled,
        activeConnections: 0,
        rejectedConnections: 0,
        serverFingerprint: nil,
        advertisementID: nil,
        pairingWindowOpen: false
    ))
    #expect(identityClient.calls.isEmpty)
    #expect(factory.created == 0)

    let enabled = try await listener.enable()
    #expect(enabled.state == .ready(port: 43123))
    #expect(enabled.serverFingerprint == hostFingerprintA)
    #expect(enabled.advertisementID?.count == 32)
    #expect(!enabled.pairingWindowOpen)

    let first = FakePendingConnection()
    let second = FakePendingConnection()
    let rejected = FakePendingConnection()
    driver.emit(first)
    driver.emit(second)
    driver.emit(rejected)
    await waitUntil { await listener.snapshot().activeConnections == 2 }
    await waitUntil { await listener.snapshot().rejectedConnections == 1 }

    #expect(first.connectionsMade == 1)
    #expect(second.connectionsMade == 1)
    #expect(rejected.connectionsMade == 0)
    #expect(rejected.cancellations == 1)

    await listener.disable()
    let disabled = await listener.snapshot()
    #expect(disabled.state == .disabled)
    #expect(disabled.activeConnections == 0)
    #expect(disabled.serverFingerprint == nil)
    #expect(disabled.advertisementID == nil)
    #expect(!disabled.pairingWindowOpen)
    #expect(driver.cancellations >= 1)
    #expect(first.bytes.wasCancelled)
    #expect(second.bytes.wasCancelled)
}

@Test func listenerRejectsInvalidDiscoveryConfigurationAndIdentifier() async throws {
    let identityClient = MemoryIdentityClient(createValues: [
        try serverIdentity(fingerprint: hostFingerprintA)
    ])
    let identityStore = try RivetDeviceAppleIdentityStore(
        applicationID: "com.example.host",
        client: identityClient
    )
    #expect(throws: RivetDeviceAppleListenerError.invalidConfiguration) {
        try RivetDeviceAppleListener(
            identityStore: identityStore,
            driverFactory: FakeListenerFactory(drivers: []),
            serviceName: " invalid "
        ) { _ in }
    }

    let driver = FakeListenerDriver(port: 43132)
    let listener = try RivetDeviceAppleListener(
        identityStore: identityStore,
        driverFactory: FakeListenerFactory(drivers: [driver]),
        serviceName: "Test Rivet",
        advertisementIDGenerator: { "not-a-canonical-id" }
    ) { _ in }
    await #expect(throws: RivetDeviceAppleListenerError.advertisementFailed) {
        try await listener.enable()
    }
    #expect(await listener.snapshot().state == .failed)
    #expect(await listener.snapshot().advertisementID == nil)
    #expect(driver.events == [.cancel])
}

@Test func listenerAdvertisesOnlyWhileReadyAndRotatesEphemeralID() async throws {
    let identityClient = MemoryIdentityClient(createValues: [
        try serverIdentity(fingerprint: hostFingerprintA)
    ])
    let identityStore = try RivetDeviceAppleIdentityStore(
        applicationID: "com.example.host",
        client: identityClient
    )
    let firstDriver = FakeListenerDriver(port: 43130)
    let secondDriver = FakeListenerDriver(port: 43131)
    let ids = AdvertisementIDSequence([
        "00112233445566778899aabbccddeeff",
        "ffeeddccbbaa99887766554433221100"
    ])
    let listener = try RivetDeviceAppleListener(
        identityStore: identityStore,
        driverFactory: FakeListenerFactory(drivers: [
            firstDriver,
            secondDriver
        ]),
        serviceName: "Test Rivet",
        advertisementIDGenerator: { ids.next() }
    ) { _ in }

    #expect(firstDriver.events.isEmpty)
    let firstReady = try await listener.enable()
    #expect(firstReady.advertisementID == "00112233445566778899aabbccddeeff")
    #expect(!firstReady.pairingWindowOpen)
    guard case let .service(firstService)? = firstDriver.events.first,
          let firstService else {
        Issue.record("listener did not publish its Bonjour service")
        return
    }
    #expect(firstService.name == "Test Rivet")
    #expect(firstService.type == rivetDeviceAppleBonjourServiceType)
    #expect(try RivetDeviceAppleBonjourAdvertisement.decode(
        txtRecordData: firstService.txtRecord
    ).pairingWindowOpen == false)

    try await listener.setPairingWindowOpen(true)
    let pairingReady = await listener.snapshot()
    #expect(pairingReady.advertisementID == firstReady.advertisementID)
    #expect(pairingReady.pairingWindowOpen)
    guard case let .service(pairingService)? = firstDriver.events.last,
          let pairingService else {
        Issue.record("listener did not update its Bonjour TXT record")
        return
    }
    let pairingAdvertisement = try RivetDeviceAppleBonjourAdvertisement.decode(
        txtRecordData: pairingService.txtRecord
    )
    #expect(pairingAdvertisement.advertisementID == firstReady.advertisementID)
    #expect(pairingAdvertisement.pairingWindowOpen)

    await listener.disable()
    #expect(firstDriver.events.suffix(2) == [
        .service(nil),
        .cancel
    ])
    let secondReady = try await listener.enable()
    #expect(secondReady.advertisementID == "ffeeddccbbaa99887766554433221100")
    #expect(secondReady.advertisementID != firstReady.advertisementID)
    #expect(!secondReady.pairingWindowOpen)

    await listener.terminate()
    #expect(secondDriver.events.suffix(2) == [
        .service(nil),
        .cancel
    ])
}

@Test func connectionArrivingWithReadyIsQueuedUntilListenerStateCommits() async throws {
    let identityClient = MemoryIdentityClient(createValues: [
        try serverIdentity(fingerprint: hostFingerprintA)
    ])
    let identityStore = try RivetDeviceAppleIdentityStore(
        applicationID: "com.example.host",
        client: identityClient
    )
    let early = FakePendingConnection()
    let driver = BlockingListenerDriver()
    let listener = try RivetDeviceAppleListener(
        identityStore: identityStore,
        driverFactory: FakeListenerFactory(drivers: [driver]),
        serviceName: "Test Rivet"
    ) { _ in
        try? await Task.sleep(for: .seconds(60))
    }

    let enable = Task { try await listener.enable() }
    for _ in 0..<200 where !driver.hasStarted {
        await Task.yield()
    }
    #expect(driver.hasStarted)
    driver.emit(early)
    for _ in 0..<20 {
        await Task.yield()
    }
    #expect(await listener.snapshot().state == .starting)
    #expect(driver.services.isEmpty)
    #expect(early.connectionsMade == 0)
    #expect(early.cancellations == 0)

    driver.becomeReady(port: 43125)
    let enabled = try await enable.value
    #expect(enabled.state == .ready(port: 43125))
    #expect(driver.services.count == 1)
    #expect(driver.services.first! != nil)
    await waitUntil { await listener.snapshot().activeConnections == 1 }
    #expect(early.connectionsMade == 1)
    #expect(early.cancellations == 0)
    await listener.terminate()
    #expect(early.bytes.wasCancelled)
}

@Test func disableDuringStartCancelsQueuedAdmissionWithoutResurrection() async throws {
    let identityClient = MemoryIdentityClient(createValues: [
        try serverIdentity(fingerprint: hostFingerprintA)
    ])
    let identityStore = try RivetDeviceAppleIdentityStore(
        applicationID: "com.example.host",
        client: identityClient
    )
    let driver = BlockingListenerDriver()
    let listener = try RivetDeviceAppleListener(
        identityStore: identityStore,
        driverFactory: FakeListenerFactory(drivers: [driver]),
        serviceName: "Test Rivet"
    ) { _ in }
    let enable = Task { try await listener.enable() }
    for _ in 0..<200 where !driver.hasStarted {
        await Task.yield()
    }
    #expect(driver.hasStarted)

    let queued = FakePendingConnection()
    driver.emit(queued)
    for _ in 0..<20 {
        await Task.yield()
    }
    await listener.disable()

    await #expect(throws: RivetDeviceAppleListenerError.startFailed) {
        try await enable.value
    }
    #expect(await listener.snapshot().state == .disabled)
    #expect(await listener.snapshot().activeConnections == 0)
    #expect(queued.connectionsMade == 0)
    #expect(queued.cancellations == 1)
}

@Test func listenerFailureAndTerminationCloseConnectionsAndStayTerminal() async throws {
    let identityClient = MemoryIdentityClient(createValues: [
        try serverIdentity(fingerprint: hostFingerprintA)
    ])
    let identityStore = try RivetDeviceAppleIdentityStore(
        applicationID: "com.example.host",
        client: identityClient
    )
    let driver = FakeListenerDriver(port: 43124)
    let listener = try RivetDeviceAppleListener(
        identityStore: identityStore,
        driverFactory: FakeListenerFactory(drivers: [driver]),
        serviceName: "Test Rivet"
    ) { _ in
        try? await Task.sleep(for: .seconds(60))
    }
    _ = try await listener.enable()

    let accepted = FakePendingConnection()
    driver.emit(accepted)
    await waitUntil { await listener.snapshot().activeConnections == 1 }
    driver.stop(.failed)
    await waitUntil { await listener.snapshot().state == .failed }
    #expect(accepted.bytes.wasCancelled)
    #expect(await listener.snapshot().activeConnections == 0)
    #expect(driver.events.last == .service(nil))

    await listener.terminate()
    #expect(await listener.snapshot().state == .terminated)
    await #expect(throws: RivetDeviceAppleListenerError.invalidState) {
        try await listener.enable()
    }
}

private func derSequenceForHostTest(_ values: Data...) -> Data {
    derElementForHostTest(
        tag: 0x30,
        content: values.reduce(into: Data()) { $0.append($1) }
    )
}

private func derElementForHostTest(tag: UInt8, content: Data) -> Data {
    precondition(content.count < 256)
    let length: Data
    if content.count < 128 {
        length = Data([UInt8(content.count)])
    } else {
        length = Data([0x81, UInt8(content.count)])
    }
    return Data([tag]) + length + content
}
#endif
