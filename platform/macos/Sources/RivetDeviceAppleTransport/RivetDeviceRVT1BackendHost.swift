import Foundation
import RivetDevice
import RivetRuntime

public enum RivetDeviceRVT1BackendHostError: Error, Equatable, Sendable {
    case invalidArguments
    case requestIDExhausted
}

/// Adapts the embedded backend client to the gateway's bounded host-call
/// contract. Payloads are encoded RivetValue argument lists, not JSON.
public actor RivetDeviceRVT1BackendHost: RivetDeviceGatewayHost {
    private let client: any RivetRPCClient
    private var nextID: UInt64 = 1
    private var work: [UInt64: Task<Data, any Error>] = [:]

    public init(client: any RivetRPCClient) {
        self.client = client
    }

    public func startRPC(
        name: String,
        payload: Data
    ) async throws -> RivetDeviceGatewayHostCall {
        guard case .list(let arguments) = try decodeRivetValue(payload) else {
            throw RivetDeviceRVT1BackendHostError.invalidArguments
        }
        let id = try allocateID()
        let client = self.client
        let workTask = Task<Data, any Error> {
            let result = try await client.call(name, arguments: arguments)
            return try encodeRivetValue(result)
        }
        work[id] = workTask
        let responseTask = Task<Data, any Error> { [weak self] in
            do {
                let data = try await workTask.value
                await self?.finish(id: id)
                return data
            } catch {
                await self?.finish(id: id)
                throw error
            }
        }
        return RivetDeviceGatewayHostCall(id: id, response: responseTask)
    }

    public func cancelRPC(id: UInt64) async {
        // Drop the entry now: a backend call that ignores cancellation never
        // reaches finish(), and the abandoned response task no-ops when it
        // removes an id that is already gone.
        work.removeValue(forKey: id)?.cancel()
    }

    private func allocateID() throws -> UInt64 {
        for _ in 0...work.count {
            let candidate = nextID
            nextID = nextID == UInt64.max ? 1 : nextID + 1
            if candidate != 0, work[candidate] == nil {
                return candidate
            }
        }
        throw RivetDeviceRVT1BackendHostError.requestIDExhausted
    }

    private func finish(id: UInt64) {
        work.removeValue(forKey: id)
    }
}
