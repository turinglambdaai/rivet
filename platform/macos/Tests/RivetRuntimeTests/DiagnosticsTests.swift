import Foundation
import Testing
@testable import RivetRuntime

@Test func diagnosticRecordUsesStableJSONLShape() throws {
    let record = RivetDiagnosticRecord(
        layer: "racket-backend",
        event: "rpc-dispatch",
        status: "failure",
        lastProtocolEvent: "request\nread",
        requestID: 42,
        message: "quote: \" and control: \u{1}"
    )

    let data = try #require(record.jsonLine().data(using: .utf8))
    let object = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    #expect(object["schema"] as? String == "rivet.diagnostic.v1")
    #expect(object["layer"] as? String == "racket-backend")
    #expect(object["event"] as? String == "rpc-dispatch")
    #expect(object["status"] as? String == "failure")
    #expect(object["last_protocol_event"] as? String == "request\nread")
    #expect((object["request_id"] as? NSNumber)?.uint64Value == 42)
    #expect(object["message"] as? String == "quote: \" and control: \u{1}")
}
