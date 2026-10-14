import CryptoKit
import Foundation

public enum RivetDeviceAppleCertificateError: Error, Sendable, Equatable,
    CustomStringConvertible {
    case malformedDER
    case subjectPublicKeyInfoMissing

    public var description: String {
        switch self {
        case .malformedDER:
            "malformed DER certificate"
        case .subjectPublicKeyInfoMissing:
            "certificate SubjectPublicKeyInfo is missing"
        }
    }
}

public enum RivetDeviceAppleSPKI {
    /// Returns the complete DER SubjectPublicKeyInfo TLV from an X.509
    /// certificate. The TLS pin hashes this value, not the certificate or raw
    /// public-key payload.
    public static func subjectPublicKeyInfo(
        certificateDER: Data
    ) throws -> Data {
        let certificate = try DERElement.parseExactly(certificateDER)
        guard certificate.tag == 0x30 else {
            throw RivetDeviceAppleCertificateError.malformedDER
        }
        let certificateFields = try certificate.children(in: certificateDER)
        guard certificateFields.count == 3,
              certificateFields[0].tag == 0x30 else {
            throw RivetDeviceAppleCertificateError.malformedDER
        }

        let tbs = certificateFields[0]
        let fields = try tbs.children(in: certificateDER)
        var index = 0
        if fields.first?.tag == 0xa0 {
            index += 1
        }
        // serialNumber, signature, issuer, validity, subject, subjectPublicKeyInfo
        guard fields.count > index + 5 else {
            throw RivetDeviceAppleCertificateError.subjectPublicKeyInfoMissing
        }
        let expectedTags: [UInt8] = [0x02, 0x30, 0x30, 0x30, 0x30]
        for (offset, tag) in expectedTags.enumerated() {
            guard fields[index + offset].tag == tag else {
                throw RivetDeviceAppleCertificateError.malformedDER
            }
        }
        let spki = fields[index + 5]
        guard spki.tag == 0x30 else {
            throw RivetDeviceAppleCertificateError.subjectPublicKeyInfoMissing
        }
        return certificateDER.subdata(in: spki.fullRange)
    }

    public static func fingerprint(certificateDER: Data) throws -> Data {
        let spki = try subjectPublicKeyInfo(certificateDER: certificateDER)
        return Data(SHA256.hash(data: spki))
    }
}

private struct DERElement {
    let tag: UInt8
    let fullRange: Range<Int>
    let contentRange: Range<Int>

    static func parseExactly(_ data: Data) throws -> DERElement {
        let element = try parse(data, at: 0, limit: data.count)
        guard element.fullRange.upperBound == data.count else {
            throw RivetDeviceAppleCertificateError.malformedDER
        }
        return element
    }

    static func parse(
        _ data: Data,
        at offset: Int,
        limit: Int
    ) throws -> DERElement {
        guard offset >= 0, limit <= data.count, offset < limit else {
            throw RivetDeviceAppleCertificateError.malformedDER
        }
        let tag = data[offset]
        // X.509 fields used here all have one-byte tags. Reject high-tag-number
        // forms rather than accepting an ambiguous encoding.
        guard tag & 0x1f != 0x1f, offset + 1 < limit else {
            throw RivetDeviceAppleCertificateError.malformedDER
        }
        let firstLength = data[offset + 1]
        let headerLength: Int
        let contentLength: Int
        if firstLength & 0x80 == 0 {
            headerLength = 2
            contentLength = Int(firstLength)
        } else {
            let lengthByteCount = Int(firstLength & 0x7f)
            guard lengthByteCount > 0,
                  lengthByteCount <= 4,
                  offset + 2 + lengthByteCount <= limit,
                  data[offset + 2] != 0 else {
                throw RivetDeviceAppleCertificateError.malformedDER
            }
            var decodedLength = 0
            for index in 0..<lengthByteCount {
                decodedLength = (decodedLength << 8) | Int(data[offset + 2 + index])
            }
            guard decodedLength >= 128 else {
                throw RivetDeviceAppleCertificateError.malformedDER
            }
            headerLength = 2 + lengthByteCount
            contentLength = decodedLength
        }
        let contentStart = offset + headerLength
        let (contentEnd, overflow) = contentStart.addingReportingOverflow(contentLength)
        guard !overflow, contentEnd <= limit else {
            throw RivetDeviceAppleCertificateError.malformedDER
        }
        return DERElement(
            tag: tag,
            fullRange: offset..<contentEnd,
            contentRange: contentStart..<contentEnd
        )
    }

    func children(in data: Data) throws -> [DERElement] {
        guard tag & 0x20 != 0 else {
            throw RivetDeviceAppleCertificateError.malformedDER
        }
        var result: [DERElement] = []
        var offset = contentRange.lowerBound
        while offset < contentRange.upperBound {
            let child = try DERElement.parse(
                data,
                at: offset,
                limit: contentRange.upperBound
            )
            result.append(child)
            offset = child.fullRange.upperBound
        }
        guard offset == contentRange.upperBound else {
            throw RivetDeviceAppleCertificateError.malformedDER
        }
        return result
    }
}
