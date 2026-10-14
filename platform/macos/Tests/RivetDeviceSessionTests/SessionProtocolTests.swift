import Foundation
import RivetDevice
import RivetRuntime
import Testing
@testable import RivetDeviceSession

private let sessionApplicationID = "com.example.app"
private let sessionDeviceID = UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!
private let sessionWindowID = UUID(uuidString: "10213243-5465-7687-98a9-bacbdcedfe0f")!
private let sessionAttemptID = UUID(uuidString: "ffeeddcc-bbaa-9988-7766-554433221100")!
private let sessionID = UUID(uuidString: "01234567-89ab-cdef-0123-456789abcdef")!
private let sessionClientNonce = Data(repeating: 0x11, count: rivetDevicePairingNonceSize)
private let sessionServerNonce = Data(repeating: 0x22, count: rivetDevicePairingNonceSize)
private let sessionCredential = Data(repeating: 0x33, count: rivetDeviceCredentialSize)
private let sessionProof = Data(repeating: 0x44, count: rivetDeviceCredentialSize)

private let allSessionMessages: [RivetDeviceSessionMessage] = [
    .authenticate(
        applicationID: sessionApplicationID,
        deviceID: sessionDeviceID,
        clientNonce: sessionClientNonce
    ),
    .authChallenge(serverNonce: sessionServerNonce),
    .authProof(sessionProof),
    .pairStart(
        applicationID: sessionApplicationID,
        windowID: sessionWindowID,
        deviceName: "Test Phone",
        clientNonce: sessionClientNonce
    ),
    .pairChallenge(attemptID: sessionAttemptID, serverNonce: sessionServerNonce),
    .pairDecision(attemptID: sessionAttemptID, confirmed: true),
    .accept(
        sessionID: sessionID,
        scopeNames: ["controller", "reader"],
        maximumPayload: rivetDeviceDefaultMaximumMessageSize,
        maximumPending: rivetDeviceDefaultMaximumPendingRequests
    ),
    .paired(
        deviceID: sessionDeviceID,
        credential: sessionCredential,
        sessionID: sessionID,
        scopeNames: ["controller", "reader"],
        maximumPayload: rivetDeviceDefaultMaximumMessageSize,
        maximumPending: rivetDeviceDefaultMaximumPendingRequests
    ),
    .reject(.authenticationFailed)
]

private struct DeviceSessionGoldenRecord {
    let kind: String
    let name: String
    let value: String
}

private func loadDeviceSessionGoldenRecords() throws -> [DeviceSessionGoldenRecord] {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 {
        url.deleteLastPathComponent()
    }
    url.appendPathComponent("rivet/tests/device-session-golden.txt")
    let contents = try String(contentsOf: url, encoding: .utf8)
    return try contents.split(whereSeparator: \.isNewline).compactMap { rawLine in
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("#") else {
            return nil
        }
        let parts = line.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3 else {
            throw RivetDeviceSessionProtocolError.malformedPayload
        }
        return DeviceSessionGoldenRecord(
            kind: String(parts[0]),
            name: String(parts[1]),
            value: String(parts[2])
        )
    }
}

private func sessionHexData(_ text: String) throws -> Data {
    guard text.count.isMultiple(of: 2) else {
        throw RivetDeviceSessionProtocolError.malformedPayload
    }
    var result = Data()
    var index = text.startIndex
    while index < text.endIndex {
        let next = text.index(index, offsetBy: 2)
        guard let byte = UInt8(text[index..<next], radix: 16) else {
            throw RivetDeviceSessionProtocolError.malformedPayload
        }
        result.append(byte)
        index = next
    }
    return result
}

private func rawSessionRecord(type: UInt8, payload: RivetValue) throws -> Data {
    let encodedPayload = try encodeRivetValue(payload)
    precondition(encodedPayload.count <= rivetDeviceSessionMaximumPayloadSize)
    var record = Data([0x52, 0x56, 0x44, 0x31, 1, type])
    var length = UInt16(encodedPayload.count).littleEndian
    withUnsafeBytes(of: &length) { record.append(contentsOf: $0) }
    record.append(encodedPayload)
    return record
}

