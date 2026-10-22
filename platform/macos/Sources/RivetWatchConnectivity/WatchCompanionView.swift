#if os(watchOS)
import SwiftUI
import RivetDevice

/// Minimal watchOS shell for a product's generated typed device request.
/// The action closure should call the product's allowlisted RivetDeviceClient;
/// the view never invents RPC routes or treats reachability as authorization.
@MainActor
public struct RivetWatchCompanionView: View {
    public typealias Action = @Sendable () async throws -> String

    private let title: String
    private let actionTitle: String
    private let transport: RivetWatchConnectivityTransport
    private let action: Action

    @State private var connectivityState: RivetWatchConnectivityState = .inactive
    @State private var result: String?
    @State private var isBusy = false

    public init(
        title: String,
        actionTitle: String,
        transport: RivetWatchConnectivityTransport,
        action: @escaping Action
    ) {
        self.title = title
        self.actionTitle = actionTitle
        self.transport = transport
        self.action = action
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(title)
                        .font(.headline)
                    Text(connectivityState.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if connectivityState != .reachable {
                        Button("Retry connection") {
                            do {
                                try transport.activate()
                                connectivityState = transport.currentState
                            } catch {
                                connectivityState = .failed
                            }
                        }
                    }
                    Button(isBusy ? "Working…" : actionTitle) {
                        Task {
                            isBusy = true
                            defer { isBusy = false }
                            do {
                                result = try await action()
                            } catch {
                                result = "Request failed. Check the iPhone connection."
                            }
                        }
                    }
                    .disabled(isBusy || connectivityState != .reachable)
                    if let result {
                        Text(result)
                            .font(.footnote)
                            .lineLimit(4)
                    }
                }
                .padding(.horizontal, 4)
            }
            .navigationTitle("Rivet")
        }
        .task {
            do {
                try transport.activate()
            } catch {
                connectivityState = .failed
            }
            connectivityState = transport.currentState
            for await next in transport.stateChanges {
                if Task.isCancelled { return }
                connectivityState = next
            }
        }
    }
}
#endif
