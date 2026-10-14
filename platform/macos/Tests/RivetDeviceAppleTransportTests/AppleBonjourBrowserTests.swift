import Foundation
import Network
import Testing
@testable import RivetDeviceAppleTransport

private let browserAdvertisementIDA = "00112233445566778899aabbccddeeff"
private let browserAdvertisementIDB = "ffeeddccbbaa99887766554433221100"

private final class BrowserEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [RivetDeviceAppleBonjourBrowserEvent] = []

    var events: [RivetDeviceAppleBonjourBrowserEvent] {
        lock.withLock { recorded }
    }

    func append(_ event: RivetDeviceAppleBonjourBrowserEvent) {
        lock.withLock { recorded.append(event) }
    }
}

private final class FakeBonjourBrowserDriver:
    RivetDeviceAppleBonjourBrowserDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var eventHandler: (@Sendable (
        RivetDeviceAppleBonjourBrowserDriverEvent
    ) -> Void)?
    private var startCount = 0
    private var cancelCount = 0

    var starts: Int {
        lock.withLock { startCount }
    }

    var cancellations: Int {
        lock.withLock { cancelCount }
    }

    func start(
        queue: DispatchQueue,
        onEvent: @escaping @Sendable (
            RivetDeviceAppleBonjourBrowserDriverEvent
        ) -> Void
    ) {
        lock.withLock {
            startCount += 1
            eventHandler = onEvent
        }
    }

    func cancel() {
        lock.withLock { cancelCount += 1 }
    }

    func emit(_ event: RivetDeviceAppleBonjourBrowserDriverEvent) {
        lock.withLock { eventHandler }?(event)
    }
}

private final class FakeBonjourBrowserFactory:
    RivetDeviceAppleBonjourBrowserDriverFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var drivers: [FakeBonjourBrowserDriver]
    private var makeCount = 0

    init(_ drivers: [FakeBonjourBrowserDriver]) {
        self.drivers = drivers
    }

    var created: Int {
        lock.withLock { makeCount }
    }

    func make() -> any RivetDeviceAppleBonjourBrowserDriver {
        lock.withLock {
            makeCount += 1
            return drivers.removeFirst()
        }
    }
}

private func browserResult(
    name: String,
    advertisementID: String,
    pairingWindowOpen: Bool,
    endpointName: String? = nil
) throws -> RivetDeviceAppleBonjourBrowseResult {
    let advertisement = try RivetDeviceAppleBonjourAdvertisement(
        advertisementID: advertisementID,
        pairingWindowOpen: pairingWindowOpen
    )
    return RivetDeviceAppleBonjourBrowseResult(
        endpoint: .service(
            name: endpointName ?? name,
            type: rivetDeviceAppleBonjourServiceType,
            domain: "local.",
            interface: nil
        ),
        serviceName: name,
        txtRecordData: advertisement.txtRecordData
    )
}

private func waitForBrowser(
    _ predicate: @escaping @Sendable () async -> Bool
) async {
    for _ in 0..<500 {
        if await predicate() {
            return
        }
        await Task.yield()
    }
}

@Test func bonjourBrowserStartsAndStopsOnlyExplicitly() async throws {
    let driver = FakeBonjourBrowserDriver()
    let factory = FakeBonjourBrowserFactory([driver])
    let events = BrowserEventRecorder()
    let browser = RivetDeviceAppleBonjourBrowser(
        driverFactory: factory,
        handler: events.append
    )

    #expect(await browser.snapshot() == RivetDeviceAppleBonjourBrowserSnapshot(
        state: .stopped,
        discoveries: []
    ))
    #expect(factory.created == 0)
    #expect(driver.starts == 0)

    try await browser.start()
    #expect(await browser.snapshot().state == .starting)
    #expect(factory.created == 1)
    #expect(driver.starts == 1)
    await #expect(throws: RivetDeviceAppleBonjourBrowserError.invalidState) {
        try await browser.start()
    }

    driver.emit(.ready)
    await waitForBrowser { await browser.snapshot().state == .ready }
    #expect(events.events == [.ready])

    await browser.stop()
    #expect(await browser.snapshot().state == .stopped)
    #expect(driver.cancellations == 1)
    #expect(events.events == [.ready, .cancelled])

    await browser.stop()
    #expect(driver.cancellations == 1)
    #expect(events.events == [.ready, .cancelled])
}

