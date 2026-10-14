import CryptoKit
import Foundation
import RivetDevice
import RivetRuntime

public let rivetDeviceSessionVersion: UInt8 = 1
public let rivetDeviceSessionMaximumRecordSize = 8 * 1024
public let rivetDeviceSessionMaximumPayloadSize = rivetDeviceSessionMaximumRecordSize - 8
public let rivetDeviceSessionMaximumScopeCount = 64

public enum RivetDeviceSessionRejectCode: String, Sendable, CaseIterable {
    case authenticationFailed = "authentication_failed"
    case pairingUnavailable = "pairing_unavailable"
    case pairingRejected = "pairing_rejected"
    case pairingExpired = "pairing_expired"
    case serverBusy = "server_busy"
    case internalError = "internal_error"
}

public enum RivetDeviceSessionMessage: Sendable, Equatable {
    case authenticate(applicationID: String, deviceID: UUID, clientNonce: Data)
    case authChallenge(serverNonce: Data)
    case authProof(Data)
    case pairStart(
        applicationID: String,
        windowID: UUID,
        deviceName: String,
        clientNonce: Data
    )
    case pairChallenge(attemptID: UUID, serverNonce: Data)
    case pairDecision(attemptID: UUID, confirmed: Bool)
    case accept(
        sessionID: UUID,
        scopeNames: [String],
        maximumPayload: Int,
        maximumPending: Int
    )
    case paired(
        deviceID: UUID,
        credential: Data,
        sessionID: UUID,
        scopeNames: [String],
        maximumPayload: Int,
        maximumPending: Int
    )
    case reject(RivetDeviceSessionRejectCode)
}

public enum RivetDeviceSessionProtocolError: Error, Sendable, Equatable,
    CustomStringConvertible {
    case truncated
    case invalidMagic
    case unsupportedVersion(UInt8)
    case unknownMessageType(UInt8)
    case recordTooLarge
    case malformedPayload
    case invalidField
    case decoderFailed

    public var description: String {
        switch self {
        case .truncated:
            "truncated Rivet device-session record"
        case .invalidMagic:
            "invalid Rivet device-session magic"
        case .unsupportedVersion:
            "unsupported Rivet device-session version"
        case .unknownMessageType:
            "unknown Rivet device-session message type"
        case .recordTooLarge:
            "Rivet device-session record exceeds its size limit"
        case .malformedPayload:
            "malformed Rivet device-session payload"
        case .invalidField:
            "invalid Rivet device-session field"
        case .decoderFailed:
            "Rivet device-session decoder is closed after a protocol failure"
        }
    }
}

private enum RivetDeviceSessionMessageType: UInt8 {
    case authenticate = 1
    case authChallenge = 2
    case authProof = 3
    case pairStart = 4
    case pairChallenge = 5
    case pairDecision = 6
    case accept = 7
    case paired = 8
    case reject = 9
}

private let sessionMagic = Data([0x52, 0x56, 0x44, 0x31]) // RVD1

public func encodeRivetDeviceSessionRecord(
    _ message: RivetDeviceSessionMessage
) throws -> Data {
    let type = messageType(for: message)
    let payload: Data
    do {
        payload = try encodeRivetValue(try payloadValue(for: message))
    } catch let error as RivetDeviceSessionProtocolError {
        throw error
    } catch {
        throw RivetDeviceSessionProtocolError.malformedPayload
    }
    guard payload.count <= rivetDeviceSessionMaximumPayloadSize else {
        throw RivetDeviceSessionProtocolError.recordTooLarge
    }

    var record = Data()
    record.append(sessionMagic)
    record.append(rivetDeviceSessionVersion)
    record.append(type.rawValue)
    var length = UInt16(payload.count).littleEndian
    withUnsafeBytes(of: &length) { record.append(contentsOf: $0) }
    record.append(payload)
    return record
}

