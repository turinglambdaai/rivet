import Dispatch
import Foundation
import Testing
@testable import RivetRuntime

private func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
    if count == 0 { return Data() }
    var result = Data()
    result.reserveCapacity(count)
    while result.count < count {
        guard let chunk = try handle.read(upToCount: count - result.count),
              !chunk.isEmpty else {
            throw ClientError.unexpectedEOF
        }
        result.append(chunk)
    }
    return result
}

private func readFrame(from handle: FileHandle) throws -> RivetFrame {
    let header = try readExactly(18, from: handle)
    let length =
        UInt32(header[14]) |
        (UInt32(header[15]) << 8) |
        (UInt32(header[16]) << 16) |
        (UInt32(header[17]) << 24)
    let payload = try readExactly(Int(length), from: handle)
    var data = header
    data.append(payload)
    return try decodeRivetFrame(data)
}

@Test func droppingStartedClientDoesNotLeakBlockedReader() throws {
    let requests = Pipe()
    let responses = Pipe()
    defer {
        try? requests.fileHandleForReading.close()
        try? requests.fileHandleForWriting.close()
        try? responses.fileHandleForReading.close()
        try? responses.fileHandleForWriting.close()
    }

    let hello = RivetFrame(
        type: .hello,
        id: 0,
        payload: try encodeRivetValue(
            .list([.string("rivet"), .int64(Int64(rivetProtocolVersion))])
        )
    )
    let readyEvent = RivetFrame(
        type: .event,
        id: 1,
        payload: try encodeRivetValue(.list([.string("ready"), .int64(1)]))
    )

    // Queue both frames before start. start() consumes Hello synchronously; the
    // background reader must consume `ready` before the test drops the client.
    // That proves the old long-lived readLoop() method is already active and
    // blocking on its next read instead of letting a not-yet-started weak task
    // produce a false-positive deinit.
    try responses.fileHandleForWriting.write(contentsOf: encodeRivetFrame(hello))
    try responses.fileHandleForWriting.write(contentsOf: encodeRivetFrame(readyEvent))

    let sawReady = DispatchSemaphore(value: 0)
    let sawShutdown = DispatchSemaphore(value: 0)
    let serverDone = DispatchSemaphore(value: 0)
    let requestReader = requests.fileHandleForReading
    let responseWriter = responses.fileHandleForWriting

    DispatchQueue(label: "dev.rivet.tests.lifecycle-server").async {
        defer {
            try? responseWriter.close()
            serverDone.signal()
        }
        guard let frame = try? readFrame(from: requestReader),
              frame.type == .shutdown,
              frame.id == 0 else {
            return
        }
        sawShutdown.signal()
    }

    var client: RivetClient? = RivetClient(
        input: responses.fileHandleForReading,
        output: requests.fileHandleForWriting
    )
    weak var weakClient = client

    try client?.start { name, value in
        if name == "ready", value == .int64(1) {
            sawReady.signal()
        }
    }
    #expect(sawReady.wait(timeout: .now() + .seconds(2)) == .success)

    // No explicit stop: deinit is the cleanup contract under test. The reader
    // is now blocked waiting for another backend frame. It must not strongly
    // retain the client across that blocking read.
    client = nil

    #expect(sawShutdown.wait(timeout: .now() + .seconds(2)) == .success)
    #expect(weakClient == nil)
    #expect(serverDone.wait(timeout: .now() + .seconds(2)) == .success)
}