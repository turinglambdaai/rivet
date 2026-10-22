import Foundation
import RivetDevice
import RivetRuntime
import Testing
@testable import RivetDeviceAppleTransport

private actor MemoryByteStream: RivetDeviceAppleApplicationByteStream {
    private struct Waiter {
        let maximumLength: Int
        let continuation: CheckedContinuation<Data?, Error>
    }

    private var incoming: Data
    private var sent: [Data] = []
    private var waiters: [Waiter] = []
    private var closed = false

    init(incoming: Data = Data()) { self.incoming = incoming }

    func sendApplicationBytes(_ data: Data) async throws {
        guard !closed else { throw RivetDeviceAppleRVT1ChannelError.closed }
        sent.append(data)
    }

    func receiveApplicationBytes(maximumLength: Int) async throws -> Data? {
        if !incoming.isEmpty { return take(maximumLength) }
        if closed { return nil }
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data?, Error>) in
            waiters.append(Waiter(maximumLength: maximumLength, continuation: continuation))
        }
    }

    func close() async {
        closed = true
        resumeWaiters()
    }

    func enqueue(_ data: Data) {
        guard !closed else { return }
        incoming.append(data)
        resumeWaiters()
    }

    func sentCount() -> Int { sent.count }
    func isClosed() -> Bool { closed }

    func sentFrames() throws -> [RivetFrame] {
        try sent.map { try decodeRivetFrame($0) }
    }

    private func take(_ maximumLength: Int) -> Data {
        let count = min(maximumLength, incoming.count)
        let result = Data(incoming.prefix(count))
        incoming = Data(incoming.dropFirst(count))
        return result
    }

    private func resumeWaiters() {
        while !waiters.isEmpty && (!incoming.isEmpty || closed) {
            let waiter = waiters.removeFirst()
            if incoming.isEmpty {
                waiter.continuation.resume(returning: nil)
            } else {
                waiter.continuation.resume(returning: take(waiter.maximumLength))
            }
        }
    }
}

private actor SlowGatewayHost: RivetDeviceGatewayHost {
    private var starts = 0
    private var cancellations = 0
    private var nextID: UInt64 = 1
    private var responseTasks: [UInt64: Task<Data, any Error>] = [:]

    func startRPC(name: String, payload: Data) async throws -> RivetDeviceGatewayHostCall {
        starts += 1
        let id = nextID
        nextID += 1
        let task = Task<Data, any Error> {
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return Data([0x01])
        }
        responseTasks[id] = task
        return RivetDeviceGatewayHostCall(id: id, response: task)
    }

    func cancelRPC(id: UInt64) async {
        cancellations += 1
        responseTasks[id]?.cancel()
    }

    func didStart() -> Bool { starts > 0 }
    func startCount() -> Int { starts }
    func cancellationCount() -> Int { cancellations }
}

private actor EchoRPCClient: RivetRPCClient {
    func call(_ name: String, arguments: [RivetValue]) async throws -> RivetValue {
        .list([.string(name)] + arguments)
    }
}

private actor TestGatewayHost: RivetDeviceGatewayHost {
    private var callNames: [String] = []

    func startRPC(name: String, payload: Data) async throws -> RivetDeviceGatewayHostCall {
        callNames.append(name)
        let response = try encodeRivetValue(.string("host-ok"))
        let task = Task<Data, any Error> { response }
        return RivetDeviceGatewayHostCall(id: UInt64(callNames.count), response: task)
    }

    func cancelRPC(id: UInt64) async {}
    func names() -> [String] { callNames }
}

private func encodedFrame(_ frame: RivetFrame) throws -> Data {
    try encodeRivetFrame(frame)
}

private func helloFrame() throws -> Data {
    try encodedFrame(RivetFrame(
        type: .hello,
        id: 0,
        payload: try encodeRivetValue(.list([
            .string("rivet"),
            .int64(Int64(rivetProtocolVersion))
        ]))
    ))
}

@Test func appleRVT1ChannelClosesAfterOversizedFrame() async throws {
    let frame = try encodedFrame(RivetFrame(type: .event, id: 0, payload: Data([1, 2])))
    let stream = MemoryByteStream(incoming: frame)
    let channel = RivetDeviceAppleRVT1Channel(stream: stream, maximumPayloadSize: 1)

    await #expect(throws: RivetDeviceAppleRVT1ChannelError.frameTooLarge(
        actual: 2, maximum: 1
    )) {
        try await channel.receive()
    }
    #expect(await stream.isClosed())
}

