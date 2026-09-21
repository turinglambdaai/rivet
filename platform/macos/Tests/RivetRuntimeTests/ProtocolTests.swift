import Foundation
import Testing
@testable import RivetRuntime

@Test func valueRoundTrips() throws {
    let values: [RivetValue] = [
        .null,
        .bool(false),
        .bool(true),
        .int64(-42),
        .int64(0),
        .int64(42),
        .string("hello"),
        .string("你好 Rivet"),
        .bytes(Data([0x00, 0xff, 0x7f])),
        .list([.string("nested"), .int64(7), .bool(true)])
    ]

    for value in values {
        #expect(try decodeRivetValue(encodeRivetValue(value)) == value)
    }
}

@Test func requestFrameMatchesRVT1Layout() throws {
    let payload = try encodeRivetValue(.list([.string("increment"), .int64(41)]))
    let frame = RivetFrame(type: .request, id: 99, payload: payload)
    let encoded = try encodeRivetFrame(frame)

    #expect(Array(encoded.prefix(6)) == [
        0x52, 0x56, 0x54, 0x31, // RVT1
        0x01,                    // protocol
        0x02                     // request
    ])
    #expect(try decodeRivetFrame(encoded) == frame)
}

@Test func int64IsLittleEndianTwosComplement() throws {
    let encoded = try encodeRivetValue(.int64(-2))
    #expect(Array(encoded) == [
        0x03,
        0xfe, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff
    ])
}

@Test func rejectsExcessiveNesting() throws {
    var value: RivetValue = .null
    for _ in 0...rivetMaxValueDepth {
        value = .list([value])
    }
    #expect(throws: RivetProtocolError.nestingTooDeep) {
        try encodeRivetValue(value)
    }

    var encoded = Data()
    for _ in 0...rivetMaxValueDepth {
        encoded.append(contentsOf: [0x06, 0x01, 0x00, 0x00, 0x00])
    }
    encoded.append(0x00)
    #expect(throws: RivetProtocolError.nestingTooDeep) {
        try decodeRivetValue(encoded)
    }
}

@Test func rejectsMalformedPayloads() throws {
    #expect(throws: RivetProtocolError.self) {
        try decodeRivetValue(Data([0xff]))
    }
    #expect(throws: RivetProtocolError.self) {
        try decodeRivetValue(Data([0x04, 0x01, 0x00, 0x00, 0x00, 0xff]))
    }
    #expect(throws: RivetProtocolError.self) {
        try decodeRivetFrame(Data("BAD!".utf8))
    }
    #expect(throws: RivetProtocolError.self) {
        try decodeRivetValue(Data([0x06, 0xff, 0xff, 0xff, 0xff]))
    }

    // RVT1 header with payload length 64 MiB + 1 and no payload.
    let oversized = Data([
        0x52, 0x56, 0x54, 0x31,
        0x01, 0x02,
        0, 0, 0, 0, 0, 0, 0, 0,
        0x01, 0x00, 0x00, 0x04
    ])
    #expect(throws: RivetProtocolError.self) {
        try decodeRivetFrame(oversized)
    }
}
