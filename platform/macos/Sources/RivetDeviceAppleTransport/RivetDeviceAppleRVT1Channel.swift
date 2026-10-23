import Foundation
import RivetDevice
import RivetRuntime

public protocol RivetDeviceAppleApplicationByteStream: Sendable {
    func sendApplicationBytes(_ data: Data) async throws
    func receiveApplicationBytes(maximumLength: Int) async throws -> Data?
    func close() async
}

extension RivetDeviceAppleConnection: RivetDeviceAppleApplicationByteStream {
    public func close() async { cancel() }
}

public enum RivetDeviceAppleRVT1ChannelError: Error, Equatable, Sendable {
    case closed
    case concurrentRead
    case frameTooLarge(actual: Int, maximum: Int)
}

/// Bounded RVT1 framing over a stream opened only after RVD1 authentication.
public actor RivetDeviceAppleRVT1Channel {
    private static let headerSize = 18
    private let stream: any RivetDeviceAppleApplicationByteStream
    private let maximumPayloadSize: Int
    private var readBuffer = Data()
    private var reading = false
    private var closed = false
    private var writeTail: Task<Void, any Error>?
    private var writeToken: UUID?

    public init(connection: RivetDeviceAppleConnection,
                maximumPayloadSize: Int = rivetDeviceDefaultMaximumMessageSize) {
        precondition(maximumPayloadSize > 0 &&
                     maximumPayloadSize <= rivetDeviceDefaultMaximumMessageSize)
        stream = connection
        self.maximumPayloadSize = maximumPayloadSize
    }

    package init(stream: any RivetDeviceAppleApplicationByteStream,
                 maximumPayloadSize: Int = rivetDeviceDefaultMaximumMessageSize) {
        precondition(maximumPayloadSize > 0 &&
                     maximumPayloadSize <= rivetDeviceDefaultMaximumMessageSize)
        self.stream = stream
        self.maximumPayloadSize = maximumPayloadSize
    }

    public func send(_ frame: RivetFrame) async throws {
        guard !closed else { throw RivetDeviceAppleRVT1ChannelError.closed }
        guard frame.payload.count <= maximumPayloadSize else {
            throw RivetDeviceAppleRVT1ChannelError.frameTooLarge(
                actual: frame.payload.count, maximum: maximumPayloadSize
            )
        }
        let data = try encodeRivetFrame(frame)
        let previous = writeTail
        let token = UUID()
        let stream = self.stream
        let task = Task<Void, any Error> {
            if let previous { try await previous.value }
            try await stream.sendApplicationBytes(data)
        }
        writeTail = task
        writeToken = token
        do {
            try await task.value
            if writeToken == token { writeTail = nil; writeToken = nil }
        } catch {
            if writeToken == token { writeTail = nil; writeToken = nil }
            if !closed {
                closed = true
                await stream.close()
            }
            throw error
        }
    }

    public func receive() async throws -> RivetFrame {
        guard !closed else { throw RivetDeviceAppleRVT1ChannelError.closed }
        guard !reading else { throw RivetDeviceAppleRVT1ChannelError.concurrentRead }
        reading = true
        defer { reading = false }
        do {
            try await fillBuffer(to: Self.headerSize)
            let length = UInt32(readBuffer[14])
                | (UInt32(readBuffer[15]) << 8)
                | (UInt32(readBuffer[16]) << 16)
                | (UInt32(readBuffer[17]) << 24)
            guard length <= UInt32(maximumPayloadSize) else {
                throw RivetDeviceAppleRVT1ChannelError.frameTooLarge(
                    actual: Int(length), maximum: maximumPayloadSize
                )
            }
            let total = Self.headerSize + Int(length)
            try await fillBuffer(to: total)
            let frameData = Data(readBuffer.prefix(total))
            readBuffer = Data(readBuffer.dropFirst(total))
            return try decodeRivetFrame(frameData)
        } catch {
            // Framing and stream errors are terminal. Keeping the channel
            // open would retry the same malformed bytes on the next receive.
            if !closed {
                closed = true
                readBuffer.removeAll(keepingCapacity: false)
                await stream.close()
            }
            throw error
        }
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        await stream.close()
    }

    private func fillBuffer(to count: Int) async throws {
        while readBuffer.count < count {
            guard let chunk = try await stream.receiveApplicationBytes(
                maximumLength: count - readBuffer.count
            ), !chunk.isEmpty else {
                throw RivetDeviceAppleRVT1ChannelError.closed
            }
            readBuffer.append(chunk)
        }
    }
}