@Test func sharedDeviceSessionGoldenVectors() throws {
    let records = try loadDeviceSessionGoldenRecords()
    let messageRecords = records.filter { $0.kind == "record" }
    #expect(messageRecords.map(\.name) == [
        "authenticate",
        "auth-challenge",
        "auth-proof-record",
        "pair-start",
        "pair-challenge",
        "pair-decision",
        "accept",
        "paired",
        "reject"
    ])
    #expect(messageRecords.count == allSessionMessages.count)
    for (record, message) in zip(messageRecords, allSessionMessages) {
        let bytes = try sessionHexData(record.value)
        #expect(try encodeRivetDeviceSessionRecord(message) == bytes)
        #expect(try decodeRivetDeviceSessionRecord(bytes) == message)
    }

    let proofRecord = try #require(records.first { $0.kind == "proof" })
    let proof = try RivetDeviceSessionAuthentication.proof(
        credential: sessionCredential,
        applicationID: sessionApplicationID,
        serverFingerprint: Data(repeating: 0x55, count: rivetDeviceFingerprintSize),
        deviceID: sessionDeviceID,
        clientNonce: sessionClientNonce,
        serverNonce: sessionServerNonce
    )
    let expectedProof = try sessionHexData(proofRecord.value)
    #expect(proof == expectedProof)

    let codeRecord = try #require(records.first { $0.kind == "code" })
    let code = try RivetDevicePairingTranscript.verificationCode(
        applicationID: sessionApplicationID,
        serverFingerprint: Data(repeating: 0x55, count: rivetDeviceFingerprintSize),
        clientNonce: sessionClientNonce,
        serverNonce: sessionServerNonce
    )
    #expect(code == codeRecord.value)
}

@Test func deviceSessionRecordsRoundTripEveryMessage() throws {
    for message in allSessionMessages {
        let encoded = try encodeRivetDeviceSessionRecord(message)
        #expect(encoded.count <= rivetDeviceSessionMaximumRecordSize)
        #expect(try decodeRivetDeviceSessionRecord(encoded) == message)

        var padded = Data([0xff])
        padded.append(encoded)
        #expect(try decodeRivetDeviceSessionRecord(padded.dropFirst()) == message)
    }
}

@Test func deviceSessionIncrementalDecoderHandlesFragmentationAndCoalescing() throws {
    let records = try allSessionMessages.map(encodeRivetDeviceSessionRecord)
    let combined = records.reduce(into: Data()) { $0.append($1) }

    var byteDecoder = RivetDeviceSessionRecordDecoder()
    var byteMessages: [RivetDeviceSessionMessage] = []
    for byte in combined {
        byteMessages.append(contentsOf: try byteDecoder.append(Data([byte])))
    }
    try byteDecoder.finish()
    #expect(byteMessages == allSessionMessages)

    var combinedDecoder = RivetDeviceSessionRecordDecoder()
    #expect(try combinedDecoder.append(combined) == allSessionMessages)
    try combinedDecoder.finish()
}

@Test func deviceSessionDecoderFailsClosedOnBadHeadersAndTruncation() throws {
    var badMagic = try encodeRivetDeviceSessionRecord(allSessionMessages[0])
    badMagic[0] = 0
    #expect(throws: RivetDeviceSessionProtocolError.invalidMagic) {
        try decodeRivetDeviceSessionRecord(badMagic)
    }

    var badVersion = try encodeRivetDeviceSessionRecord(allSessionMessages[0])
    badVersion[4] = 2
    #expect(throws: RivetDeviceSessionProtocolError.unsupportedVersion(2)) {
        try decodeRivetDeviceSessionRecord(badVersion)
    }

    var badType = try encodeRivetDeviceSessionRecord(allSessionMessages[0])
    badType[5] = 0xff
    #expect(throws: RivetDeviceSessionProtocolError.unknownMessageType(0xff)) {
        try decodeRivetDeviceSessionRecord(badType)
    }

    var excessiveHeader = Data([0x52, 0x56, 0x44, 0x31, 1, 1])
    let excessiveLength = UInt16(rivetDeviceSessionMaximumPayloadSize + 1)
    excessiveHeader.append(UInt8(excessiveLength & 0xff))
    excessiveHeader.append(UInt8(excessiveLength >> 8))
    var decoder = RivetDeviceSessionRecordDecoder()
    #expect(throws: RivetDeviceSessionProtocolError.recordTooLarge) {
        try decoder.append(excessiveHeader)
    }
    #expect(throws: RivetDeviceSessionProtocolError.decoderFailed) {
        try decoder.append(Data())
    }

    var truncatedDecoder = RivetDeviceSessionRecordDecoder()
    let record = try encodeRivetDeviceSessionRecord(allSessionMessages[0])
    _ = try truncatedDecoder.append(record.dropLast())
    #expect(throws: RivetDeviceSessionProtocolError.truncated) {
        try truncatedDecoder.finish()
    }
}

