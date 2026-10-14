import Foundation
import Network

private let rivetDeviceAppleBonjourMaximumPendingEvents = 256
private let rivetDeviceAppleBonjourMaximumDiscoveries = 128

public enum RivetDeviceAppleBonjourBrowserState: Sendable, Equatable {
    case stopped
    case starting
    case ready
    case failed
}

public enum RivetDeviceAppleBonjourBrowserError: Error, Sendable, Equatable,
    CustomStringConvertible {
    case invalidState

    public var description: String {
        switch self {
        case .invalidState:
            "Rivet device Bonjour browser is in the wrong state"
        }
    }
}

/// A discovery result is only an unauthenticated connection candidate. The
/// ephemeral advertisement identifier and pairing hint are not credentials.
public struct RivetDeviceAppleBonjourDiscovery: Sendable, Equatable {
    public let endpoint: NWEndpoint
    public let serviceName: String
    public let advertisementID: String
    public let pairingWindowOpen: Bool

    package init(
        endpoint: NWEndpoint,
        serviceName: String,
        advertisementID: String,
        pairingWindowOpen: Bool
    ) {
        self.endpoint = endpoint
        self.serviceName = serviceName
        self.advertisementID = advertisementID
        self.pairingWindowOpen = pairingWindowOpen
    }
}

public struct RivetDeviceAppleBonjourBrowserSnapshot: Sendable, Equatable {
    public let state: RivetDeviceAppleBonjourBrowserState
    public let discoveries: [RivetDeviceAppleBonjourDiscovery]

    package init(
        state: RivetDeviceAppleBonjourBrowserState,
        discoveries: [RivetDeviceAppleBonjourDiscovery]
    ) {
        self.state = state
        self.discoveries = discoveries
    }
}

public enum RivetDeviceAppleBonjourBrowserEvent: Sendable, Equatable {
    case ready
    case added(RivetDeviceAppleBonjourDiscovery)
    case changed(
        previous: RivetDeviceAppleBonjourDiscovery,
        current: RivetDeviceAppleBonjourDiscovery
    )
    case removed(RivetDeviceAppleBonjourDiscovery)
    case failed
    case cancelled
}

package struct RivetDeviceAppleBonjourBrowseResult: Sendable, Hashable {
    package let endpoint: NWEndpoint
    package let serviceName: String
    package let txtRecordData: Data

    package init(
        endpoint: NWEndpoint,
        serviceName: String,
        txtRecordData: Data
    ) {
        self.endpoint = endpoint
        self.serviceName = serviceName
        self.txtRecordData = txtRecordData
    }
}

package enum RivetDeviceAppleBonjourBrowserDriverEvent: Sendable, Equatable {
    case ready
    case added(RivetDeviceAppleBonjourBrowseResult)
    case changed(
        old: RivetDeviceAppleBonjourBrowseResult,
        new: RivetDeviceAppleBonjourBrowseResult
    )
    case removed(RivetDeviceAppleBonjourBrowseResult)
    case failed
    case cancelled
}

package protocol RivetDeviceAppleBonjourBrowserDriver: Sendable {
    func start(
        queue: DispatchQueue,
        onEvent: @escaping @Sendable (
            RivetDeviceAppleBonjourBrowserDriverEvent
        ) -> Void
    )
    func cancel()
}

package protocol RivetDeviceAppleBonjourBrowserDriverFactory: Sendable {
    func make() -> any RivetDeviceAppleBonjourBrowserDriver
}

package struct RivetDeviceSystemBonjourBrowserDriverFactory:
    RivetDeviceAppleBonjourBrowserDriverFactory {
    package init() {}

    package func make() -> any RivetDeviceAppleBonjourBrowserDriver {
        RivetDeviceSystemBonjourBrowserDriver()
    }
}

