import Foundation
import RivetDevice

/// A conservative foreground WatchConnectivity message budget. Large
/// background transfers belong to WCSession file transfer, not sendMessageData.
public let rivetWatchConnectivityDefaultMaximumMessageSize = 64 * 1024

/// An untrusted, bounded WatchConnectivity envelope. The paired iPhone must
/// authorize each registered route and the authenticated desktop session.
public struct RivetWatchMessagePolicy: Sendable {
    public let maximumBytes: Int

    public init(maximumBytes: Int = rivetWatchConnectivityDefaultMaximumMessageSize) {
        precondition(
            maximumBytes > 0 &&
                maximumBytes <= rivetWatchConnectivityDefaultMaximumMessageSize &&
                maximumBytes <= rivetDeviceDefaultMaximumMessageSize
        )
        self.maximumBytes = maximumBytes
    }

    public func validate(_ message: Data) throws {
        guard !message.isEmpty else {
            throw RivetWatchMessagePolicyError.emptyMessage
        }
        guard message.count <= maximumBytes else {
            throw RivetWatchMessagePolicyError.messageTooLarge(
                actual: message.count, maximum: maximumBytes
            )
        }
    }
}

public enum RivetWatchMessagePolicyError: Error, Equatable, Sendable {
    case emptyMessage
    case messageTooLarge(actual: Int, maximum: Int)
}


/// Reachability of the paired iPhone for immediate WatchConnectivity messages.
/// File/background transfer is a separate API and is not implied by this state.
public enum RivetWatchConnectivityState: Equatable, Sendable {
    case unsupported
    case inactive
    case reachable
    case notReachable
    case failed

    public var title: String {
        switch self {
        case .unsupported: "WatchConnectivity is unavailable"
        case .inactive: "Waiting for the paired iPhone"
        case .reachable: "iPhone reachable"
        case .notReachable: "Open the iPhone app to connect"
        case .failed: "WatchConnectivity activation failed"
        }
    }
}


/// The immediate watch-to-phone relay must not leave an RPC suspended when
/// WatchConnectivity drops a reply callback during a network transition.
public enum RivetWatchConnectivityError: Error, Equatable, Sendable, CustomStringConvertible {
    case notSupported
    case notReachable
    case notActivated
    case emptyReply
    case requestTimedOut

    public var description: String {
        switch self {
        case .notSupported: "WatchConnectivity is not supported on this device"
        case .notReachable: "the paired WatchConnectivity peer is not reachable"
        case .notActivated: "the paired WatchConnectivity session is not activated"
        case .emptyReply: "the WatchConnectivity peer returned an invalid empty reply"
        case .requestTimedOut: "the paired WatchConnectivity peer did not reply before the deadline"
        }
    }
}

/// Once-only completion for callbacks that may arrive after task cancellation
/// or a deadline. Pre-install cancellation is saved and immediately delivered
/// when the checked continuation becomes available.
final class RivetWatchPendingReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var completed: Result<Data, Error>?
    private var timeoutTask: Task<Void, Never>?

    @discardableResult
    func install(_ next: CheckedContinuation<Data, Error>) -> Bool {
        lock.lock()
        if let completed {
            lock.unlock()
            next.resume(with: completed)
            return false
        }
        precondition(continuation == nil, "a pending reply has only one waiter")
        continuation = next
        lock.unlock()
        return true
    }

    func complete(_ result: Result<Data, Error>) {
        lock.lock()
        guard completed == nil else {
            lock.unlock()
            return
        }
        completed = result
        let waiter = continuation
        continuation = nil
        let timer = timeoutTask
        timeoutTask = nil
        lock.unlock()
        timer?.cancel()
        waiter?.resume(with: result)
    }

    func armTimeout(nanoseconds: UInt64) {
        let timer = Task.detached { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            self?.complete(.failure(RivetWatchConnectivityError.requestTimedOut))
        }
        lock.lock()
        if completed != nil {
            lock.unlock()
            timer.cancel()
            return
        }
        precondition(timeoutTask == nil, "a pending reply has only one deadline")
        timeoutTask = timer
        lock.unlock()
    }
}


/// iPhone-side one-shot reply gate. A slow or non-cooperative product router
/// cannot leave WatchConnectivity waiting indefinitely for its reply handler.
final class RivetWatchReply: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((Data) -> Void)?
    private var timeoutTask: Task<Void, Never>?

    init(_ handler: @escaping (Data) -> Void) {
        self.handler = handler
    }

    func send(_ data: Data) {
        lock.lock()
        let completion = handler
        handler = nil
        let timer = timeoutTask
        timeoutTask = nil
        lock.unlock()
        timer?.cancel()
        completion?(data)
    }

    func armTimeout(nanoseconds: UInt64, onTimeout: @escaping @Sendable () -> Void) {
        let timer = Task.detached { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            onTimeout()
            self?.send(Data())
        }
        lock.lock()
        guard handler != nil else {
            lock.unlock()
            timer.cancel()
            return
        }
        precondition(timeoutTask == nil, "one reply has only one deadline")
        timeoutTask = timer
        lock.unlock()
    }
}