@Test func bonjourBrowserAddsOnlyCanonicalBoundedAdvertisements() async throws {
    let driver = FakeBonjourBrowserDriver()
    let events = BrowserEventRecorder()
    let browser = RivetDeviceAppleBonjourBrowser(
        driverFactory: FakeBonjourBrowserFactory([driver]),
        handler: events.append
    )
    try await browser.start()
    driver.emit(.ready)

    let valid = try browserResult(
        name: "Desktop",
        advertisementID: browserAdvertisementIDA,
        pairingWindowOpen: false
    )
    #expect(NWTXTRecord(valid.txtRecordData).data == valid.txtRecordData)
    let oversized = RivetDeviceAppleBonjourBrowseResult(
        endpoint: valid.endpoint,
        serviceName: valid.serviceName,
        txtRecordData: Data(
            repeating: 0,
            count: rivetDeviceAppleBonjourMaximumTXTRecordSize + 1
        )
    )
    let reordered = RivetDeviceAppleBonjourBrowseResult(
        endpoint: .service(
            name: "Noncanonical",
            type: rivetDeviceAppleBonjourServiceType,
            domain: "local.",
            interface: nil
        ),
        serviceName: "Noncanonical",
        txtRecordData: Data([3]) + Data("v=1".utf8)
            + Data([35]) + Data("id=\(browserAdvertisementIDA)".utf8)
            + Data([6]) + Data("pair=0".utf8)
    )

    driver.emit(.added(oversized))
    driver.emit(.added(reordered))
    for _ in 0..<20 { await Task.yield() }
    #expect(await browser.snapshot().discoveries.isEmpty)

    driver.emit(.added(valid))
    await waitForBrowser { await browser.snapshot().discoveries.count == 1 }
    let discovery = try #require(await browser.snapshot().discoveries.first)
    #expect(discovery.endpoint == valid.endpoint)
    #expect(discovery.serviceName == "Desktop")
    #expect(discovery.advertisementID == browserAdvertisementIDA)
    #expect(!discovery.pairingWindowOpen)
    #expect(events.events == [.ready, .added(discovery)])
    await browser.stop()
}

@Test func bonjourBrowserReportsEndpointNameIDAndPairingHintChanges() async throws {
    let driver = FakeBonjourBrowserDriver()
    let events = BrowserEventRecorder()
    let browser = RivetDeviceAppleBonjourBrowser(
        driverFactory: FakeBonjourBrowserFactory([driver]),
        handler: events.append
    )
    try await browser.start()
    driver.emit(.ready)
    let old = try browserResult(
        name: "Desktop A",
        advertisementID: browserAdvertisementIDA,
        pairingWindowOpen: false
    )
    let new = try browserResult(
        name: "Desktop B",
        advertisementID: browserAdvertisementIDB,
        pairingWindowOpen: true
    )
    driver.emit(.added(old))
    await waitForBrowser { await browser.snapshot().discoveries.count == 1 }
    let previous = try #require(await browser.snapshot().discoveries.first)

    driver.emit(.changed(old: old, new: new))
    await waitForBrowser {
        await browser.snapshot().discoveries.first?.advertisementID
            == browserAdvertisementIDB
    }
    let current = try #require(await browser.snapshot().discoveries.first)
    #expect(previous.endpoint != current.endpoint)
    #expect(previous.serviceName == "Desktop A")
    #expect(current.serviceName == "Desktop B")
    #expect(previous.advertisementID == browserAdvertisementIDA)
    #expect(current.advertisementID == browserAdvertisementIDB)
    #expect(!previous.pairingWindowOpen)
    #expect(current.pairingWindowOpen)
    #expect(events.events == [
        .ready,
        .added(previous),
        .changed(previous: previous, current: current)
    ])
    await browser.stop()
}

@Test func bonjourBrowserFailsClosedAtTheCandidateBound() async throws {
    let driver = FakeBonjourBrowserDriver()
    let events = BrowserEventRecorder()
    let browser = RivetDeviceAppleBonjourBrowser(
        driverFactory: FakeBonjourBrowserFactory([driver]),
        handler: events.append
    )
    try await browser.start()

    for index in 0..<129 {
        let result = try browserResult(
            name: "Desktop \(index)",
            advertisementID: String(format: "%032x", index),
            pairingWindowOpen: false
        )
        driver.emit(.added(result))
    }
    await waitForBrowser { await browser.snapshot().state == .failed }

    #expect(await browser.snapshot().discoveries.isEmpty)
    #expect(driver.cancellations == 1)
    #expect(events.events.last == .failed)
    #expect(!events.events.contains { event in
        guard case .added(let discovery) = event else {
            return false
        }
        return discovery.serviceName == "Desktop 128"
    })
    await browser.stop()
}