public func decodeRivetDeviceSessionRecord(
    _ record: Data
) throws -> RivetDeviceSessionMessage {
    guard record.count >= 8 else {
        throw RivetDeviceSessionProtocolError.truncated
    }
    guard record.prefix(4) == sessionMagic else {
        throw RivetDeviceSessionProtocolError.invalidMagic
    }
    let start = record.startIndex
    let version = record[record.index(start, offsetBy: 4)]
    guard version == rivetDeviceSessionVersion else {
        throw RivetDeviceSessionProtocolError.unsupportedVersion(version)
    }
    let rawType = record[record.index(start, offsetBy: 5)]
    guard let type = RivetDeviceSessionMessageType(rawValue: rawType) else {
        throw RivetDeviceSessionProtocolError.unknownMessageType(rawType)
    }
    let lowLength = record[record.index(start, offsetBy: 6)]
    let highLength = record[record.index(start, offsetBy: 7)]
    let payloadLength = Int(lowLength) | (Int(highLength) << 8)
    guard payloadLength <= rivetDeviceSessionMaximumPayloadSize else {
        throw RivetDeviceSessionProtocolError.recordTooLarge
    }
    let expectedLength = 8 + payloadLength
    guard record.count >= expectedLength else {
        throw RivetDeviceSessionProtocolError.truncated
    }
    guard record.count == expectedLength else {
        throw RivetDeviceSessionProtocolError.malformedPayload
    }

    let value: RivetValue
    do {
        let payloadStart = record.index(start, offsetBy: 8)
        let payloadEnd = record.index(start, offsetBy: expectedLength)
        value = try decodeRivetValue(record.subdata(in: payloadStart..<payloadEnd))
    } catch {
        throw RivetDeviceSessionProtocolError.malformedPayload
    }
    return try message(type: type, payload: value)
}

/// Incrementally consumes an ordered byte stream while retaining at most one
/// bounded record. Multiple records may be returned from a coalesced read.
public struct RivetDeviceSessionRecordDecoder: Sendable {
    private var buffer = Data()
    private var expectedRecordLength: Int?
    private var failed = false

    public init() {}

    public mutating func append(_ input: Data) throws -> [RivetDeviceSessionMessage] {
        guard !failed else {
            throw RivetDeviceSessionProtocolError.decoderFailed
        }
        var messages: [RivetDeviceSessionMessage] = []
        var offset = input.startIndex
        do {
            while offset < input.endIndex {
                let targetLength = expectedRecordLength ?? 8
                let needed = targetLength - buffer.count
                let available = input.distance(from: offset, to: input.endIndex)
                let count = min(needed, available)
                let end = input.index(offset, offsetBy: count)
                buffer.append(contentsOf: input[offset..<end])
                offset = end

                if expectedRecordLength == nil, buffer.count == 8 {
                    try validateHeader()
                }
                if let expectedRecordLength,
                   buffer.count == expectedRecordLength {
                    messages.append(try decodeRivetDeviceSessionRecord(buffer))
                    buffer.removeAll(keepingCapacity: true)
                    self.expectedRecordLength = nil
                }
            }
            return messages
        } catch {
            failed = true
            buffer.removeAll(keepingCapacity: false)
            expectedRecordLength = nil
            throw error
        }
    }

    public mutating func finish() throws {
        guard !failed else {
            throw RivetDeviceSessionProtocolError.decoderFailed
        }
        guard buffer.isEmpty else {
            failed = true
            buffer.removeAll(keepingCapacity: false)
            expectedRecordLength = nil
            throw RivetDeviceSessionProtocolError.truncated
        }
    }

    private mutating func validateHeader() throws {
        guard buffer.prefix(4) == sessionMagic else {
            throw RivetDeviceSessionProtocolError.invalidMagic
        }
        let version = buffer[4]
        guard version == rivetDeviceSessionVersion else {
            throw RivetDeviceSessionProtocolError.unsupportedVersion(version)
        }
        let rawType = buffer[5]
        guard RivetDeviceSessionMessageType(rawValue: rawType) != nil else {
            throw RivetDeviceSessionProtocolError.unknownMessageType(rawType)
        }
        let payloadLength = Int(buffer[6]) | (Int(buffer[7]) << 8)
        guard payloadLength <= rivetDeviceSessionMaximumPayloadSize else {
            throw RivetDeviceSessionProtocolError.recordTooLarge
        }
        expectedRecordLength = 8 + payloadLength
    }
}

