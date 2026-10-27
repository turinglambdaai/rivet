import Foundation
import RivetDevice
import RivetRuntime

/// Stable, non-sensitive errors for a Watch request reaching an iPhone
/// without an active authenticated desktop session.
public enum RivetWatchRelayError: Error, Equatable, Sendable, RivetDeviceRemoteError {
    case invalidRPC(String)
    case desktopUnavailable

    public var rivetDeviceErrorCode: String {
        switch self {
        case .invalidRPC: "invalid_watch_rpc"
        case .desktopUnavailable: "desktop_unavailable"
        }
    }

    public var rivetDeviceErrorMessage: String {
        switch self {
        case .invalidRPC: "invalid watch RPC registration"
        case .desktopUnavailable: "no authenticated desktop session"
        }
    }
}

/// A session lease for one *specific* successful RVD1 authentication.
/// connectionID must be a fresh UUID for every connection (not the stable
/// paired-device ID). Rotating this value on reconnect or revocation prevents
/// an in-flight Watch RPC from returning an old session's response.
public struct RivetWatchAuthenticatedDesktopSession: Sendable {
    public let connectionID: UUID
    public let client: any RivetRPCClient

    public init(connectionID: UUID, client: any RivetRPCClient) {
        self.connectionID = connectionID
        self.client = client
    }
}

/// An iPhone-side WatchConnectivity router that forwards only explicitly
/// registered typed Watch actions to a current RVD1-authenticated desktop
/// RVT1 client. A reachable Watch does NOT grant desktop authorization.
///
/// The product must return only its current session lease from activeSession;
/// do not return an in-process backend or a revoked session. Every successful
/// RVD1 connection gets a fresh connectionID. The provider is checked before
/// dispatch and again before delivering an RPC result. The product
/// registers actions before activating WCSession, then passes router to
/// RivetWatchConnectivityTransport(router:).
public actor RivetWatchAuthenticatedRPCRelay {
    public nonisolated let router: RivetDeviceRouter

    private let activeSession: @Sendable () async -> RivetWatchAuthenticatedDesktopSession?

    public init(
        messagePolicy: RivetWatchMessagePolicy = RivetWatchMessagePolicy(),
        activeSession: @escaping @Sendable () async -> RivetWatchAuthenticatedDesktopSession?
    ) {
        router = RivetDeviceRouter(maximumMessageSize: messagePolicy.maximumBytes)
        self.activeSession = activeSession
    }

    /// Register one exact, product-selected backend RPC. The Watch cannot
    /// supply arbitrary RPC names: the RPC name and conversion closures are
    /// captured at registration by the iPhone application. The desktop
    /// gateway independently checks the paired device's RPC grant.
    public func register<Request: RivetDeviceRequest>(
        _ request: Request.Type = Request.self,
        rpc rpcName: String,
        arguments: @escaping @Sendable (Request) throws -> [RivetValue],
        response: @escaping @Sendable (RivetValue) throws -> Request.Response
    ) async throws {
        guard Self.isValidRPCName(rpcName) else {
            throw RivetWatchRelayError.invalidRPC(rpcName)
        }
        let provider = activeSession
        try await router.register(request) { value in
            guard let session = await provider() else {
                throw RivetWatchRelayError.desktopUnavailable
            }
            let values = try arguments(value)
            let result = try await session.client.call(rpcName, arguments: values)
            // A reconnect or revocation may race a successful RPC response.
            // Never return results from an obsolete authenticated session.
            guard let current = await provider(),
                  current.connectionID == session.connectionID else {
                throw RivetWatchRelayError.desktopUnavailable
            }
            return try response(result)
        }
    }

    private static func isValidRPCName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard !bytes.isEmpty, bytes.count <= 128 else { return false }
        return bytes.allSatisfy { b in
            (b >= 65 && b <= 90) || (b >= 97 && b <= 122) ||
                (b >= 48 && b <= 57) || b == 45 || b == 46 || b == 95
        }
    }
}
