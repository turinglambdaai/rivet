#if canImport(WatchConnectivity)
@preconcurrency import WatchConnectivity
import Foundation
import RivetDevice

public enum RivetWatchConnectivityError: Error, Sendable, CustomStringConvertible {
    case notSupported
    case notReachable
    case notActivated
    case emptyReply

    public var description: String {
        switch self {
        case .notSupported: return "WatchConnectivity is not supported on this device"
        case .notReachable: return "the paired WatchConnectivity peer is not reachable"
        case .notActivated: return "the paired WatchConnectivity session is not activated"
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
    private let messagePolicy: RivetWatchMessagePolicy

    public init(
        session: WCSession = .default,
        router: RivetDeviceRouter? = nil,
        messagePolicy: RivetWatchMessagePolicy = RivetWatchMessagePolicy()
    ) {
        self.session = session
        self.router = router
        self.messagePolicy = messagePolicy
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
        try messagePolicy.validate(request)
        guard WCSession.isSupported() else {
            throw RivetWatchConnectivityError.notSupported
        }
        guard session.activationState == .activated else {
            throw RivetWatchConnectivityError.notActivated
        }
        guard session.isReachable else {
            throw RivetWatchConnectivityError.notReachable
        }
        let policy = messagePolicy
        return try await withCheckedThrowingContinuation { continuation in
            session.sendMessageData(
                request,
                replyHandler: { data in
                    if data.isEmpty {
                        continuation.resume(throwing: RivetWatchConnectivityError.emptyReply)
                    } else {
                        do {
                            try policy.validate(data)
                            continuation.resume(returning: data)
                        } catch {
                            continuation.resume(throwing: error)
                        }
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
        do {
            try messagePolicy.validate(messageData)
        } catch {
            reply.send(Data())
            return
        }
        let policy = messagePolicy
        Task {
            do {
                let data = try await router.handle(messageData)
                try policy.validate(data)
                reply.send(data)
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
