import Foundation

/// Real-time chart series data plane, Swift side.
///
/// The batch layout is the cross-language contract defined by
/// ``rivet/chart.rkt``: little-endian `u32` magic `0x52564331` ("RVC1"),
/// `u32` sample count, `i64` absolute first index, then count x
/// (`i64` timestamp-ns, `i64` value). The C++ decoder lives in
/// `runtime/include/rivet/chart_batch.hpp`; the three implementations are
/// pinned by shared golden bytes in each test suite.
public enum RivetChartBatch {

    public static let magic: UInt32 = 0x5256_4331

    public struct Sample: Equatable, Sendable {
        public var tsNs: Int64
        public var value: Int64

        public init(tsNs: Int64, value: Int64) {
            self.tsNs = tsNs
            self.value = value
        }
    }

    public struct Batch: Equatable, Sendable {
        public var firstIndex: UInt64
        public var samples: [Sample]

        public init(firstIndex: UInt64, samples: [Sample]) {
            self.firstIndex = firstIndex
            self.samples = samples
        }
    }

    public enum DecodeError: Error, Equatable, Sendable {
        case shortHeader(Int)
        case magicMismatch(UInt32)
        case lengthMismatch(declared: Int, actual: Int)
    }

    public static func decode(_ data: Data) throws -> Batch {
        guard data.count >= 16 else { throw DecodeError.shortHeader(data.count) }
        let bytes = [UInt8](data)
        let magic = readU32LE(bytes, 0)
        guard magic == RivetChartBatch.magic else { throw DecodeError.magicMismatch(magic) }
        let count = Int(readU32LE(bytes, 4))
        let expected = 16 + count * 16
        guard data.count == expected else {
            throw DecodeError.lengthMismatch(declared: expected, actual: data.count)
        }
        let firstIndex = UInt64(bitPattern: readI64LE(bytes, 8))
        var samples: [Sample] = []
        samples.reserveCapacity(count)
        for i in 0..<count {
            let base = 16 + i * 16
            samples.append(Sample(tsNs: readI64LE(bytes, base), value: readI64LE(bytes, base + 8)))
        }
        return Batch(firstIndex: firstIndex, samples: samples)
    }

    public static func encode(_ samples: [Sample], firstIndex: UInt64) -> Data {
        var data = Data(capacity: 16 + samples.count * 16)
        appendU32LE(&data, RivetChartBatch.magic)
        appendU32LE(&data, UInt32(clamping: samples.count))
        appendI64LE(&data, Int64(bitPattern: firstIndex))
        for sample in samples {
            appendI64LE(&data, sample.tsNs)
            appendI64LE(&data, sample.value)
        }
        return data
    }

    private static func readU32LE(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func readI64LE(_ bytes: [UInt8], _ offset: Int) -> Int64 {
        var bits: UInt64 = 0
        for i in stride(from: 7, through: 0, by: -1) {
            bits = (bits << 8) | UInt64(bytes[offset + i])
        }
        return Int64(bitPattern: bits)
    }

    private static func appendU32LE(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 24) & 0xff))
    }

    private static func appendI64LE(_ data: inout Data, _ value: Int64) {
        let bits = UInt64(bitPattern: value)
        for i in 0..<8 {
            data.append(UInt8((bits >> (8 * UInt64(i))) & 0xff))
        }
    }
}
