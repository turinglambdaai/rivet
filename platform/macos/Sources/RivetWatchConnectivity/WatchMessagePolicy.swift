import Foundation
import RivetDevice

/// An untrusted, bounded WatchConnectivity envelope. The paired iPhone must
/// authorize each registered route and the authenticated desktop session.
public struct RivetWatchMessagePolicy: Sendable {
    public let maximumBytes: Int

    public init(maximumBytes: Int = rivetDeviceDefaultMaximumMessageSize) {
        precondition(maximumBytes > 0 && maximumBytes <= rivetDeviceDefaultMaximumMessageSize)
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