public enum RivetDeviceSessionAuthentication {
    public static func proof(
        credential: Data,
        applicationID: String,
        serverFingerprint: Data,
        deviceID: UUID,
        clientNonce: Data,
        serverNonce: Data
    ) throws -> Data {
        guard credential.count == rivetDeviceCredentialSize,
              isValidDeviceAPIName(applicationID),
              serverFingerprint.count == rivetDeviceFingerprintSize,
              clientNonce.count == rivetDevicePairingNonceSize,
              serverNonce.count == rivetDevicePairingNonceSize else {
            throw RivetDeviceSessionProtocolError.invalidField
        }
        var transcript = Data("rivet-device-auth-v1".utf8)
        appendLengthPrefixed(Data(applicationID.utf8), to: &transcript)
        appendLengthPrefixed(serverFingerprint, to: &transcript)
        appendLengthPrefixed(uuidBytes(deviceID), to: &transcript)
        appendLengthPrefixed(clientNonce, to: &transcript)
        appendLengthPrefixed(serverNonce, to: &transcript)
        let code = HMAC<SHA256>.authenticationCode(
            for: transcript,
            using: SymmetricKey(data: credential)
        )
        return Data(code)
    }
}

private func messageType(
    for message: RivetDeviceSessionMessage
) -> RivetDeviceSessionMessageType {
    switch message {
    case .authenticate: .authenticate
    case .authChallenge: .authChallenge
    case .authProof: .authProof
    case .pairStart: .pairStart
    case .pairChallenge: .pairChallenge
    case .pairDecision: .pairDecision
    case .accept: .accept
    case .paired: .paired
    case .reject: .reject
    }
}

private func payloadValue(for message: RivetDeviceSessionMessage) throws -> RivetValue {
    switch message {
    case .authenticate(let applicationID, let deviceID, let clientNonce):
        try requireAPIName(applicationID)
        try requireBytes(clientNonce, count: rivetDevicePairingNonceSize)
        return .list([
            .string(applicationID),
            .bytes(uuidBytes(deviceID)),
            .bytes(clientNonce)
        ])
    case .authChallenge(let serverNonce):
        try requireBytes(serverNonce, count: rivetDevicePairingNonceSize)
        return .list([.bytes(serverNonce)])
    case .authProof(let proof):
        try requireBytes(proof, count: rivetDeviceCredentialSize)
        return .list([.bytes(proof)])
    case .pairStart(let applicationID, let windowID, let deviceName, let clientNonce):
        try requireAPIName(applicationID)
        guard isValidDeviceDisplayName(deviceName) else {
            throw RivetDeviceSessionProtocolError.invalidField
        }
        try requireBytes(clientNonce, count: rivetDevicePairingNonceSize)
        return .list([
            .string(applicationID),
            .bytes(uuidBytes(windowID)),
            .string(deviceName),
            .bytes(clientNonce)
        ])
    case .pairChallenge(let attemptID, let serverNonce):
        try requireBytes(serverNonce, count: rivetDevicePairingNonceSize)
        return .list([.bytes(uuidBytes(attemptID)), .bytes(serverNonce)])
    case .pairDecision(let attemptID, let confirmed):
        return .list([.bytes(uuidBytes(attemptID)), .bool(confirmed)])
    case .accept(let sessionID, let scopeNames, let maximumPayload, let maximumPending):
        try requireLimits(maximumPayload: maximumPayload, maximumPending: maximumPending)
        try requireCanonicalScopes(scopeNames)
        return .list([
            .bytes(uuidBytes(sessionID)),
            .list(scopeNames.map(RivetValue.string)),
            .int64(Int64(maximumPayload)),
            .int64(Int64(maximumPending))
        ])
    case .paired(
        let deviceID,
        let credential,
        let sessionID,
        let scopeNames,
        let maximumPayload,
        let maximumPending
    ):
        try requireBytes(credential, count: rivetDeviceCredentialSize)
        try requireLimits(maximumPayload: maximumPayload, maximumPending: maximumPending)
        try requireCanonicalScopes(scopeNames)
        return .list([
            .bytes(uuidBytes(deviceID)),
            .bytes(credential),
            .bytes(uuidBytes(sessionID)),
            .list(scopeNames.map(RivetValue.string)),
            .int64(Int64(maximumPayload)),
            .int64(Int64(maximumPending))
        ])
    case .reject(let code):
        return .list([.string(code.rawValue)])
    }
}

