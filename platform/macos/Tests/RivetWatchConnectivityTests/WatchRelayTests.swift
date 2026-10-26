import Foundation
import RivetDevice
import Testing
@testable import RivetWatchConnectivity

private struct WatchEcho: RivetDeviceRequest {
    static let route = "watch.echo"
    let text: String
    typealias Response = WatchEchoReply
}

private struct WatchDenied: RivetDeviceRequest {
    static let route = "watch.unregistered"
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
    let defaultPolicy = RivetWatchMessagePolicy()
    #expect(defaultPolicy.maximumBytes == 64 * 1024)
    try defaultPolicy.validate(Data(repeating: 1, count: 64 * 1024))
    #expect(throws: RivetWatchMessagePolicyError.messageTooLarge(
        actual: 64 * 1024 + 1, maximum: 64 * 1024
    )) {
        try defaultPolicy.validate(Data(repeating: 1, count: 64 * 1024 + 1))
    }

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

@Test func watchRelayCannotInvokeUnregisteredPhoneRoutes() async throws {
    let router = RivetDeviceRouter()
    try await router.register(WatchEcho.self) { message in
        WatchEchoReply(text: message.text)
    }
    let client = RivetDeviceClient(transport: PhoneRelayLoopback(
        router: router, policy: RivetWatchMessagePolicy()
    ))
    await #expect(throws: RivetDeviceError.remote(
        code: "unknown_route",
        message: "watch.unregistered"
    )) {
        try await client.send(WatchDenied(text: "cannot escalate"))
    }
}


private func awaitPendingWatchReply(
    _ pending: RivetWatchPendingReply,
    deadline: UInt64? = nil
) async throws -> Data {
    try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Data, Error>) in
        guard pending.install(continuation) else { return }
        if let deadline { pending.armTimeout(nanoseconds: deadline) }
    }
}

@Test func watchReplyCompletionIgnoresDuplicateAndLateCallbacks() async throws {
    let pending = RivetWatchPendingReply()
    let wait = Task { try await awaitPendingWatchReply(pending) }
    pending.complete(.success(Data([0x34])))
    pending.complete(.failure(RivetWatchConnectivityError.emptyReply))
    #expect(try await wait.value == Data([0x34]))
}

@Test func watchReplyCancellationBeforeRegistrationResumesExactlyOnce() async {
    let pending = RivetWatchPendingReply()
    pending.complete(.failure(CancellationError()))
    let wait = Task { try await awaitPendingWatchReply(pending) }
    pending.complete(.success(Data([1])))
    await #expect(throws: CancellationError.self) { try await wait.value }
}

@Test func watchReplyDeadlineIsFiniteAndRejectsLateSuccess() async {
    let pending = RivetWatchPendingReply()
    let wait = Task { try await awaitPendingWatchReply(pending, deadline: 10_000_000) }
    await #expect(throws: RivetWatchConnectivityError.requestTimedOut) {
        try await wait.value
    }
    pending.complete(.success(Data([0x01])))
}
