import Dispatch
import Foundation
import Testing
@testable import RivetRuntime

private struct ClientHarness {
    let client: RivetClient
    let backendInput: FileHandle   // native client -> fake backend
    let backendOutput: FileHandle  // fake backend -> native client

    func close() {
        client.stop()
        try? backendOutput.close()
        try? backendInput.close()
    }
}

private func readExactly(_ handle: FileHandle, count: Int) throws -> Data {
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

private func readFrame(_ handle: FileHandle) throws -> RivetFrame {
    let header = try readExactly(handle, count: 18)
    let length =
        UInt32(header[14]) |
        (UInt32(header[15]) << 8) |
        (UInt32(header[16]) << 16) |
        (UInt32(header[17]) << 24)
    let payload = try readExactly(handle, count: Int(length))
    var complete = header
    complete.append(payload)
    return try decodeRivetFrame(complete)
}

private func writeFrame(_ frame: RivetFrame, to handle: FileHandle) throws {
    try handle.write(contentsOf: encodeRivetFrame(frame))
}

private func requestName(_ frame: RivetFrame) throws -> String {
    guard frame.type == .request,
          case .list(let fields) = try decodeRivetValue(frame.payload),
          let first = fields.first,
          case .string(let name) = first else {
        throw ClientError.unexpectedMessage(frame.type)
    }
    return name
}

private func makeClientHarness() throws -> ClientHarness {
    let backendToClient = Pipe()
    let clientToBackend = Pipe()

    let helloPayload = try encodeRivetValue(
        .list([.string("rivet"), .int64(Int64(rivetProtocolVersion))])
    )
    try writeFrame(
        RivetFrame(type: .hello, id: 0, payload: helloPayload),
        to: backendToClient.fileHandleForWriting
    )

    let client = RivetClient(
        input: backendToClient.fileHandleForReading,
        output: clientToBackend.fileHandleForWriting
    )
    try client.start()

    return ClientHarness(
        client: client,
        backendInput: clientToBackend.fileHandleForReading,
        backendOutput: backendToClient.fileHandleForWriting
    )
}

@Test func preCancelledCallDoesNotLeakRequest() async throws {
    let harness = try makeClientHarness()
    defer { harness.close() }

    // Hold the task before it enters RivetClient.call so cancellation is
    // definitely already set when request reservation/submission begins.
    let ready = DispatchSemaphore(value: 0)
    let gate = DispatchSemaphore(value: 0)
    let cancelledTask = Task {
        ready.signal()
        gate.wait()
        return try await harness.client.call("cancelled-before-send")
    }
    ready.wait()
    cancelledTask.cancel()
    gate.signal()

    let normalTask = Task {
        try await harness.client.call("normal-after-cancel")
    }

    var request = try readFrame(harness.backendInput)
    var name = try requestName(request)
    if name != "normal-after-cancel" {
        // Keep the test failure-safe: if a regression leaks the cancelled
        // Request, finish it so neither checked continuation remains stranded,
        // then continue to service the expected normal request.
        Issue.record("pre-cancelled call leaked Request \(name)")
        try writeFrame(
            RivetFrame(
                type: .error,
                id: request.id,
                payload: try encodeRivetValue(.string("leaked cancelled request"))
            ),
            to: harness.backendOutput
        )
        request = try readFrame(harness.backendInput)
        name = try requestName(request)
    }

    #expect(request.type == .request)
    #expect(name == "normal-after-cancel")

    try writeFrame(
        RivetFrame(
            type: .response,
            id: request.id,
            payload: try encodeRivetValue(.int64(42))
        ),
        to: harness.backendOutput
    )

    let normalResult = try await normalTask.value
    #expect(normalResult == .int64(42))
    do {
        _ = try await cancelledTask.value
        Issue.record("pre-cancelled Rivet call unexpectedly succeeded")
    } catch {
        #expect(error is CancellationError)
    }
}

@Test func cancellationCannotOvertakeSubmittedRequest() async throws {
    let harness = try makeClientHarness()
    defer { harness.close() }

    let task = Task {
        try await harness.client.call("cancel-after-send")
    }

    let request = try readFrame(harness.backendInput)
    #expect(request.type == .request)
    #expect(try requestName(request) == "cancel-after-send")

    task.cancel()
    let cancel = try readFrame(harness.backendInput)
    #expect(cancel.type == .cancel)
    #expect(cancel.id == request.id)
    #expect(cancel.payload.isEmpty)

    // Match backend cancellation semantics with one terminal Error so the
    // client's checked continuation is released exactly once.
    try writeFrame(
        RivetFrame(
            type: .error,
            id: request.id,
            payload: try encodeRivetValue(.string("request cancelled"))
        ),
        to: harness.backendOutput
    )

    do {
        _ = try await task.value
        Issue.record("cancelled Rivet call unexpectedly succeeded")
    } catch {
        #expect(String(describing: error) == "request cancelled")
    }
}
