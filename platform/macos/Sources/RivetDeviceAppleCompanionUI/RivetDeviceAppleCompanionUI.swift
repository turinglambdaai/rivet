#if os(iOS) || os(macOS)
import Combine
import Foundation
import Network
import SwiftUI
import RivetDevice
import RivetDeviceAppleTransport
import RivetDeviceAppleCompanion

public enum RivetDeviceAppleCompanionPresentationStatus: String, Equatable, Sendable {
    case idle
    case browsing
    case connecting
    case waitingForConfirmation
    case connected
    case failed

    public var title: String {
        switch self {
        case .idle: "Not connected"
        case .browsing: "Searching for Rivet devices"
        case .connecting: "Connecting securely"
        case .waitingForConfirmation: "Confirm the pairing code"
        case .connected: "Secure session established"
        case .failed: "Action failed; check permissions and connection"
        }
    }
}

/// Main-actor state adapter for SwiftUI. It keeps the platform-neutral
/// companion coordinator as the source of truth and never approves pairing
/// automatically.
@MainActor
public final class RivetDeviceAppleCompanionModel: ObservableObject {
    @Published public private(set) var discoveries: [RivetDeviceAppleBonjourDiscovery] = []
    @Published public private(set) var pairedDevices: [RivetDevicePairedDevice] = []
    @Published public private(set) var pairingCode: RivetDeviceApplePairingCode?
    @Published public var selectedPairedDeviceID: UUID?
    @Published public private(set) var status: RivetDeviceAppleCompanionPresentationStatus = .idle
    @Published public private(set) var isBrowsing = false
    @Published public private(set) var connectedDeviceID: UUID?

    private let companion: RivetDeviceAppleCompanion
    private let applicationHandler: RivetDeviceAppleCompanion.ApplicationHandler
    private var eventTask: Task<Void, Never>?

    public init(
        companion: RivetDeviceAppleCompanion,
        applicationHandler: @escaping RivetDeviceAppleCompanion.ApplicationHandler
    ) {
        self.companion = companion
        self.applicationHandler = applicationHandler
        let events = companion.events
        eventTask = Task.detached { [weak self, events] in
            for await event in events {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                await self.consume(event)
            }
        }
    }

    public func startBrowsing() {
        guard !isBrowsing else { return }
        isBrowsing = true
        status = .browsing
        Task {
            do {
                try await companion.startBrowsing()
            } catch {
                isBrowsing = false
                status = .failed
            }
        }
    }

    public func stopBrowsing() {
        isBrowsing = false
        if status == .browsing { status = .idle }
        Task { await companion.stopBrowsing() }
    }

    public func refreshPairedDevices() async {
        do {
            pairedDevices = try await companion.pairedDevices()
            if let selectedPairedDeviceID,
               !pairedDevices.contains(where: { $0.id == selectedPairedDeviceID }) {
                self.selectedPairedDeviceID = nil
            }
        } catch {
            status = .failed
        }
    }

    public func pair(
        _ selected: RivetDeviceAppleBonjourDiscovery,
        windowID: UUID
    ) {
        pairingCode = nil
        status = .connecting
        Task {
            do {
                try await companion.startSession(
                    selected: selected,
                    intent: .pair(windowID: windowID),
                    applicationHandler: applicationHandler
                )
            } catch let error as RivetDeviceAppleCompanionError {
                status = error == .sessionNoLongerActive
                    ? (isBrowsing ? .browsing : .idle)
                    : .failed
            } catch {
                status = .failed
            }
        }
    }

    public func reconnect(
        _ selected: RivetDeviceAppleBonjourDiscovery,
        deviceID: UUID
    ) {
        status = .connecting
        Task {
            do {
                try await companion.startSession(
                    selected: selected,
                    intent: .reconnect(deviceID: deviceID),
                    applicationHandler: applicationHandler
                )
            } catch let error as RivetDeviceAppleCompanionError {
                status = error == .sessionNoLongerActive
                    ? (isBrowsing ? .browsing : .idle)
                    : .failed
            } catch {
                status = .failed
            }
        }
    }

    public func confirmPairing(_ confirmed: Bool) {
        Task {
            do {
                try await companion.confirmPairing(confirmed)
                if !confirmed {
                    pairingCode = nil
                    status = isBrowsing ? .browsing : .idle
                }
            } catch {
                status = .failed
            }
        }
    }

    public func cancelSession() {
        pairingCode = nil
        connectedDeviceID = nil
        status = isBrowsing ? .browsing : .idle
        Task { await companion.cancelSession() }
    }

