import Foundation
import RivetDeviceSession

public let rivetDeviceAppleBonjourServiceType = "_rivet-device._tcp"
public let rivetDeviceAppleBonjourMaximumTXTRecordSize = 128

public enum RivetDeviceAppleBonjourError: Error, Sendable, Equatable,
    CustomStringConvertible {
    case invalidAdvertisementID
    case invalidTXTRecord
    case unsupportedProtocolVersion
    case txtRecordTooLarge

    public var description: String {
        switch self {
        case .invalidAdvertisementID:
            "invalid Rivet device advertisement identifier"
        case .invalidTXTRecord:
            "invalid Rivet device Bonjour TXT record"
        case .unsupportedProtocolVersion:
            "unsupported Rivet device-session advertisement version"
        case .txtRecordTooLarge:
            "Rivet device Bonjour TXT record is too large"
        }
    }
}

/// The complete privacy-bounded discovery payload. It intentionally contains
/// no application, account, device, API, filename, or user-content fields.
public struct RivetDeviceAppleBonjourAdvertisement: Sendable, Equatable {
    public let protocolVersion: UInt8
    public let advertisementID: String
    public let pairingWindowOpen: Bool

    public init(
        advertisementID: String,
        pairingWindowOpen: Bool
    ) throws {
        guard Self.isValidAdvertisementID(advertisementID) else {
            throw RivetDeviceAppleBonjourError.invalidAdvertisementID
        }
        protocolVersion = rivetDeviceSessionVersion
        self.advertisementID = advertisementID
        self.pairingWindowOpen = pairingWindowOpen
    }

    public var txtRecordData: Data {
        let entries = [
            "id=\(advertisementID)",
            "pair=\(pairingWindowOpen ? 1 : 0)",
            "v=\(protocolVersion)"
        ]
        var result = Data()
        for entry in entries {
            let bytes = Data(entry.utf8)
            precondition(bytes.count <= 255)
            result.append(UInt8(bytes.count))
            result.append(bytes)
        }
        precondition(result.count <= rivetDeviceAppleBonjourMaximumTXTRecordSize)
        return result
    }

    public static func decode(
        txtRecordData: Data
    ) throws -> RivetDeviceAppleBonjourAdvertisement {
        guard !txtRecordData.isEmpty,
              txtRecordData.count <= rivetDeviceAppleBonjourMaximumTXTRecordSize else {
            if txtRecordData.count > rivetDeviceAppleBonjourMaximumTXTRecordSize {
                throw RivetDeviceAppleBonjourError.txtRecordTooLarge
            }
            throw RivetDeviceAppleBonjourError.invalidTXTRecord
        }
        var fields: [String: String] = [:]
        var offset = 0
        while offset < txtRecordData.count {
            let length = Int(txtRecordData[offset])
            offset += 1
            guard length > 0,
                  offset + length <= txtRecordData.count,
                  let entry = String(
                    data: txtRecordData.subdata(in: offset..<(offset + length)),
                    encoding: .utf8
                  ),
                  let separator = entry.firstIndex(of: "="),
                  separator != entry.startIndex else {
                throw RivetDeviceAppleBonjourError.invalidTXTRecord
            }
            let key = String(entry[..<separator])
            let value = String(entry[entry.index(after: separator)...])
            guard fields[key] == nil else {
                throw RivetDeviceAppleBonjourError.invalidTXTRecord
            }
            fields[key] = value
            offset += length
        }
        guard fields.count == 3,
              let versionText = fields["v"],
              let version = UInt8(versionText),
              let advertisementID = fields["id"],
              let pairingText = fields["pair"],
              pairingText == "0" || pairingText == "1" else {
            throw RivetDeviceAppleBonjourError.invalidTXTRecord
        }
        guard version == rivetDeviceSessionVersion else {
            throw RivetDeviceAppleBonjourError.unsupportedProtocolVersion
        }
        let advertisement = try RivetDeviceAppleBonjourAdvertisement(
            advertisementID: advertisementID,
            pairingWindowOpen: pairingText == "1"
        )
        guard advertisement.txtRecordData == txtRecordData else {
            throw RivetDeviceAppleBonjourError.invalidTXTRecord
        }
        return advertisement
    }

    private static func isValidAdvertisementID(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        }
    }
}

package struct RivetDeviceAppleBonjourService: Sendable, Equatable {
    package let name: String
    package let type: String
    package let txtRecord: Data

    package init(
        name: String,
        advertisement: RivetDeviceAppleBonjourAdvertisement
    ) {
        self.name = name
        type = rivetDeviceAppleBonjourServiceType
        txtRecord = advertisement.txtRecordData
    }
}