/// Explicitly started Bonjour discovery for iOS companion applications.
/// Discovery never opens a connection and never grants authority; products
/// must still run TLS pinning and the RVD1 authentication/pairing preface.
public actor RivetDeviceAppleBonjourBrowser {
    public typealias EventHandler = @Sendable (
        RivetDeviceAppleBonjourBrowserEvent
    ) -> Void

    private let driverFactory: any RivetDeviceAppleBonjourBrowserDriverFactory
    private let queue: DispatchQueue
    private let handler: EventHandler

    private var state = RivetDeviceAppleBonjourBrowserState.stopped
    private var generation = UUID()
    private var driver: (any RivetDeviceAppleBonjourBrowserDriver)?
    private var eventContinuation: AsyncStream<
        RivetDeviceAppleBonjourBrowserDriverEvent
    >.Continuation?
    private var eventTask: Task<Void, Never>?
    private var discoveries: [NWEndpoint: RivetDeviceAppleBonjourDiscovery] = [:]

    public init(handler: @escaping EventHandler) {
        driverFactory = RivetDeviceSystemBonjourBrowserDriverFactory()
        queue = DispatchQueue(label: "dev.rivet.device-browser")
        self.handler = handler
    }

    package init(
        driverFactory: any RivetDeviceAppleBonjourBrowserDriverFactory,
        queue: DispatchQueue = DispatchQueue(
            label: "dev.rivet.device-browser"
        ),
        handler: @escaping EventHandler
    ) {
        self.driverFactory = driverFactory
        self.queue = queue
        self.handler = handler
    }

    deinit {
        eventContinuation?.finish()
        eventTask?.cancel()
        driver?.cancel()
    }

    public func snapshot() -> RivetDeviceAppleBonjourBrowserSnapshot {
        RivetDeviceAppleBonjourBrowserSnapshot(
            state: state,
            discoveries: discoveries.values.sorted(by: Self.discoveryOrder)
        )
    }

    public func start() throws {
        guard state == .stopped else {
            throw RivetDeviceAppleBonjourBrowserError.invalidState
        }
        let requestedGeneration = UUID()
        generation = requestedGeneration
        state = .starting
        let newDriver = driverFactory.make()
        driver = newDriver
        let (events, continuation) = AsyncStream.makeStream(
            of: RivetDeviceAppleBonjourBrowserDriverEvent.self,
            bufferingPolicy: .bufferingOldest(
                rivetDeviceAppleBonjourMaximumPendingEvents
            )
        )
        eventContinuation = continuation
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else {
                    return
                }
                await self.handle(event, generation: requestedGeneration)
            }
        }
        newDriver.start(queue: queue) { [weak self] event in
            if case .dropped = continuation.yield(event) {
                continuation.finish()
                Task {
                    await self?.eventBufferOverflow(
                        generation: requestedGeneration
                    )
                }
            }
        }
    }

    /// Stops browsing and removes every candidate before reporting one
    /// cancellation event. Repeated stops are intentionally idempotent.
    public func stop() {
        guard state != .stopped else {
            return
        }
        generation = UUID()
        let oldDriver = driver
        driver = nil
        stopEventDelivery()
        state = .stopped
        removeAllDiscoveries()
        oldDriver?.cancel()
        handler(.cancelled)
    }

    private func handle(
        _ event: RivetDeviceAppleBonjourBrowserDriverEvent,
        generation eventGeneration: UUID
    ) {
        guard generation == eventGeneration, state != .stopped else {
            return
        }
        switch event {
        case .ready:
            guard state == .starting else {
                return
            }
            state = .ready
            handler(.ready)
        case let .added(result):
            add(result)
        case let .changed(old, new):
            change(old: old, new: new)
        case let .removed(result):
            remove(result)
        case .failed:
            finish(state: .failed, event: .failed)
        case .cancelled:
            finish(state: .stopped, event: .cancelled)
        }
    }

    private func add(_ result: RivetDeviceAppleBonjourBrowseResult) {
        guard let discovery = Self.decode(result) else {
            return
        }
        if let previous = discoveries[result.endpoint] {
            discoveries[result.endpoint] = discovery
            if previous != discovery {
                handler(.changed(previous: previous, current: discovery))
            }
        } else {
            guard discoveries.count < rivetDeviceAppleBonjourMaximumDiscoveries else {
                finish(state: .failed, event: .failed)
                return
            }
            discoveries[result.endpoint] = discovery
            handler(.added(discovery))
        }
    }

    private func change(
        old: RivetDeviceAppleBonjourBrowseResult,
        new: RivetDeviceAppleBonjourBrowseResult
    ) {
        let previous = discoveries.removeValue(forKey: old.endpoint)
        guard let current = Self.decode(new) else {
            if let previous {
                handler(.removed(previous))
            }
            return
        }

        let displaced: RivetDeviceAppleBonjourDiscovery?
        if old.endpoint != new.endpoint {
            displaced = discoveries.removeValue(forKey: new.endpoint)
        } else {
            displaced = nil
        }
        if let displaced {
            handler(.removed(displaced))
        }
        let replacesKnownDiscovery = previous != nil || displaced != nil
        let hasCapacity =
            discoveries.count < rivetDeviceAppleBonjourMaximumDiscoveries
        guard replacesKnownDiscovery || hasCapacity else {
            finish(state: .failed, event: .failed)
            return
        }
        discoveries[new.endpoint] = current
        if let previous {
            if previous != current {
                handler(.changed(previous: previous, current: current))
            }
        } else {
            handler(.added(current))
        }
    }

    private func remove(_ result: RivetDeviceAppleBonjourBrowseResult) {
        guard let removed = discoveries.removeValue(forKey: result.endpoint) else {
            return
        }
        handler(.removed(removed))
    }

    private func finish(
        state terminalState: RivetDeviceAppleBonjourBrowserState,
        event: RivetDeviceAppleBonjourBrowserEvent
    ) {
        generation = UUID()
        let oldDriver = driver
        driver = nil
        stopEventDelivery()
        state = terminalState
        removeAllDiscoveries()
        oldDriver?.cancel()
        handler(event)
    }

    private func stopEventDelivery() {
        eventContinuation?.finish()
        eventContinuation = nil
        eventTask?.cancel()
        eventTask = nil
    }

    private func eventBufferOverflow(generation eventGeneration: UUID) {
        guard generation == eventGeneration, state != .stopped else {
            return
        }
        finish(state: .failed, event: .failed)
    }

    private func removeAllDiscoveries() {
        let removed = discoveries.values.sorted(by: Self.discoveryOrder)
        discoveries.removeAll(keepingCapacity: true)
        for discovery in removed {
            handler(.removed(discovery))
        }
    }

    private static func decode(
        _ result: RivetDeviceAppleBonjourBrowseResult
    ) -> RivetDeviceAppleBonjourDiscovery? {
        guard let advertisement = try? RivetDeviceAppleBonjourAdvertisement.decode(
            txtRecordData: result.txtRecordData
        ) else {
            return nil
        }
        return RivetDeviceAppleBonjourDiscovery(
            endpoint: result.endpoint,
            serviceName: result.serviceName,
            advertisementID: advertisement.advertisementID,
            pairingWindowOpen: advertisement.pairingWindowOpen
        )
    }

    private static func discoveryOrder(
        _ lhs: RivetDeviceAppleBonjourDiscovery,
        _ rhs: RivetDeviceAppleBonjourDiscovery
    ) -> Bool {
        if lhs.serviceName != rhs.serviceName {
            return lhs.serviceName < rhs.serviceName
        }
        if lhs.advertisementID != rhs.advertisementID {
            return lhs.advertisementID < rhs.advertisementID
        }
        return lhs.endpoint.debugDescription < rhs.endpoint.debugDescription
    }
}

