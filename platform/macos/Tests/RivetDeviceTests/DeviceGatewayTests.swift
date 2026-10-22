import Foundation
import Testing
@testable import RivetDevice

private actor TestGatewayHost: RivetDeviceGatewayHost {
    struct Start: Equatable, Sendable {
        let id: UInt64
        let name: String
        let payload: Data
    }

    private let blocksResponses: Bool
    private var nextID: UInt64 = 100
    private var tasks: [UInt64: Task<Data, any Error>] = [:]
    private(set) var starts: [Start] = []
    private(set) var cancellations: [UInt64] = []

    init(blocksResponses: Bool = false) {
        self.blocksResponses = blocksResponses
    }

    func startRPC(name: String, payload: Data) async throws -> RivetDeviceGatewayHostCall {
        let id = nextID
        nextID += 1
        let blocksResponses = self.blocksResponses
        let task = Task<Data, any Error> {
            if blocksResponses {
                try await Task.sleep(for: .seconds(30))
            }
            return payload
        }
        tasks[id] = task
        starts.append(Start(id: id, name: name, payload: payload))
        return RivetDeviceGatewayHostCall(id: id, response: task)
    }

    func cancelRPC(id: UInt64) async {
        cancellations.append(id)
        tasks[id]?.cancel()
    }

    func startedCount() -> Int {
        starts.count
    }
}

private func eventually(
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<1_000 {
        if await condition() {
            return true
        }
        await Task.yield()
    }
    return false
}

private let pairedScope = RivetDeviceScope(
    name: "paired-watch",
    rpcs: ["tasks.list"],
    events: ["tasks.changed"],
    readableStates: ["sync.status"],
    writableStates: ["sync.preference"]
)

@Test func gatewayScopesAreDefaultDenyAndFilterOutboundData() async throws {
    let host = TestGatewayHost()
    let session = try RivetDeviceGatewaySession(
        pairedDeviceID: UUID(),
        scopes: [pairedScope],
        host: host
    )
    let payload = Data("hello".utf8)

    let response = try await session.invokeRPC(
        remoteRequestID: 1,
        name: "tasks.list",
        payload: payload
    )
    #expect(response == payload)
    #expect(try await session.filterEvent(name: "tasks.changed", payload: payload) == payload)
    #expect(try await session.filterEvent(name: "private.changed", payload: payload) == nil)
    #expect(try await session.filterStateChange(name: "sync.status", payload: payload) == payload)
    #expect(try await session.filterStateChange(name: "private.state", payload: payload) == nil)
    try await session.requireStateRead("sync.status")
    try await session.requireStateWrite("sync.preference")

    await #expect(throws: RivetDeviceGatewayError.forbidden) {
        try await session.invokeRPC(
            remoteRequestID: 2,
            name: "tasks.deleteAll",
            payload: payload
        )
    }
    await #expect(throws: RivetDeviceGatewayError.forbidden) {
        try await session.requireStateRead("unknown.state")
    }

    let starts = await host.starts
    #expect(starts.map(\.name) == ["tasks.list"])
}

@Test func stateRoutesRequireTheExactStateCapability() async throws {
    let host = TestGatewayHost()
    let session = try RivetDeviceGatewaySession(
        pairedDeviceID: UUID(),
        scopes: [pairedScope],
        host: host
    )
    let payload = Data("encoded state args".utf8)

    await #expect(throws: RivetDeviceGatewayError.forbidden) {
        try await session.invokeRPC(
            remoteRequestID: 20,
            name: "$state/get",
            payload: payload
        )
    }
    await #expect(throws: RivetDeviceGatewayError.forbidden) {
        try await session.invokeStateRPC(
            remoteRequestID: 21,
            name: "$state/get",
            stateName: "private.state",
            payload: payload
        )
    }

    let response = try await session.invokeStateRPC(
        remoteRequestID: 22,
        name: "$state/get",
        stateName: "sync.status",
        payload: payload
    )
    #expect(response == Data([0x42]))
    let starts = await host.starts
    #expect(starts.map(\.name) == ["$state/get"])
}

@Test func remoteRequestIDsMapToHostIDsAndCancellationStaysInSession() async throws {
    let host = TestGatewayHost(blocksResponses: true)
    let first = try RivetDeviceGatewaySession(
        pairedDeviceID: UUID(),
        scopes: [pairedScope],
        host: host
    )
    let second = try RivetDeviceGatewaySession(
        pairedDeviceID: UUID(),
        scopes: [pairedScope],
        host: host
    )
    let request = Task {
        try await first.invokeRPC(
            remoteRequestID: 7,
            name: "tasks.list",
            payload: Data()
        )
    }

    let didStart = await eventually { await host.startedCount() == 1 }
    #expect(didStart)
    await second.cancel(remoteRequestID: 7)
    #expect(await host.cancellations.isEmpty)

    await #expect(throws: RivetDeviceGatewayError.duplicateRequestID(7)) {
        try await first.invokeRPC(
            remoteRequestID: 7,
            name: "tasks.list",
            payload: Data()
        )
    }

    await first.cancel(remoteRequestID: 7)
    await #expect(throws: RivetDeviceGatewayError.cancelled) {
        try await request.value
    }
    #expect(await host.cancellations == [100])
    #expect(await first.pendingRequestCount() == 0)
}

