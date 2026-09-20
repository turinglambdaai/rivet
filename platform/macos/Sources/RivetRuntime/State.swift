import Foundation

public struct RivetStateChange: Sendable, Equatable {
    public let name: String
    public let value: RivetValue

    public init(name: String, value: RivetValue) {
        self.name = name
        self.value = value
    }
}

public extension RivetClient {
    func getState(_ name: String) async throws -> RivetValue {
        try await call("$state/get", arguments: [.string(name)])
    }

    @discardableResult
    func setState(_ name: String, value: RivetValue) async throws -> RivetValue {
        try await call("$state/set", arguments: [.string(name), value])
    }

    static func stateChange(eventName: String, value: RivetValue) -> RivetStateChange? {
        guard eventName == "$state",
              case .list(let fields) = value,
              fields.count == 2,
              case .string(let name) = fields[0] else {
            return nil
        }
        return RivetStateChange(name: name, value: fields[1])
    }
}
