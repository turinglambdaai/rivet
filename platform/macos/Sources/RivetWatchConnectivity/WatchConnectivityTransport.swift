#if canImport(WatchConnectivity)
@preconcurrency import WatchConnectivity
import Foundation
import RivetDevice

public enum RivetWatchConnectivityError: Error, Sendable, CustomStringConvertible {
    case notSupported
    case notReachable
    case emptyReply

    public var description: String {
        switch self {
        case .notSupported: return "WatchConnectivity is not supported on this device"
        case .notReachable: return "the paired WatchConnectivity peer is not reachable"
        case .emptyReply: return "the WatchConnectivity peer returned an invalid empty reply"
        }
    }
}

private final class RivetWatchReply: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((Data) -> Void)?

    init(_ handler: @escaping (Data) -> Void) {
        self.handler = handler
    }

    func send(_ data: Data) {
        lock.lock()
        let handler = self.handler
        self.handler = nil
        lock.unlock()
        handler?(data)
    }
}

public final class RivetWatchConnectivityTransport: NSObject, RivetDeviceTransport, @unchecked Sendable {
    private let session: WCSession
    private let router: RivetDeviceRouter?

    public init(
        session: WCSession = .default,
        router: RivetDeviceRouter? = nil
    ) {
        self.session = session
        self.router = router
        super.init()
        session.delegate = self
    }

    public func activate() throws {
        guard WCSession.isSupported() else {
            throw RivetWatchConnectivityError.notSupported
        }
        session.activate()
    }

    public func send(_ request: Data) async throws -> Data {
        guard WCSession.isSupported() else {
            throw RivetWatchConnectivityError.notSupported
        }
        guard session.isReachable else {
            throw RivetWatchConnectivityError.notReachable
        }
        return try await withCheckedThrowingContinuation { continuation in
            session.sendMessageData(
                request,
                replyHandler: { data in
                    if data.isEmpty {
                        continuation.resume(throwing: RivetWatchConnectivityError.emptyReply)
                    } else {
                        continuation.resume(returning: data)
                    }
                },
                errorHandler: { error in
                    continuation.resume(throwing: error)
                }
            )
        }
    }
}

extension RivetWatchConnectivityTransport: WCSessionDelegate {
    public func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {}

    public func session(
        _ session: WCSession,
        didReceiveMessageData messageData: Data,
        replyHandler: @escaping (Data) -> Void
    ) {
        let reply = RivetWatchReply(replyHandler)
        guard let router else {
            reply.send(Data())
            return
        }
        Task {
            do {
                reply.send(try await router.handle(messageData))
            } catch {
                reply.send(Data())
            }
        }
    }

    #if os(iOS)
    public func sessionDidBecomeInactive(_ session: WCSession) {}

    public func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    #endif
}
#endif