@Test func appleRVT1ClientPerformsHelloAndCorrelatesTypedResponses() async throws {
    let stream = MemoryByteStream(incoming: try helloFrame())
    let client = RivetDeviceAppleRVT1Client(stream: stream)
    try await client.start()
    let call = Task { try await client.call("player.seek", arguments: [.int64(42)]) }
    for _ in 0..<2_000 {
        if await stream.sentCount() == 1 { break }
        await Task.yield()
    }
    let sent = try await stream.sentFrames()
    let request = try #require(sent.first)
    #expect(request.type == .request)
    #expect(try decodeRivetValue(request.payload) == .list([
        .string("player.seek"), .int64(42)
    ]))
    await stream.enqueue(try encodedFrame(RivetFrame(
        type: .response,
        id: request.id,
        payload: try encodeRivetValue(.string("seeked"))
    )))
    #expect(try await call.value == .string("seeked"))
    await client.stop()
}

@Test func appleRVT1ClientCancellationSendsMatchingCancelFrame() async throws {
    let stream = MemoryByteStream(incoming: try helloFrame())
    let client = RivetDeviceAppleRVT1Client(stream: stream)
    try await client.start()
    let call = Task {
        try await client.call("player.wait", arguments: [.int64(5)])
    }
    for _ in 0..<2_000 {
        if await stream.sentCount() >= 1 { break }
        await Task.yield()
    }
    let sentBeforeCancel = try await stream.sentFrames()
    let request = try #require(sentBeforeCancel.first)
    #expect(request.type == .request)

    call.cancel()
    await #expect(throws: CancellationError.self) {
        try await call.value
    }
    for _ in 0..<2_000 {
        if await stream.sentCount() >= 2 { break }
        await Task.yield()
    }
    let sent = try await stream.sentFrames()
    #expect(sent.count == 2)
    #expect(sent[1].type == .cancel)
    #expect(sent[1].id == request.id)
    await client.stop()
}

@Test func appleRVT1GatewayEnforcesRPCAndStateGrants() async throws {
    let host = TestGatewayHost()
    let gateway = RivetDeviceGateway(host: host)
    let session = try await gateway.openSession(
        pairedDeviceID: UUID(),
        scopes: [RivetDeviceScope(
            name: "companion",
            rpcs: ["player.play"],
            readableStates: ["volume"]
        )]
    )
    var incoming = Data()
    let frames = [
        RivetFrame(type: .request, id: 7,
                   payload: try encodeRivetValue(.list([.string("player.play")]))),
        RivetFrame(type: .request, id: 8,
                   payload: try encodeRivetValue(.list([.string("$state/get"), .string("volume")]))),
        RivetFrame(type: .request, id: 9,
                   payload: try encodeRivetValue(.list([.string("$state/get"), .string("private.state")]))),
    ]
    for frame in frames { incoming.append(try encodedFrame(frame)) }
    let stream = MemoryByteStream(incoming: incoming)
    let server = RivetDeviceAppleRVT1GatewayServer(
        stream: stream, gateway: gateway, session: session
    )
    let running = Task { try await server.run() }
    for _ in 0..<2_000 {
        if await stream.sentCount() >= 4 { break }
        await Task.yield()
    }
    #expect(await stream.sentCount() >= 4)
    await stream.enqueue(try encodedFrame(RivetFrame(type: .shutdown, id: 0)))
    try await running.value

    let sent = try await stream.sentFrames()
    #expect(sent.first?.type == .hello)
    let byID = Dictionary(uniqueKeysWithValues: sent.filter {
        $0.type == .response || $0.type == .error
    }.map { ($0.id, $0) })
    #expect(byID[7]?.type == .response)
    #expect(byID[8]?.type == .response)
    #expect(byID[9]?.type == .error)
    let denied = try #require(byID[9])
    #expect(try decodeRivetValue(denied.payload) == .string("operation not permitted"))
    #expect(Set(await host.names()) == Set(["player.play", "$state/get"]))
    #expect(await gateway.sessionCount() == 0)
}

@Test func appleRVT1GatewayBoundsConcurrentRequests() async throws {
    let host = SlowGatewayHost()
    let gateway = RivetDeviceGateway(host: host)
    let session = try await gateway.openSession(
        pairedDeviceID: UUID(),
        scopes: [RivetDeviceScope(name: "companion", rpcs: ["player.play"])]
    )
    var incoming = Data()
    for id in 1...65 {
        incoming.append(try encodedFrame(RivetFrame(
            type: .request,
            id: UInt64(id),
            payload: try encodeRivetValue(.list([.string("player.play")]))
        )))
    }
    let stream = MemoryByteStream(incoming: incoming)
    let server = RivetDeviceAppleRVT1GatewayServer(
        stream: stream, gateway: gateway, session: session
    )
    let running = Task { try await server.run() }

    for _ in 0..<2_000 {
        if await stream.sentCount() >= 2 { break }
        await Task.yield()
    }
    let sent = try await stream.sentFrames()
    let rejected = try #require(sent.first(where: { $0.id == 65 }))
    #expect(rejected.type == .error)
    #expect(try decodeRivetValue(rejected.payload) == .string("too many pending requests"))
    #expect(await host.startCount() <= rivetDeviceDefaultMaximumPendingRequests)

    await stream.enqueue(try encodedFrame(RivetFrame(type: .shutdown, id: 0)))
    try await running.value
    #expect(await gateway.sessionCount() == 0)
}

