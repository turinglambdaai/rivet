import Foundation

public let rivetProtocolVersion: UInt8 = 1

public enum RivetMessageType: UInt8, Sendable {
    case hello = 1
    case request = 2
    case response = 3
    case error = 4
    case event = 5
    case cancel = 6
    case shutdown = 7
}

public enum RivetValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int64(Int64)
    case string(String)
    case bytes(Data)
    case list([RivetValue])
}

public struct RivetFrame: Equatable, Sendable {
    public var type: RivetMessageType
    public var id: UInt64
    public var payload: Data

    public init(type: RivetMessageType, id: UInt64, payload: Data = Data()) {
        self.type = type
        self.id = id
        self.payload = payload
    }
}

public enum RivetProtocolError: Error, Equatable, CustomStringConvertible {
    case truncated
    case invalidMagic
    case unsupportedVersion(UInt8)
    case unknownMessageType(UInt8)
    case unknownValueTag(UInt8)
    case invalidUTF8
    case trailingBytes
    case lengthOverflow

    public var description: String {
        switch self {
        case .truncated: return "truncated Rivet payload"
        case .invalidMagic: return "invalid Rivet frame magic"
        case .unsupportedVersion(let version): return "unsupported Rivet protocol version \(version)"
        case .unknownMessageType(let value): return "unknown Rivet message type \(value)"
        case .unknownValueTag(let value): return "unknown Rivet value tag \(value)"
        case .invalidUTF8: return "invalid UTF-8 in Rivet string"
        case .trailingBytes: return "trailing bytes after Rivet value"
        case .lengthOverflow: return "Rivet value exceeds UInt32 protocol limit"
        }
    }
}

private enum ValueTag: UInt8 {
    case null = 0x00
    case falseValue = 0x01
    case trueValue = 0x02
    case int64 = 0x03
    case string = 0x04
    case bytes = 0x05
    case list = 0x06
}

private let magic = Data([0x52, 0x56, 0x54, 0x31]) // RVT1

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}

private struct Reader {
    let data: Data
    var offset: Int = 0

    mutating func readByte() throws -> UInt8 {
        guard offset < data.count else { throw RivetProtocolError.truncated }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readInteger<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let width = MemoryLayout<T>.size
        guard offset <= data.count - width else { throw RivetProtocolError.truncated }
        var result: T = 0
        for i in 0..<width {
            result |= T(data[offset + i]) << T(i * 8)
        }
        offset += width
        return result
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, offset <= data.count - count else {
            throw RivetProtocolError.truncated
        }
        let result = data.subdata(in: offset..<(offset + count))
        offset += count
        return result
    }

    var isAtEnd: Bool { offset == data.count }
}

public func encodeRivetValue(_ value: RivetValue) throws -> Data {
    var result = Data()
    try encode(value, into: &result)
    return result
}

private func encode(_ value: RivetValue, into output: inout Data) throws {
    switch value {
    case .null:
        output.append(ValueTag.null.rawValue)
    case .bool(false):
        output.append(ValueTag.falseValue.rawValue)
    case .bool(true):
        output.append(ValueTag.trueValue.rawValue)
    case .int64(let value):
        output.append(ValueTag.int64.rawValue)
        output.appendLE(UInt64(bitPattern: value))
    case .string(let value):
        let bytes = Data(value.utf8)
        guard bytes.count <= Int(UInt32.max) else { throw RivetProtocolError.lengthOverflow }
        output.append(ValueTag.string.rawValue)
        output.appendLE(UInt32(bytes.count))
        output.append(bytes)
    case .bytes(let bytes):
        guard bytes.count <= Int(UInt32.max) else { throw RivetProtocolError.lengthOverflow }
        output.append(ValueTag.bytes.rawValue)
        output.appendLE(UInt32(bytes.count))
        output.append(bytes)
    case .list(let values):
        guard values.count <= Int(UInt32.max) else { throw RivetProtocolError.lengthOverflow }
        output.append(ValueTag.list.rawValue)
        output.appendLE(UInt32(values.count))
        for value in values {
            try encode(value, into: &output)
        }
    }
}

public func decodeRivetValue(_ data: Data) throws -> RivetValue {
    var reader = Reader(data: data)
    let value = try decodeValue(from: &reader)
    guard reader.isAtEnd else { throw RivetProtocolError.trailingBytes }
    return value
}

private func decodeValue(from reader: inout Reader) throws -> RivetValue {
    let rawTag = try reader.readByte()
    guard let tag = ValueTag(rawValue: rawTag) else {
        throw RivetProtocolError.unknownValueTag(rawTag)
    }

    switch tag {
    case .null:
        return .null
    case .falseValue:
        return .bool(false)
    case .trueValue:
        return .bool(true)
    case .int64:
        let bits: UInt64 = try reader.readInteger(UInt64.self)
        return .int64(Int64(bitPattern: bits))
    case .string:
        let length: UInt32 = try reader.readInteger(UInt32.self)
        let bytes = try reader.readData(count: Int(length))
        guard let value = String(data: bytes, encoding: .utf8) else {
            throw RivetProtocolError.invalidUTF8
        }
        return .string(value)
    case .bytes:
        let length: UInt32 = try reader.readInteger(UInt32.self)
        return .bytes(try reader.readData(count: Int(length)))
    case .list:
        let count: UInt32 = try reader.readInteger(UInt32.self)
        var values: [RivetValue] = []
        values.reserveCapacity(Int(count))
        for _ in 0..<count {
            values.append(try decodeValue(from: &reader))
        }
        return .list(values)
    }
}

public func encodeRivetFrame(_ frame: RivetFrame) throws -> Data {
    guard frame.payload.count <= Int(UInt32.max) else {
        throw RivetProtocolError.lengthOverflow
    }

    var result = Data()
    result.append(magic)
    result.append(rivetProtocolVersion)
    result.append(frame.type.rawValue)
    result.appendLE(frame.id)
    result.appendLE(UInt32(frame.payload.count))
    result.append(frame.payload)
    return result
}

public func decodeRivetFrame(_ data: Data) throws -> RivetFrame {
    var reader = Reader(data: data)
    guard try reader.readData(count: 4) == magic else {
        throw RivetProtocolError.invalidMagic
    }

    let version = try reader.readByte()
    guard version == rivetProtocolVersion else {
        throw RivetProtocolError.unsupportedVersion(version)
    }

    let rawType = try reader.readByte()
    guard let type = RivetMessageType(rawValue: rawType) else {
        throw RivetProtocolError.unknownMessageType(rawType)
    }

    let id: UInt64 = try reader.readInteger(UInt64.self)
    let length: UInt32 = try reader.readInteger(UInt32.self)
    let payload = try reader.readData(count: Int(length))
    guard reader.isAtEnd else { throw RivetProtocolError.trailingBytes }
    return RivetFrame(type: type, id: id, payload: payload)
}