@Test func sessionsBoundPendingCallsAndMessageSizes() async throws {
    let host = TestGatewayHost(blocksResponses: true)
    let session = try RivetDeviceGatewaySession(
        pairedDeviceID: UUID(),
        scopes: [pairedScope],
        host: host,
        maximumMessageSize: 4,
        maximumPendingRequests: 1
    )

    await #expect(
        throws: RivetDeviceGatewayError.messageTooLarge(actual: 5, maximum: 4)
    ) {
        try await session.invokeRPC(
            remoteRequestID: 1,
            name: "tasks.list",
            payload: Data(repeating: 0, count: 5)
        )
    }

    let request = Task {
        try await session.invokeRPC(
            remoteRequestID: 2,
            name: "tasks.list",
            payload: Data()
        )
    }
    let didStart = await eventually { await host.startedCount() == 1 }
    #expect(didStart)

    await #expect(throws: RivetDeviceGatewayError.pendingRequestLimit(1)) {
        try await session.invokeRPC(
            remoteRequestID: 3,
            name: "tasks.list",
            payload: Data()
        )
    }
    await session.cancel(remoteRequestID: 2)
    await #expect(throws: RivetDeviceGatewayError.cancelled) {
        try await request.value
    }
}

@Test func gatewayBoundsAndRevokesSessions() async throws {
    let host = TestGatewayHost(blocksResponses: true)
    let gateway = RivetDeviceGateway(host: host, maximumSessions: 1)
    let firstID = UUID()
    let pairedDeviceID = UUID()
    let session = try await gateway.openSession(
        id: firstID,
        pairedDeviceID: pairedDeviceID,
        scopes: [pairedScope]
    )

    await #expect(throws: RivetDeviceGatewayError.duplicateSession(firstID)) {
        try await gateway.openSession(
            id: firstID,
            pairedDeviceID: pairedDeviceID,
            scopes: [pairedScope]
        )
    }
    await #expect(throws: RivetDeviceGatewayError.sessionLimit(1)) {
        try await gateway.openSession(pairedDeviceID: UUID(), scopes: [pairedScope])
    }

    let request = Task {
        try await session.invokeRPC(
            remoteRequestID: 1,
            name: "tasks.list",
            payload: Data()
        )
    }
    let didStart = await eventually { await host.startedCount() == 1 }
    #expect(didStart)

    await gateway.closeSession(id: firstID)
    #expect(await gateway.sessionCount() == 0)
    #expect(await session.isClosed())
    await #expect(throws: RivetDeviceGatewayError.cancelled) {
        try await request.value
    }
    await #expect(throws: RivetDeviceGatewayError.sessionClosed) {
        try await session.invokeRPC(
            remoteRequestID: 2,
            name: "tasks.list",
            payload: Data()
        )
    }
}

@Test func invalidScopeNamesAreRejectedBeforeSessionCreation() async {
    let host = TestGatewayHost()
    let invalid = RivetDeviceScope(name: "bad scope", rpcs: ["tasks.list"])

    #expect(throws: RivetDeviceGatewayError.invalidName("bad scope")) {
        try RivetDeviceGatewaySession(
            pairedDeviceID: UUID(),
            scopes: [invalid],
            host: host
        )
    }
}

@Test func revocationClosesOnlySessionsOwnedByThePairedDevice() async throws {
    let host = TestGatewayHost()
    let gateway = RivetDeviceGateway(host: host, maximumSessions: 3)
    let revokedDeviceID = UUID()
    let retainedDeviceID = UUID()
    let first = try await gateway.openSession(
        pairedDeviceID: revokedDeviceID,
        scopes: [pairedScope]
    )
    let second = try await gateway.openSession(
        pairedDeviceID: revokedDeviceID,
        scopes: [pairedScope]
    )
    let retained = try await gateway.openSession(
        pairedDeviceID: retainedDeviceID,
        scopes: [pairedScope]
    )

    await gateway.revokeSessions(deviceID: revokedDeviceID)

    #expect(await gateway.sessionCount() == 1)
    #expect(await first.isClosed())
    #expect(await second.isClosed())
    #expect(await !retained.isClosed())
    #expect(await gateway.session(id: retained.id) != nil)
}