@Test func deviceSessionRecordLimitAndPayloadShapeAreEnforced() throws {
    let oversizedScopes = (0..<rivetDeviceSessionMaximumScopeCount).map { index in
        String(format: "scope%02d", index) + String(repeating: "x", count: 120)
    }.sorted(by: utf8Precedes)
    #expect(throws: RivetDeviceSessionProtocolError.recordTooLarge) {
        try encodeRivetDeviceSessionRecord(.accept(
            sessionID: sessionID,
            scopeNames: oversizedScopes,
            maximumPayload: rivetDeviceDefaultMaximumMessageSize,
            maximumPending: rivetDeviceDefaultMaximumPendingRequests
        ))
    }

    let maximumPayloadValue = try encodeRivetValue(
        .bytes(Data(repeating: 0, count: rivetDeviceSessionMaximumPayloadSize - 5))
    )
    #expect(maximumPayloadValue.count == rivetDeviceSessionMaximumPayloadSize)
    var maximumRecord = Data([0x52, 0x56, 0x44, 0x31, 1, 3, 0xf8, 0x1f])
    maximumRecord.append(maximumPayloadValue)
    #expect(maximumRecord.count == rivetDeviceSessionMaximumRecordSize)
    #expect(throws: RivetDeviceSessionProtocolError.malformedPayload) {
        try decodeRivetDeviceSessionRecord(maximumRecord)
    }

    let valid = try encodeRivetDeviceSessionRecord(.authProof(sessionProof))
    var trailing = valid
    trailing.append(0)
    trailing[6] = UInt8((valid.count - 8 + 1) & 0xff)
    #expect(throws: RivetDeviceSessionProtocolError.malformedPayload) {
        try decodeRivetDeviceSessionRecord(trailing)
    }

    #expect(throws: RivetDeviceSessionProtocolError.invalidField) {
        try encodeRivetDeviceSessionRecord(.accept(
            sessionID: sessionID,
            scopeNames: ["reader", "controller"],
            maximumPayload: rivetDeviceDefaultMaximumMessageSize,
            maximumPending: rivetDeviceDefaultMaximumPendingRequests
        ))
    }
}

@Test func deviceSessionRejectsMalformedFieldCountsTypesAndSizes() throws {
    let malformedRecords = try [
        rawSessionRecord(type: 1, payload: .list([
            .string(sessionApplicationID),
            .bytes(Data(repeating: 0, count: 16))
        ])),
        rawSessionRecord(type: 1, payload: .list([
            .string(sessionApplicationID),
            .string(sessionDeviceID.uuidString),
            .bytes(sessionClientNonce)
        ])),
        rawSessionRecord(type: 1, payload: .list([
            .string(sessionApplicationID),
            .bytes(Data(repeating: 0, count: 15)),
            .bytes(sessionClientNonce)
        ])),
        rawSessionRecord(type: 2, payload: .list([
            .bytes(Data(repeating: 0, count: rivetDevicePairingNonceSize - 1))
        ])),
        rawSessionRecord(type: 7, payload: .list([
            .bytes(uuidBytes(sessionID)),
            .list([.string("reader"), .string("controller")]),
            .int64(Int64(rivetDeviceDefaultMaximumMessageSize)),
            .int64(Int64(rivetDeviceDefaultMaximumPendingRequests))
        ])),
        rawSessionRecord(type: 9, payload: .list([.string("unknown_code")]))
    ]

    for record in malformedRecords {
        #expect(throws: (any Error).self) {
            try decodeRivetDeviceSessionRecord(record)
        }
    }
}

@Test func deviceSessionAuthenticationProofBindsEveryTranscriptField() throws {
    let fingerprint = Data(repeating: 0x55, count: rivetDeviceFingerprintSize)
    let proof = try RivetDeviceSessionAuthentication.proof(
        credential: sessionCredential,
        applicationID: sessionApplicationID,
        serverFingerprint: fingerprint,
        deviceID: sessionDeviceID,
        clientNonce: sessionClientNonce,
        serverNonce: sessionServerNonce
    )
    #expect(proof.count == rivetDeviceCredentialSize)
    let repeatedProof = try RivetDeviceSessionAuthentication.proof(
        credential: sessionCredential,
        applicationID: sessionApplicationID,
        serverFingerprint: fingerprint,
        deviceID: sessionDeviceID,
        clientNonce: sessionClientNonce,
        serverNonce: sessionServerNonce
    )
    let changedProof = try RivetDeviceSessionAuthentication.proof(
        credential: sessionCredential,
        applicationID: sessionApplicationID,
        serverFingerprint: fingerprint,
        deviceID: sessionDeviceID,
        clientNonce: sessionClientNonce,
        serverNonce: Data(repeating: 0x23, count: rivetDevicePairingNonceSize)
    )
    #expect(proof == repeatedProof)
    #expect(proof != changedProof)
}