private func message(
    type: RivetDeviceSessionMessageType,
    payload: RivetValue
) throws -> RivetDeviceSessionMessage {
    guard case .list(let fields) = payload else {
        throw RivetDeviceSessionProtocolError.malformedPayload
    }
    switch type {
    case .authenticate:
        guard fields.count == 3,
              case .string(let applicationID) = fields[0],
              case .bytes(let deviceBytes) = fields[1],
              case .bytes(let clientNonce) = fields[2] else {
            throw RivetDeviceSessionProtocolError.malformedPayload
        }
        try requireAPIName(applicationID)
        try requireBytes(clientNonce, count: rivetDevicePairingNonceSize)
        return .authenticate(
            applicationID: applicationID,
            deviceID: try decodeUUID(deviceBytes),
            clientNonce: clientNonce
        )
    case .authChallenge:
        guard fields.count == 1, case .bytes(let serverNonce) = fields[0] else {
            throw RivetDeviceSessionProtocolError.malformedPayload
        }
        try requireBytes(serverNonce, count: rivetDevicePairingNonceSize)
        return .authChallenge(serverNonce: serverNonce)
    case .authProof:
        guard fields.count == 1, case .bytes(let proof) = fields[0] else {
            throw RivetDeviceSessionProtocolError.malformedPayload
        }
        try requireBytes(proof, count: rivetDeviceCredentialSize)
        return .authProof(proof)
    case .pairStart:
        guard fields.count == 4,
              case .string(let applicationID) = fields[0],
              case .bytes(let windowBytes) = fields[1],
              case .string(let deviceName) = fields[2],
              case .bytes(let clientNonce) = fields[3] else {
            throw RivetDeviceSessionProtocolError.malformedPayload
        }
        try requireAPIName(applicationID)
        guard isValidDeviceDisplayName(deviceName) else {
            throw RivetDeviceSessionProtocolError.invalidField
        }
        try requireBytes(clientNonce, count: rivetDevicePairingNonceSize)
        return .pairStart(
            applicationID: applicationID,
            windowID: try decodeUUID(windowBytes),
            deviceName: deviceName,
            clientNonce: clientNonce
        )
    case .pairChallenge:
        guard fields.count == 2,
              case .bytes(let attemptBytes) = fields[0],
              case .bytes(let serverNonce) = fields[1] else {
            throw RivetDeviceSessionProtocolError.malformedPayload
        }
        try requireBytes(serverNonce, count: rivetDevicePairingNonceSize)
        return .pairChallenge(
            attemptID: try decodeUUID(attemptBytes),
            serverNonce: serverNonce
        )
    case .pairDecision:
        guard fields.count == 2,
              case .bytes(let attemptBytes) = fields[0],
              case .bool(let confirmed) = fields[1] else {
            throw RivetDeviceSessionProtocolError.malformedPayload
        }
        return .pairDecision(
            attemptID: try decodeUUID(attemptBytes),
            confirmed: confirmed
        )
    case .accept:
        guard fields.count == 4,
              case .bytes(let sessionBytes) = fields[0] else {
            throw RivetDeviceSessionProtocolError.malformedPayload
        }
        let scopes = try decodeScopes(fields[1])
        let limits = try decodeLimits(payload: fields[2], pending: fields[3])
        return .accept(
            sessionID: try decodeUUID(sessionBytes),
            scopeNames: scopes,
            maximumPayload: limits.payload,
            maximumPending: limits.pending
        )
    case .paired:
        guard fields.count == 6,
              case .bytes(let deviceBytes) = fields[0],
              case .bytes(let credential) = fields[1],
              case .bytes(let sessionBytes) = fields[2] else {
            throw RivetDeviceSessionProtocolError.malformedPayload
        }
        try requireBytes(credential, count: rivetDeviceCredentialSize)
        let scopes = try decodeScopes(fields[3])
        let limits = try decodeLimits(payload: fields[4], pending: fields[5])
        return .paired(
            deviceID: try decodeUUID(deviceBytes),
            credential: credential,
            sessionID: try decodeUUID(sessionBytes),
            scopeNames: scopes,
            maximumPayload: limits.payload,
            maximumPending: limits.pending
        )
    case .reject:
        guard fields.count == 1,
              case .string(let rawCode) = fields[0],
              let code = RivetDeviceSessionRejectCode(rawValue: rawCode) else {
            throw RivetDeviceSessionProtocolError.malformedPayload
        }
        return .reject(code)
    }
}

