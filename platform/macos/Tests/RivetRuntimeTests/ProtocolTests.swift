import Foundation
import Testing
@testable import RivetRuntime

private struct GoldenRecord {
    let kind: String
    let name: String
    let bytes: Data
}

private func hexData(_ text: Substring) throws -> Data {
    guard text.count.isMultiple(of: 2) else {
        throw NSError(domain: "RivetGolden", code: 1)
    }
    var result = Data()
    var index = text.startIndex
    while index < text.endIndex {
        let next = text.index(index, offsetBy: 2)
        guard let byte = UInt8(text[index..<next], radix: 16) else {
            throw NSError(domain: "RivetGolden", code: 2)
        }
        result.append(byte)
        index = next
    }
    return result
}

private func loadGoldenRecords() throws -> [GoldenRecord] {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 {
        url.deleteLastPathComponent()
    }
    url.appendPathComponent("tests/protocol-golden.txt")

    let contents = try String(contentsOf: url, encoding: .utf8)
    return try contents.split(whereSeparator: \ .isNewline).compactMap { rawLine in
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
        let parts = line.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3 else {
            throw NSError(domain: "RivetGolden", code: 3)
        }
        return GoldenRecord(
            kind: String(parts[0]),
            name: String(parts[1]),
            bytes: try hexData(parts[2])
        )
    }
}

private func goldenValue(_ name: String) throws -> RivetValue {
    switch name {
    case "null": return .null
    case "false": return .bool(false)
    case "true": return .bool(true)
    case "int64-neg2": return .int64(-2)
    case "int64-42": return .int64(42)
    case "string-hello": return .string("hello")
    case "string-unicode": return .string("你好 Rivet")
    case "bytes-binary": return .bytes(Data([0x00, 0xff, 0x7f]))
    case "list-nested": return .list([.string("nested"), .int64(7), .bool(true)])
    default: throw NSError(domain: "RivetGolden", code: 4)
    }
}

@Test func sharedGoldenVectors() throws {
    for record in try loadGoldenRecords() {
        switch record.kind {
        case "value":
            let expected = try goldenValue(record.name)
            #expect(try encodeRivetValue(expected) == record.bytes)
            #expect(try decodeRivetValue(record.bytes) == expected)
        case "frame":
            #expect(record.name == "request-99")
            let decoded = try decodeRivetFrame(record.bytes)
            #expect(decoded.type == .request)
            #expect(decoded.id == 99)
            #expect(try decodeRivetValue(decoded.payload) == .list([.string("increment"), .int64(41)]))
            #expect(try encodeRivetFrame(decoded) == record.bytes)
        case "invalid-value":
            #expect(throws: RivetProtocolError.self) {
                try decodeRivetValue(record.bytes)
            }
        case "invalid-frame":
            #expect(throws: RivetProtocolError.self) {
                try decodeRivetFrame(record.bytes)
            }
        default:
            Issue.record("unknown protocol fixture kind: \(record.kind)")
        }
    }
}

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

@Test func rejectsOversizedFrame() throws {
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
