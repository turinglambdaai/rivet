import Foundation
import Testing
@testable import RivetRuntime

private actor RecordingRPCClient: RivetRPCClient {
    private var recorded: [(String, [RivetValue])] = []

    func call(_ name: String, arguments: [RivetValue]) async throws -> RivetValue {
        recorded.append((name, arguments))
        return .string(name)
    }

    func snapshot() -> [(String, [RivetValue])] {
        recorded
    }
}

@Test func rpcClientStateHelpersUseReservedRoutes() async throws {
    let client = RecordingRPCClient()
    #expect(try await client.getState("volume") == .string("$state/get"))
    #expect(
        try await client.setState("volume", value: .int64(7))
            == .string("$state/set")
    )

    let requests = await client.snapshot()
    #expect(requests.count == 2)
    #expect(requests[0].0 == "$state/get")
    #expect(requests[0].1 == [.string("volume")])
    #expect(requests[1].0 == "$state/set")
    #expect(requests[1].1 == [.string("volume"), .int64(7)])
}
