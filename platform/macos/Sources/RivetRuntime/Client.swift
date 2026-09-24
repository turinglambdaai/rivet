import Foundation

struct RequestIDAllocator {
    private var nextID: UInt64

    init(nextID: UInt64 = 1) {
        self.nextID = nextID == 0 ? 1 : nextID
    }

    mutating func allocate(
        occupiedCount: Int,
        isOccupied: (UInt64) -> Bool
    ) -> UInt64 {
        precondition(occupiedCount >= 0)

        // With N occupied ids, N + 1 distinct non-zero candidates guarantee a
        // free slot. This keeps wraparound bounded by active work rather than
        // scanning the UInt64 domain.
        for attempt in 0...occupiedCount {
            let candidate = nextID
            advance()
            if !isOccupied(candidate) {
                return candidate
            }
            if attempt == occupiedCount {
                break
            }
        }

        preconditionFailure("Rivet request id allocator invariant violated")
    }

    private mutating func advance() {
        nextID = nextID == UInt64.max ? 1 : nextID + 1
    }
}

final class RequestCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var requestID: UInt64?
    private var cancelled = false
    private var requestSent = false
    private var cancelSent = false

    func register(_ id: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        precondition(requestID == nil)
        requestID = id
        return cancelled
    }

    func markRequestSent() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        precondition(requestID != nil)
        requestSent = true
        guard cancelled, !cancelSent else { return nil }
        cancelSent = true
        return requestID
    }

    func cancel() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        guard requestSent, !cancelSent else { return nil }
        cancelSent = true
        return requestID
    }
}

struct ClientLifecycle {
    private enum Phase {
        case created
        case starting
        case running
        case stopped
    }

    private var phase: Phase = .created

    var isRunning: Bool { phase == .running }

    mutating func beginStart() throws {
        guard phase == .created else {
            throw ClientError.alreadyStarted
        }
        phase = .starting
    }

    mutating func finishStart() throws {
        guard phase == .starting else {
            throw ClientError.stopped
        }
        phase = .running
    }

    mutating func failStart() {
        if phase == .starting {
            phase = .stopped
        }
    }

    mutating func stop() -> Bool {
        let wasRunning = phase == .running
        phase = .stopped
        return wasRunning
    }
}

public final class RivetClient: @unchecked Sendable {
    public typealias EventHandler = @Sendable (_ name: String, _ value: RivetValue) -> Void

    private let input: FileHandle
    private let output: FileHandle
    private let stateLock = NSLock()
    private let writeLock = NSLock()
    private let readerQueue = DispatchQueue(label: "dev.rivet.protocol-reader")

    private var requestIDs = RequestIDAllocator()
    private var lifecycle = ClientLifecycle()
    private var pending: [UInt64: CheckedContinuation<RivetValue, Error>] = [:]
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
        do {
            try lifecycle.beginStart()
            stateLock.unlock()
        } catch {
            stateLock.unlock()
            throw error
        }

        do {
            let hello = try readFrame()
            try validateHello(hello)

            stateLock.lock()
            do {
                try lifecycle.finishStart()
                eventHandler = onEvent
                stateLock.unlock()
            } catch {
                stateLock.unlock()
                throw error
            }
        } catch {
            stateLock.lock()
            lifecycle.failStart()
            stateLock.unlock()
            throw error
        }

        readerQueue.async { [weak self] in
            self?.readLoop()
        }
    }

    public func call(_ name: String, arguments: [RivetValue] = []) async throws -> RivetValue {
        let cancellation = RequestCancellationState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let id: UInt64
                do {
                    id = try registerPending(continuation)
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                if cancellation.register(id) || Task.isCancelled {
                    if let continuation = takePending(id) {
                        continuation.resume(throwing: CancellationError())
                    }
                    return
                }

                do {
                    var values: [RivetValue] = [.string(name)]
                    values.append(contentsOf: arguments)
                    try write(
                        RivetFrame(
                            type: .request,
                            id: id,
                            payload: encodeRivetValue(.list(values))
                        )
                    )
                    if let cancelledID = cancellation.markRequestSent() {
                        cancel(cancelledID)
                    }
                } catch {
                    if let continuation = takePending(id) {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            if let id = cancellation.cancel() {
                self.cancel(id)
            }
        }
    }

    public func cancel(_ requestID: UInt64) {
        stateLock.lock()
        let shouldSend = lifecycle.isRunning && pending[requestID] != nil
        stateLock.unlock()
        guard shouldSend else { return }

        do {
            try write(RivetFrame(type: .cancel, id: requestID))
        } catch {
            if let continuation = takePending(requestID) {
                continuation.resume(throwing: error)
            }
        }
    }

    public func stop() {
        stateLock.lock()
        let wasRunning = lifecycle.stop()
        stateLock.unlock()

        if wasRunning {
            try? write(RivetFrame(type: .shutdown, id: 0))
        }
        failAll(ClientError.stopped)
    }

    private func registerPending(
        _ continuation: CheckedContinuation<RivetValue, Error>
    ) throws -> UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard lifecycle.isRunning else { throw ClientError.notRunning }

        var allocator = requestIDs
        let id = allocator.allocate(occupiedCount: pending.count) { candidate in
            pending[candidate] != nil
        }
        requestIDs = allocator
        precondition(pending[id] == nil)
        pending[id] = continuation
        return id
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
        return lifecycle.isRunning
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
        stateLock.unlock()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }

    private func finishWithError(_ error: Error) {
        stateLock.lock()
        _ = lifecycle.stop()
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