private func requireAPIName(_ name: String) throws {
    guard isValidDeviceAPIName(name) else {
        throw RivetDeviceSessionProtocolError.invalidField
    }
}

private func requireBytes(_ value: Data, count: Int) throws {
    guard value.count == count else {
        throw RivetDeviceSessionProtocolError.invalidField
    }
}

private func requireLimits(maximumPayload: Int, maximumPending: Int) throws {
    guard maximumPayload > 0,
          maximumPayload <= rivetDeviceDefaultMaximumMessageSize,
          maximumPending > 0,
          maximumPending <= rivetDeviceDefaultMaximumPendingRequests else {
        throw RivetDeviceSessionProtocolError.invalidField
    }
}

private func requireCanonicalScopes(_ scopeNames: [String]) throws {
    guard scopeNames.count <= rivetDeviceSessionMaximumScopeCount,
          Set(scopeNames).count == scopeNames.count,
          scopeNames.allSatisfy(isValidDeviceAPIName),
          scopeNames == scopeNames.sorted(by: utf8Precedes) else {
        throw RivetDeviceSessionProtocolError.invalidField
    }
}

private func decodeScopes(_ value: RivetValue) throws -> [String] {
    guard case .list(let values) = value else {
        throw RivetDeviceSessionProtocolError.malformedPayload
    }
    let names = try values.map { value -> String in
        guard case .string(let name) = value else {
            throw RivetDeviceSessionProtocolError.malformedPayload
        }
        return name
    }
    try requireCanonicalScopes(names)
    return names
}

private func decodeLimits(
    payload: RivetValue,
    pending: RivetValue
) throws -> (payload: Int, pending: Int) {
    guard case .int64(let payloadValue) = payload,
          case .int64(let pendingValue) = pending,
          payloadValue > 0,
          pendingValue > 0,
          payloadValue <= Int64(Int.max),
          pendingValue <= Int64(Int.max) else {
        throw RivetDeviceSessionProtocolError.invalidField
    }
    let limits = (payload: Int(payloadValue), pending: Int(pendingValue))
    try requireLimits(
        maximumPayload: limits.payload,
        maximumPending: limits.pending
    )
    return limits
}

package func utf8Precedes(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
}

package func uuidBytes(_ id: UUID) -> Data {
    var bytes = id.uuid
    return withUnsafeBytes(of: &bytes) { Data($0) }
}

private func decodeUUID(_ data: Data) throws -> UUID {
    guard data.count == 16 else {
        throw RivetDeviceSessionProtocolError.invalidField
    }
    let bytes = Array(data)
    return UUID(uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
    ))
}

private func appendLengthPrefixed(_ value: Data, to output: inout Data) {
    precondition(value.count <= Int(UInt32.max))
    var length = UInt32(value.count).bigEndian
    withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
    output.append(value)
}
