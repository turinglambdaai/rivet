import Foundation
import RivetDevice
import RivetRuntime
import Testing
@testable import RivetWatchConnectivity

private struct WatchSeek: RivetDeviceRequest {
    static let route = "watch.seek"
    typealias Response = WatchSeekReply
    let position: Int64
}

private struct WatchUnknown: RivetDeviceRequest {
    static let route = "watch.not.registered"
    typealias Response = WatchSeekReply
}

private struct WatchSeekReply: Codable, Equatable, Sendable {
    let position: Int64
}

private enum WatchRelayTestError: Error {
    case unexpectedResponse
}

private struct WatchRelayLoopbackTransport: RivetDeviceTransport {
    let router: RivetDeviceRouter

    func send(_ request: Data) async throws -> Data {
        try await router.handle(request)
    }
}

private actor WatchRelaySessionBox {
    private var session: RivetWatchAuthenticatedDesktopSession?

    func current() -> RivetWatchAuthenticatedDesktopSession? { session }
    func set(_ newSession: RivetWatchAuthenticatedDesktopSession?) {
        session = newSession
    }
}

private actor WatchRelayFakeDesktop: RivetRPCClient {
    private var calls: [(String, [RivetValue])] = []

    func call(_ name: String, arguments: [RivetValue]) async throws -> RivetValue {
        calls.append((name, arguments))
        guard name == "player.seek", arguments.count == 1,
              case .int64(let position) = arguments[0] else {
            throw WatchRelayTestError.unexpectedResponse
        }
        return .int64(position + 1)
    }

    func snapshot() -> [(String, [RivetValue])] { calls }
}

private func registerSeek(_ relay: RivetWatchAuthenticatedRPCRelay) async throws {
    try await relay.register(
        WatchSeek.self,
        rpc: "player.seek",
        arguments: { [.int64($0.position)] },
        response: { value in
            guard case .int64(let position) = value else {
                throw WatchRelayTestError.unexpectedResponse
            }
            return WatchSeekReply(position: position)
        }
    )
}

@Test func watchRelayRequiresCurrentAuthenticatedDesktopSession() async throws {
    let box = WatchRelaySessionBox()
    let desktop = WatchRelayFakeDesktop()
    let relay = RivetWatchAuthenticatedRPCRelay(activeSession: { await box.current() })
    try await registerSeek(relay)

    let watch = RivetDeviceClient(
        transport: WatchRelayLoopbackTransport(router: relay.router),
        maximumMessageSize: rivetWatchConnectivityDefaultMaximumMessageSize
    )
    await #expect(throws: RivetDeviceError.remote(
        code: "desktop_unavailable",
        message: "no authenticated desktop session"
    )) {
        try await watch.send(WatchSeek(position: 10))
    }

    await box.set(RivetWatchAuthenticatedDesktopSession(
        connectionID: UUID(), client: desktop
    ))
    let reply = try await watch.send(WatchSeek(position: 10))
    #expect(reply == WatchSeekReply(position: 11))
    let calls = await desktop.snapshot()
    #expect(calls.count == 1)
    #expect(calls[0].0 == "player.seek")
    #expect(calls[0].1 == [.int64(10)])

    await box.set(nil)
    await #expect(throws: RivetDeviceError.remote(
        code: "desktop_unavailable",
        message: "no authenticated desktop session"
    )) {
        try await watch.send(WatchSeek(position: 15))
    }
    let afterDisconnect = await desktop.snapshot()
    #expect(afterDisconnect.count == 1)
}

@Test func watchRelayOnlyDispatchesRegisteredTypesAndExactRPCs() async throws {
    let box = WatchRelaySessionBox()
    let desktop = WatchRelayFakeDesktop()
    await box.set(RivetWatchAuthenticatedDesktopSession(
        connectionID: UUID(), client: desktop
    ))
    let relay = RivetWatchAuthenticatedRPCRelay(activeSession: { await box.current() })
    try await registerSeek(relay)
    let watch = RivetDeviceClient(
        transport: WatchRelayLoopbackTransport(router: relay.router)
    )

    await #expect(throws: RivetDeviceError.remote(
        code: "unknown_route",
        message: "watch.not.registered"
    )) {
        try await watch.send(WatchUnknown())
    }
    let calls = await desktop.snapshot()
    #expect(calls.isEmpty)
    await #expect(throws: RivetDeviceError.duplicateRoute("watch.seek")) {
        try await registerSeek(relay)
    }
    await #expect(throws: RivetWatchRelayError.invalidRPC("$state/get")) {
        try await relay.register(
            WatchUnknown.self,
            rpc: "$state/get",
            arguments: { _ in [] },
            response: { _ in WatchSeekReply(position: 0) }
        )
    }
}

@Test func watchRelayEnforcesForegroundBudgetAtPhoneRouter() async throws {
    let box = WatchRelaySessionBox()
    let desktop = WatchRelayFakeDesktop()
    await box.set(RivetWatchAuthenticatedDesktopSession(
        connectionID: UUID(), client: desktop
    ))
    let relay = RivetWatchAuthenticatedRPCRelay(
        messagePolicy: RivetWatchMessagePolicy(maximumBytes: 160),
        activeSession: { await box.current() }
    )
    try await registerSeek(relay)
    let watch = RivetDeviceClient(
        transport: WatchRelayLoopbackTransport(router: relay.router)
    )
    let reply = try await watch.send(WatchSeek(position: 1))
    #expect(reply == WatchSeekReply(position: 2))

    let huge = Data(repeating: 42, count: 161)
    await #expect(throws: RivetDeviceError.messageTooLarge(
        actual: 161, maximum: 160
    )) {
        try await relay.router.handle(huge)
    }
}