@Test func appleRVT1GatewayCancelForwardsCancellationAndSuppressesLateResponse() async throws {
    let host = SlowGatewayHost()
    let gateway = RivetDeviceGateway(host: host)
    let session = try await gateway.openSession(
        pairedDeviceID: UUID(),
        scopes: [RivetDeviceScope(name: "companion", rpcs: ["player.play"])]
    )
    let request = try encodedFrame(RivetFrame(
        type: .request,
        id: 56,
        payload: try encodeRivetValue(.list([.string("player.play")]))
    ))
    let stream = MemoryByteStream(incoming: request)
    let server = RivetDeviceAppleRVT1GatewayServer(
        stream: stream, gateway: gateway, session: session
    )
    let running = Task { try await server.run() }

    for _ in 0..<2_000 {
        if await host.didStart() { break }
        await Task.yield()
    }
    #expect(await host.didStart())
    await stream.enqueue(try encodedFrame(RivetFrame(type: .cancel, id: 56)))
    for _ in 0..<2_000 {
        if await host.cancellationCount() >= 1 { break }
        await Task.yield()
    }
    #expect(await host.cancellationCount() >= 1)
    await stream.enqueue(try encodedFrame(RivetFrame(type: .shutdown, id: 0)))
    try await running.value

    let sent = try await stream.sentFrames()
    #expect(sent.map(\.type) == [.hello])
    #expect(await gateway.sessionCount() == 0)
}

@Test func appleRVT1GatewayShutdownCancelsInFlightRPCAndRevokesSession() async throws {
    let host = SlowGatewayHost()
    let gateway = RivetDeviceGateway(host: host)
    let session = try await gateway.openSession(
        pairedDeviceID: UUID(),
        scopes: [RivetDeviceScope(name: "companion", rpcs: ["player.play"])]
    )
    let request = try encodedFrame(RivetFrame(
        type: .request,
        id: 55,
        payload: try encodeRivetValue(.list([.string("player.play")]))
    ))
    let stream = MemoryByteStream(incoming: request)
    let server = RivetDeviceAppleRVT1GatewayServer(
        stream: stream, gateway: gateway, session: session
    )
    let running = Task { try await server.run() }

    for _ in 0..<2_000 {
        if await host.didStart() { break }
        await Task.yield()
    }
    #expect(await host.didStart())
    await stream.enqueue(try encodedFrame(RivetFrame(type: .shutdown, id: 0)))
    try await running.value
    for _ in 0..<2_000 {
        if await host.cancellationCount() >= 1 { break }
        await Task.yield()
    }

    #expect(await host.cancellationCount() >= 1)
    #expect(await gateway.sessionCount() == 0)
}

@Test func appleRVT1GatewayFiltersEventsAndStateChangesPerDevice() async throws {
    let host = TestGatewayHost()
    let gateway = RivetDeviceGateway(host: host)
    let session = try await gateway.openSession(
        pairedDeviceID: UUID(),
        scopes: [RivetDeviceScope(
            name: "companion",
            events: ["progress"],
            readableStates: ["volume"]
        )]
    )
    let stream = MemoryByteStream()
    let server = RivetDeviceAppleRVT1GatewayServer(
        stream: stream, gateway: gateway, session: session
    )
    let running = Task { try await server.run() }
    for _ in 0..<2_000 {
        if await stream.sentCount() >= 1 { break }
        await Task.yield()
    }
    #expect(try await server.sendEvent(name: "progress", value: .int64(3)))
    #expect(!(try await server.sendEvent(name: "private.event", value: .int64(3))))
    #expect(try await server.sendStateChange(name: "volume", value: .int64(8)))
    #expect(!(try await server.sendStateChange(name: "private.state", value: .int64(8))))
    await stream.enqueue(try encodedFrame(RivetFrame(type: .shutdown, id: 0)))
    try await running.value
    let sent = try await stream.sentFrames()
    #expect(sent.map(\.type) == [.hello, .event, .event])
}

@Test func rvt1BackendHostEncodesArgumentsAndResults() async throws {
    let host = RivetDeviceRVT1BackendHost(client: EchoRPCClient())
    let payload = try encodeRivetValue(.list([.string("chapter"), .int64(4)]))
    let call = try await host.startRPC(name: "player.seek", payload: payload)
    let response = try await call.response.value
    #expect(try decodeRivetValue(response) == .list([
        .string("player.seek"), .string("chapter"), .int64(4)
    ]))
}