private final class RivetDeviceSystemBonjourBrowserDriver:
    RivetDeviceAppleBonjourBrowserDriver, @unchecked Sendable {
    private let browser: NWBrowser

    init() {
        browser = NWBrowser(
            for: .bonjourWithTXTRecord(
                type: rivetDeviceAppleBonjourServiceType,
                domain: nil
            ),
            using: .tcp
        )
    }

    func start(
        queue: DispatchQueue,
        onEvent: @escaping @Sendable (
            RivetDeviceAppleBonjourBrowserDriverEvent
        ) -> Void
    ) {
        browser.stateUpdateHandler = { state in
            switch state {
            case .ready:
                onEvent(.ready)
            case .failed:
                onEvent(.failed)
            case .cancelled:
                onEvent(.cancelled)
            case .setup, .waiting:
                break
            @unknown default:
                onEvent(.failed)
            }
        }
        browser.browseResultsChangedHandler = { _, changes in
            for change in changes {
                switch change {
                case let .added(result):
                    if let result = Self.convert(result) {
                        onEvent(.added(result))
                    }
                case let .changed(old, new, _):
                    let old = Self.convert(old)
                    let new = Self.convert(new)
                    switch (old, new) {
                    case let (.some(old), .some(new)):
                        onEvent(.changed(old: old, new: new))
                    case let (.some(old), .none):
                        onEvent(.removed(old))
                    case let (.none, .some(new)):
                        onEvent(.added(new))
                    case (.none, .none):
                        break
                    }
                case let .removed(result):
                    if let result = Self.convert(result) {
                        onEvent(.removed(result))
                    }
                case .identical:
                    break
                @unknown default:
                    break
                }
            }
        }
        browser.start(queue: queue)
    }

    func cancel() {
        browser.cancel()
    }

    private static func convert(
        _ result: NWBrowser.Result
    ) -> RivetDeviceAppleBonjourBrowseResult? {
        guard case let .service(name, type, _, _) = result.endpoint,
              type == rivetDeviceAppleBonjourServiceType,
              case let .bonjour(txtRecord) = result.metadata else {
            return nil
        }
        return RivetDeviceAppleBonjourBrowseResult(
            endpoint: result.endpoint,
            serviceName: name,
            txtRecordData: txtRecord.data
        )
    }
}
