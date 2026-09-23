import Foundation

public final class RivetClient: @unchecked Sendable {
    public typealias EventHandler = @Sendable (_ name: String, _ value: RivetValue) -> Void

    private let input: FileHandle
    private let output: FileHandle
    private let stateLock = NSLock()
    private let writeLock = NSLock()
    private let readerQueue = DispatchQueue(label: "dev.rivet.protocol-reader")

    private var nextID: UInt64 = 1
    private var running = false
    private var pending: [UInt64: CheckedContinuation<RivetValue, Error>] = [:]
    // Request IDs are reserved before the cancellation handler is installed.
    // This closes the old window where cancellation could observe no pending
    // continuation and then the operation could still register/send a Request.
    private var registering: Set<UInt64> = []
    private var cancelledBeforeSend: Set<UInt64> = []
    private var eventHandler: EventHandler?

    public init(input: FileHandle, output: FileHandle) {
        self.input = input
        self.output = output
    }

    deinit {
        stop()
    }

    public func start(onEvent: EventHandler? = nil) throws {
        stateLock.lock()
        guard !running else {
            stateLock.unlock()
            throw ClientError.alreadyStarted
        }
        stateLock.unlock()

        let hello = try readFrame()
        try validateHello(hello)

        stateLock.lock()
        eventHandler = onEvent
        running = true
        stateLock.unlock()

        readerQueue.async { [weak self] in
            self?.readLoop()
        }
    }

    public func call(_ name: String, arguments: [RivetValue] = []) async throws -> RivetValue {
        let id = try reserveRequestID()
        return try await withTaskCancellationHandler {
            // Do not rely only on cancellation-handler scheduling for tasks
            // that were already cancelled before entering call(). Releasing
            // the reservation here guarantees a pre-cancelled call performs no
            // request encoding or transport write.
            if Task.isCancelled {
                releaseRequestReservation(id)
                throw CancellationError()
            }

            let requestData: Data
            do {
                var values: [RivetValue] = [.string(name)]
                values.append(contentsOf: arguments)
                requestData = try encodeRivetFrame(
                    RivetFrame(
                        type: .request,
                        id: id,
                        payload: encodeRivetValue(.list(values))
                    )
                )
            } catch {
                releaseRequestReservation(id)
                throw error
            }

            return try await withCheckedThrowingContinuation { continuation in
                submitReservedRequest(id, data: requestData, continuation: continuation)
            }
        } onCancel: {
            self.cancel(id)
        }
    }

    public func cancel(_ requestID: UInt64) {
        // Serialize Request/Cancel writes with the same lock. If Request
        // submission already owns writeLock, cancellation cannot overtake it.
        writeLock.lock()
        stateLock.lock()

        guard running else {
            stateLock.unlock()
            writeLock.unlock()
            return
        }

        if registering.contains(requestID) {
            cancelledBeforeSend.insert(requestID)
            stateLock.unlock()
            writeLock.unlock()
            return
        }

        let shouldSend = pending[requestID] != nil
        stateLock.unlock()

        guard shouldSend else {
            writeLock.unlock()
            return
        }

        do {
            let data = try encodeRivetFrame(RivetFrame(type: .cancel, id: requestID))
            try output.write(contentsOf: data)
            writeLock.unlock()
        } catch {
            writeLock.unlock()
            if let continuation = takePending(requestID) {
                continuation.resume(throwing: error)
            }
        }
    }

    public func stop() {
        stateLock.lock()
        let wasRunning = running
        running = false
        stateLock.unlock()

        if wasRunning {
            try? write(RivetFrame(type: .shutdown, id: 0))
        }
        failAll(ClientError.stopped)
    }

    private func reserveRequestID() throws -> UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard running else { throw ClientError.notRunning }

