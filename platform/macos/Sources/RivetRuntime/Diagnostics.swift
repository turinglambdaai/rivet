import Foundation

public struct RivetDiagnosticRecord: Sendable, Equatable {
    public var layer: String
    public var event: String
    public var status: String
    public var lastProtocolEvent: String
    public var requestID: UInt64?
    public var message: String?

    public init(
        layer: String,
        event: String,
        status: String,
        lastProtocolEvent: String = "none",
        requestID: UInt64? = nil,
        message: String? = nil
    ) {
        self.layer = layer
        self.event = event
        self.status = status
        self.lastProtocolEvent = lastProtocolEvent
        self.requestID = requestID
        self.message = message
    }

    public func jsonLine() -> String {
        var object: [String: Any] = [
            "schema": "rivet.diagnostic.v1",
            "layer": layer,
            "event": event,
            "status": status,
            "last_protocol_event": lastProtocolEvent
        ]
        if let requestID { object["request_id"] = requestID }
        if let message, !message.isEmpty { object["message"] = message }
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ) else {
            return "{\"schema\":\"rivet.diagnostic.v1\",\"layer\":\"native-runtime\",\"event\":\"diagnostic-encoding\",\"status\":\"failure\",\"last_protocol_event\":\"none\"}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}

public typealias RivetDiagnosticSink = @Sendable (RivetDiagnosticRecord) -> Void

public enum RivetDiagnostics {
    private static let outputLock = NSLock()

    public static let discard: RivetDiagnosticSink = { _ in }

    public static let standardError: RivetDiagnosticSink = { record in
        let data = Data((record.jsonLine() + "\n").utf8)
        outputLock.lock()
        defer { outputLock.unlock() }
        try? FileHandle.standardError.write(contentsOf: data)
    }
}
