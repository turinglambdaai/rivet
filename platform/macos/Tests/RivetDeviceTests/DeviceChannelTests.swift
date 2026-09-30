import Foundation
import Testing
@testable import RivetDevice

private struct Greeting: RivetDeviceRequest {
    static let route = "demo.greeting"
    typealias Response = GreetingResponse

    let name: String
}

private struct GreetingResponse: Codable, Equatable, Sendable {
    let message: String
}

private struct UnknownRequest: RivetDeviceRequest {
    static let route = "demo.unknown"
    typealias Response = GreetingResponse
}

private struct InvalidRouteRequest: RivetDeviceRequest {
    static let route = "invalid route"
    typealias Response = GreetingResponse
}

private struct FailingRequest: RivetDeviceRequest {
    static let route = "demo.failure"
    typealias Response = GreetingResponse
}

private struct ExpectedFailure: RivetDeviceRemoteError {
    let rivetDeviceErrorCode = "expected_failure"
    let rivetDeviceErrorMessage = "the phone rejected this request"
}

private struct InternalFailure: Error {}

private struct LoopbackTransport: RivetDeviceTransport {
    let router: RivetDeviceRouter

    func send(_ request: Data) async throws -> Data {
        try await router.handle(request)
    }
}

private struct InvalidReplyTransport: RivetDeviceTransport {
    func send(_ request: Data) async throws -> Data {
        Data("not-json".utf8)
    }
}

@Test func typedRequestRoundTripsThroughRouter() async throws {
    let router = RivetDeviceRouter()
    try await router.register(Greeting.self) { request in
        GreetingResponse(message: "Hello, \(request.name)!")
    }
    let client = RivetDeviceClient(transport: LoopbackTransport(router: router))

    let response = try await client.send(Greeting(name: "Watch"))
    #expect(response == GreetingResponse(message: "Hello, Watch!"))
}

@Test func duplicateAndInvalidRoutesAreRejected() async throws {
    let router = RivetDeviceRouter()
    try await router.register(Greeting.self) { _ in GreetingResponse(message: "ok") }

    await #expect(throws: RivetDeviceError.duplicateRoute(Greeting.route)) {
        try await router.register(Greeting.self) { _ in GreetingResponse(message: "again") }
    }

    let client = RivetDeviceClient(transport: LoopbackTransport(router: router))
    await #expect(throws: RivetDeviceError.invalidRoute(InvalidRouteRequest.route)) {
        try await client.send(InvalidRouteRequest())
    }
}

@Test func unknownRouteBecomesTypedRemoteError() async throws {
    let router = RivetDeviceRouter()
    let client = RivetDeviceClient(transport: LoopbackTransport(router: router))

    await #expect(
        throws: RivetDeviceError.remote(code: "unknown_route", message: UnknownRequest.route)
    ) {
        try await client.send(UnknownRequest())
    }
}

@Test func handlerCanExposeStableRemoteError() async throws {
    let router = RivetDeviceRouter()
    try await router.register(FailingRequest.self) { _ in
        throw ExpectedFailure()
    }
    let client = RivetDeviceClient(transport: LoopbackTransport(router: router))

    await #expect(
        throws: RivetDeviceError.remote(
            code: "expected_failure",
            message: "the phone rejected this request"
        )
    ) {
        try await client.send(FailingRequest())
    }
}

@Test func unregisteredHandlerErrorsDoNotLeakImplementationDetails() async throws {
    let router = RivetDeviceRouter()
    try await router.register(FailingRequest.self) { _ in
        throw InternalFailure()
    }
    let client = RivetDeviceClient(transport: LoopbackTransport(router: router))

    await #expect(
        throws: RivetDeviceError.remote(
            code: "handler_error",
            message: "request handler failed"
        )
    ) {
        try await client.send(FailingRequest())
    }
}

@Test func malformedAndOversizedMessagesFailAtTheBoundary() async throws {
    let invalidClient = RivetDeviceClient(transport: InvalidReplyTransport())
    await #expect(throws: RivetDeviceError.malformedEnvelope) {
        try await invalidClient.send(Greeting(name: "Watch"))
    }

    let router = RivetDeviceRouter(maximumMessageSize: 64)
    let limitedClient = RivetDeviceClient(
        transport: LoopbackTransport(router: router),
        maximumMessageSize: 64
    )
    await #expect(throws: RivetDeviceError.self) {
        try await limitedClient.send(Greeting(name: String(repeating: "x", count: 256)))
    }
}
