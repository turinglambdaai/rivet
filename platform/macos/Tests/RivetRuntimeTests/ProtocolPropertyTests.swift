import Foundation
import Testing
@testable import RivetRuntime

private let corpusCount = 512
private let corpusSeed: UInt64 = 0x72697665742d7631
private let corpusFinalState: UInt64 = 0xa6bf907b781d9548
private let corpusFingerprint: UInt64 = 0x2c89b9f6a1b6232c
private let lcgMultiplier: UInt64 = 6_364_136_223_846_793_005
private let lcgIncrement: UInt64 = 1_442_695_040_888_963_407
private let fnvOffset: UInt64 = 14_695_981_039_346_656_037
private let fnvPrime: UInt64 = 1_099_511_628_211

private struct CorpusRNG {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* lcgMultiplier &+ lcgIncrement
        return state
    }
}

private let corpusStringTokens = [
    "a",
    "\u{0000}",
    "你",
    "🙂",
    "Rivet"
]

private func randomValue(_ rng: inout CorpusRNG, depth: Int) -> RivetValue {
    let variantCount: UInt64 = depth >= 4 ? 5 : 6
    switch rng.next() % variantCount {
    case 0:
        return .null
    case 1:
        return .bool((rng.next() & 1) != 0)
    case 2:
        return .int64(Int64(bitPattern: rng.next()))
    case 3:
        let count = Int(rng.next() % 8)
        var value = ""
        for _ in 0..<count {
            value += corpusStringTokens[Int(rng.next() % UInt64(corpusStringTokens.count))]
        }
        return .string(value)
    case 4:
        let count = Int(rng.next() % 24)
        var bytes = Data()
        bytes.reserveCapacity(count)
        for _ in 0..<count {
            bytes.append(UInt8(truncatingIfNeeded: rng.next()))
        }
        return .bytes(bytes)
    case 5:
        let count = Int(rng.next() % 4)
        var values: [RivetValue] = []
        values.reserveCapacity(count)
        for _ in 0..<count {
            values.append(randomValue(&rng, depth: depth + 1))
        }
        return .list(values)
    default:
        Issue.record("unreachable deterministic corpus variant")
        return .null
    }
}

private func fingerprintByte(_ hash: UInt64, _ byte: UInt8) -> UInt64 {
    (hash ^ UInt64(byte)) &* fnvPrime
}

private func fingerprintValue(_ hash: UInt64, _ encoded: Data) -> UInt64 {
    var result = hash
    let length = UInt64(encoded.count)
    for index in 0..<8 {
        result = fingerprintByte(
            result,
            UInt8(truncatingIfNeeded: length >> UInt64(index * 8))
        )
    }
    for byte in encoded {
        result = fingerprintByte(result, byte)
    }
    return result
}

private func minimalFrame(version: UInt8, type: UInt8) -> Data {
    var result = Data([0x52, 0x56, 0x54, 0x31, version, type])
    result.append(Data(repeating: 0, count: 12))
    return result
}

@Test func deterministicProtocolCorpus() throws {
    var rng = CorpusRNG(state: corpusSeed)
    var fingerprint = fnvOffset

    for caseIndex in 0..<corpusCount {
        let value = randomValue(&rng, depth: 0)
        let encoded = try encodeRivetValue(value)
        let decoded = try decodeRivetValue(encoded)

        #expect(try encodeRivetValue(decoded) == encoded,
                "corpus case \(caseIndex) failed canonical round-trip")

        // Every strict prefix is truncated, including the empty prefix.
        for prefixCount in 0..<encoded.count {
            let prefix = Data(encoded.prefix(prefixCount))
            #expect(throws: RivetProtocolError.self) {
                try decodeRivetValue(prefix)
            }
        }

        // Standalone values are canonical and reject trailing bytes.
        var withTrailing = encoded
        withTrailing.append(0x00)
        #expect(throws: RivetProtocolError.self) {
            try decodeRivetValue(withTrailing)
        }

        fingerprint = fingerprintValue(fingerprint, encoded)
    }

    #expect(rng.state == corpusFinalState)
    #expect(fingerprint == corpusFingerprint)
}

@Test func exhaustiveProtocolDiscriminants() throws {
    // RVT1 v1 defines value tags 0x00...0x06. Every other byte must be an
    // unknown tag, independently of the selected invalid golden fixtures.
    for raw in 7...255 {
        #expect(throws: RivetProtocolError.self) {
            try decodeRivetValue(Data([UInt8(raw)]))
        }
    }

    // Message type is a one-byte closed enum: 1...7 are valid, all other
    // values must fail before payload semantics are considered.
    for raw in 0...255 {
        let byte = UInt8(raw)
        let encoded = minimalFrame(version: rivetProtocolVersion, type: byte)
        if (1...7).contains(raw) {
            let decoded = try decodeRivetFrame(encoded)
            #expect(decoded.type.rawValue == byte)
        } else {
            #expect(throws: RivetProtocolError.self) {
                try decodeRivetFrame(encoded)
            }
        }
    }

    // Version 1 is the only RVT1 version accepted today. Exhaust the entire
    // byte domain so a future parser change cannot silently accept another
    // version without an explicit protocol decision.
    for raw in 0...255 {
        let byte = UInt8(raw)
        let encoded = minimalFrame(
            version: byte,
            type: RivetMessageType.request.rawValue
        )
        if byte == rivetProtocolVersion {
            _ = try decodeRivetFrame(encoded)
        } else {
            #expect(throws: RivetProtocolError.self) {
                try decodeRivetFrame(encoded)
            }
        }
    }
}
