import Foundation
import RivetDevice
import Testing
@testable import RivetWatchConnectivity

private struct WatchEcho: RivetDeviceRequest {
    static let route = "watch.echo"
    let text: String
    typealias Response = WatchEchoReply
}

private struct WatchEchoReply: Codable, Sendable, Equatable {
    let text: String
}

private struct PhoneRelayLoopback: RivetDeviceTransport {
    let router: RivetDeviceRouter
    let policy: RivetWatchMessagePolicy

    func send(_ request: Data) async throws -> Data {
        try policy.validate(request)
        let response = try await router.handle(request)
        try policy.validate(response)
        return response
    }
}

@Test func watchEnvelopeRejectsEmptyAndOversizedMessages() throws {
    let policy = RivetWatchMessagePolicy(maximumBytes: 16)
    #expect(throws: RivetWatchMessagePolicyError.emptyMessage) {
        try policy.validate(Data())
    }
    try policy.validate(Data(repeating: 7, count: 16))
    #expect(throws: RivetWatchMessagePolicyError.messageTooLarge(
        actual: 17, maximum: 16
    )) {
        try policy.validate(Data(repeating: 7, count: 17))
    }
}

@Test func watchRelayExecutesOnlyRegisteredPhoneRouterRoutes() async throws {
    let router = RivetDeviceRouter()
    try await router.register(WatchEcho.self) { message in
        WatchEchoReply(text: message.text)
    }
    let client = RivetDeviceClient(transport: PhoneRelayLoopback(
        router: router, policy: RivetWatchMessagePolicy()
    ))
    let reply = try await client.send(WatchEcho(text: "paired watch"))
    #expect(reply == WatchEchoReply(text: "paired watch"))
}

@Test func watchRelayRejectsOversizedPhoneReplies() async throws {
    let router = RivetDeviceRouter()
    try await router.register(WatchEcho.self) { _ in
        WatchEchoReply(text: String(repeating: "x", count: 1024))
    }
    let client = RivetDeviceClient(transport: PhoneRelayLoopback(
        router: router, policy: RivetWatchMessagePolicy(maximumBytes: 256)
    ))
    await #expect(throws: RivetWatchMessagePolicyError.self) {
        try await client.send(WatchEcho(text: "small"))
    }
}