    public func removePairing(deviceID: UUID) {
        Task {
            do {
                try await companion.removePairing(deviceID: deviceID)
                await refreshPairedDevices()
            } catch {
                status = .failed
            }
        }
    }

    private func consume(_ event: RivetDeviceAppleCompanionEvent) {
        switch event {
        case .discovery(.ready):
            isBrowsing = true
            status = .browsing
        case .discovery(.added(let discovery)):
            upsert(discovery)
        case .discovery(.changed(let previous, let current)):
            discoveries.removeAll { $0.endpoint == previous.endpoint }
            upsert(current)
        case .discovery(.removed(let discovery)):
            discoveries.removeAll { $0.endpoint == discovery.endpoint }
        case .discovery(.failed):
            isBrowsing = false
            discoveries.removeAll()
            status = .failed
        case .discovery(.cancelled):
            isBrowsing = false
            discoveries.removeAll()
            if status == .browsing { status = .idle }
        case .pairingCode(let code):
            pairingCode = code
            status = .waitingForConfirmation
        case .connected(let acceptance):
            connectedDeviceID = acceptance.deviceID
            pairingCode = nil
            status = .connected
            Task { await refreshPairedDevices() }
        case .sessionEnded:
            connectedDeviceID = nil
            pairingCode = nil
            status = isBrowsing ? .browsing : .idle
        case .sessionFailed:
            connectedDeviceID = nil
            pairingCode = nil
            status = .failed
        }
    }

    private func upsert(_ discovery: RivetDeviceAppleBonjourDiscovery) {
        discoveries.removeAll { $0.endpoint == discovery.endpoint }
        discoveries.append(discovery)
        discoveries.sort {
            if $0.serviceName != $1.serviceName {
                return $0.serviceName.localizedStandardCompare($1.serviceName) == .orderedAscending
            }
            return $0.advertisementID < $1.advertisementID
        }
    }
}

/// A reusable first-party SwiftUI surface. The host pairing-window ID is
/// supplied by the product's explicit QR/manual pairing flow; it is never
/// inferred from a Bonjour advertisement.
public struct RivetDeviceAppleCompanionView: View {
    @ObservedObject private var model: RivetDeviceAppleCompanionModel
    private let pairingWindowID: UUID?

    public init(
        model: RivetDeviceAppleCompanionModel,
        pairingWindowID: UUID? = nil
    ) {
        self.model = model
        self.pairingWindowID = pairingWindowID
    }

    public var body: some View {
        NavigationStack {
            List {
                Section("Nearby devices") {
                    Button(model.isBrowsing ? "Stop scanning" : "Scan for devices") {
                        if model.isBrowsing {
                            model.stopBrowsing()
                        } else {
                            model.startBrowsing()
                        }
                    }
                    if model.discoveries.isEmpty {
                        Text("No devices discovered yet")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.discoveries, id: \.endpoint) { discovery in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(discovery.serviceName)
                                .font(.headline)
                            Text(discovery.pairingWindowOpen ? "Pairing window open" : "Pairing window closed")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack {
                                if let pairingWindowID, discovery.pairingWindowOpen {
                                    Button("Pair") {
                                        model.pair(discovery, windowID: pairingWindowID)
                                    }
                                }
                                if !model.pairedDevices.isEmpty {
                                    Menu("Reconnect") {
                                        ForEach(model.pairedDevices, id: \.id) { device in
                                            Button(device.name) {
                                                model.reconnect(discovery, deviceID: device.id)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("Paired devices") {
                    if model.pairedDevices.isEmpty {
                        Text("No saved pairings")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.pairedDevices, id: \.id) { device in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(device.name)
                                Text(device.applicationID)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Forget", role: .destructive) {
                                model.removePairing(deviceID: device.id)
                            }
                        }
                    }
                }

                if let code = model.pairingCode {
                    Section("Confirm pairing") {
                        Text(code.verificationCode)
                            .font(.system(size: 30, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .center)
                        Text("Compare this code with the desktop. Approve only if both screens match.")
                            .font(.callout)
                        HStack {
                            Button("Approve") { model.confirmPairing(true) }
                            Button("Reject", role: .destructive) { model.confirmPairing(false) }
                        }
                    }
                }

                Section("Session") {
                    Text(model.status.title)
                    if model.connectedDeviceID != nil ||
                        model.status == .connecting ||
                        model.status == .waitingForConfirmation {
                        Button("Cancel session", role: .destructive) {
                            model.cancelSession()
                        }
                    }
                }
            }
            .navigationTitle("Rivet Companion")
            .task { await model.refreshPairedDevices() }
        }
    }
}
#endif