@Test func bonjourBrowserRemovesVanishedAndNewlyInvalidResults() async throws {
    let driver = FakeBonjourBrowserDriver()
    let events = BrowserEventRecorder()
    let browser = RivetDeviceAppleBonjourBrowser(
        driverFactory: FakeBonjourBrowserFactory([driver]),
        handler: events.append
    )
    try await browser.start()
    let first = try browserResult(
        name: "First",
        advertisementID: browserAdvertisementIDA,
        pairingWindowOpen: false
    )
    let second = try browserResult(
        name: "Second",
        advertisementID: browserAdvertisementIDB,
        pairingWindowOpen: false
    )
    driver.emit(.added(first))
    driver.emit(.added(second))
    await waitForBrowser { await browser.snapshot().discoveries.count == 2 }
    let firstDiscovery = try #require(
        await browser.snapshot().discoveries.first { $0.serviceName == "First" }
    )
    let secondDiscovery = try #require(
        await browser.snapshot().discoveries.first { $0.serviceName == "Second" }
    )

    driver.emit(.removed(first))
    await waitForBrowser { await browser.snapshot().discoveries.count == 1 }
    let invalidSecond = RivetDeviceAppleBonjourBrowseResult(
        endpoint: second.endpoint,
        serviceName: second.serviceName,
        txtRecordData: Data([0])
    )
    driver.emit(.changed(old: second, new: invalidSecond))
    await waitForBrowser { await browser.snapshot().discoveries.isEmpty }

    #expect(events.events.contains(.removed(firstDiscovery)))
    #expect(events.events.contains(.removed(secondDiscovery)))
    await browser.stop()
}

@Test func bonjourBrowserFailureClearsCandidatesAndRequiresStopBeforeRestart() async throws {
    let driver = FakeBonjourBrowserDriver()
    let events = BrowserEventRecorder()
    let browser = RivetDeviceAppleBonjourBrowser(
        driverFactory: FakeBonjourBrowserFactory([driver]),
        handler: events.append
    )
    try await browser.start()
    let result = try browserResult(
        name: "Desktop",
        advertisementID: browserAdvertisementIDA,
        pairingWindowOpen: true
    )
    driver.emit(.added(result))
    await waitForBrowser { await browser.snapshot().discoveries.count == 1 }
    let discovery = try #require(await browser.snapshot().discoveries.first)

    driver.emit(.failed)
    await waitForBrowser { await browser.snapshot().state == .failed }
    #expect(await browser.snapshot().discoveries.isEmpty)
    #expect(driver.cancellations == 1)
    #expect(events.events.suffix(2) == [.removed(discovery), .failed])
    await #expect(throws: RivetDeviceAppleBonjourBrowserError.invalidState) {
        try await browser.start()
    }

    await browser.stop()
    #expect(await browser.snapshot().state == .stopped)
    #expect(events.events.last == .cancelled)
}

@Test func bonjourBrowserCancellationClearsStateAndIgnoresStaleEvents() async throws {
    let firstDriver = FakeBonjourBrowserDriver()
    let secondDriver = FakeBonjourBrowserDriver()
    let factory = FakeBonjourBrowserFactory([firstDriver, secondDriver])
    let events = BrowserEventRecorder()
    let browser = RivetDeviceAppleBonjourBrowser(
        driverFactory: factory,
        handler: events.append
    )
    try await browser.start()
    let old = try browserResult(
        name: "Old",
        advertisementID: browserAdvertisementIDA,
        pairingWindowOpen: false
    )
    firstDriver.emit(.added(old))
    await waitForBrowser { await browser.snapshot().discoveries.count == 1 }
    firstDriver.emit(.cancelled)
    await waitForBrowser { await browser.snapshot().state == .stopped }
    #expect(await browser.snapshot().discoveries.isEmpty)

    firstDriver.emit(.added(old))
    for _ in 0..<20 { await Task.yield() }
    #expect(await browser.snapshot().discoveries.isEmpty)

    try await browser.start()
    #expect(factory.created == 2)
    let fresh = try browserResult(
        name: "Fresh",
        advertisementID: browserAdvertisementIDB,
        pairingWindowOpen: true
    )
    secondDriver.emit(.added(fresh))
    await waitForBrowser { await browser.snapshot().discoveries.count == 1 }
    #expect(await browser.snapshot().discoveries.first?.serviceName == "Fresh")
    await browser.stop()
}