        // There cannot be 2^64 simultaneously resident entries in practice,
        // so scanning on wrap is sufficient without adding a new public error
        // case. Skip any ID that is still pending or only reserved for a call
        // whose continuation has not been installed yet.
        while true {
            let id = nextID
            nextID &+= 1
            if nextID == 0 { nextID = 1 }
            guard id != 0 else { continue }
            if pending[id] == nil && !registering.contains(id) {
                registering.insert(id)
                return id
            }
        }
    }

    private func releaseRequestReservation(_ id: UInt64) {
        stateLock.lock()
        registering.remove(id)
        cancelledBeforeSend.remove(id)
        stateLock.unlock()
    }

    private func submitReservedRequest(
        _ id: UInt64,
        data: Data,
        continuation: CheckedContinuation<RivetValue, Error>
    ) {
        // Request submission and cancellation use the same lock order. Holding
        // writeLock through registration and the actual write creates one
        // atomic ordering point: either cancellation wins before registration
        // and suppresses the Request, or Request bytes are fully written before
        // a Cancel for the same ID can be emitted.
        writeLock.lock()
        stateLock.lock()

        guard running else {
            registering.remove(id)
            cancelledBeforeSend.remove(id)
            stateLock.unlock()
            writeLock.unlock()
            continuation.resume(throwing: ClientError.notRunning)
            return
        }

        if cancelledBeforeSend.remove(id) != nil {
            registering.remove(id)
            stateLock.unlock()
            writeLock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }

        guard registering.remove(id) != nil else {
            stateLock.unlock()
            writeLock.unlock()
            continuation.resume(throwing: ClientError.notRunning)
            return
        }

        pending[id] = continuation
        stateLock.unlock()

        do {
            try output.write(contentsOf: data)
            writeLock.unlock()
        } catch {
            writeLock.unlock()
            if let continuation = takePending(id) {
                continuation.resume(throwing: error)
            }
        }
    }

    private func write(_ frame: RivetFrame) throws {
        let data = try encodeRivetFrame(frame)
        writeLock.lock()
        defer { writeLock.unlock() }
        try output.write(contentsOf: data)
    }

    private func readFrame() throws -> RivetFrame {
        let header = try readExactly(18)
        let length =
            UInt32(header[14]) |
            (UInt32(header[15]) << 8) |
            (UInt32(header[16]) << 16) |
            (UInt32(header[17]) << 24)
        guard Int(length) <= rivetMaxFramePayloadSize else {
            throw RivetProtocolError.lengthOverflow
        }
        let payload = try readExactly(Int(length))
        var complete = header
        complete.append(payload)
        return try decodeRivetFrame(complete)
    }

    private func readExactly(_ count: Int) throws -> Data {
        if count == 0 { return Data() }
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            guard let chunk = try input.read(upToCount: count - result.count),
                  !chunk.isEmpty else {
                throw ClientError.unexpectedEOF
            }
            result.append(chunk)
        }
        return result
    }

    private func validateHello(_ frame: RivetFrame) throws {
        guard frame.type == .hello, frame.id == 0 else {
            throw ClientError.invalidHello
        }
        guard case .list(let fields) = try decodeRivetValue(frame.payload),
              fields.count == 2,
              fields[0] == .string("rivet"),
              fields[1] == .int64(Int64(rivetProtocolVersion)) else {
            throw ClientError.invalidHello
        }
    }

    private func readLoop() {
        do {
            while isRunning {
                let frame = try readFrame()
                switch frame.type {
                case .response:
                    let value = try decodeRivetValue(frame.payload)
                    takePending(frame.id)?.resume(returning: value)
                case .error:
                    let value = try decodeRivetValue(frame.payload)
                    let message: String
                    if case .string(let text) = value {
                        message = text
                    } else {
                        message = "Rivet backend error"
                    }
                    takePending(frame.id)?.resume(throwing: ClientError.backend(message))
                case .event:
                    deliverEvent(frame)
                case .hello:
                    finishWithError(ClientError.duplicateHello)
                    return
                default:
                    finishWithError(ClientError.unexpectedMessage(frame.type))
                    return
                }
            }
        } catch {
            finishWithError(error)
        }
    }

    private func deliverEvent(_ frame: RivetFrame) {
        guard let value = try? decodeRivetValue(frame.payload),
              case .list(let fields) = value,
              fields.count == 2,
              case .string(let name) = fields[0] else {
            return
        }

        stateLock.lock()
        let handler = eventHandler
        stateLock.unlock()
        handler?(name, fields[1])
    }

    private var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    private func takePending(_ id: UInt64) -> CheckedContinuation<RivetValue, Error>? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return pending.removeValue(forKey: id)
    }

    private func failAll(_ error: Error) {
        stateLock.lock()
        let continuations = Array(pending.values)
        pending.removeAll()
        registering.removeAll()
        cancelledBeforeSend.removeAll()
        stateLock.unlock()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }

    private func finishWithError(_ error: Error) {
        stateLock.lock()
        running = false
        stateLock.unlock()
        failAll(error)
    }
}

public enum ClientError: Error, CustomStringConvertible {
    case alreadyStarted
    case notRunning
    case stopped
    case unexpectedEOF
    case invalidHello
    case duplicateHello
    case unexpectedMessage(RivetMessageType)
    case backend(String)

    public var description: String {
        switch self {
        case .alreadyStarted: return "Rivet client has already been started"
        case .notRunning: return "Rivet client is not running"
        case .stopped: return "Rivet client stopped"
        case .unexpectedEOF: return "Rivet transport closed unexpectedly"
        case .invalidHello: return "invalid Rivet Hello handshake"
        case .duplicateHello: return "duplicate Rivet Hello frame"
        case .unexpectedMessage(let type): return "unexpected Rivet message: \(type)"
        case .backend(let message): return message
        }
    }
}
