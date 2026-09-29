import Foundation
import XMPPProtocol

/// Value-only registration intent journal. The caller must persist every returned state
/// before network transmission and serialize access within the owning account/installation.
public struct PushRegistrationJournal: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public private(set) var revision: UInt64
    public private(set) var acknowledgedRevision: UInt64
    public private(set) var pending: XMPPPushRegistrationOperation?

    public init() { revision = 0; acknowledgedRevision = 0; pending = nil }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        revision = try values.decode(UInt64.self, forKey: .revision)
        acknowledgedRevision = try values.decode(UInt64.self, forKey: .acknowledgedRevision)
        pending = try values.decodeIfPresent(XMPPPushRegistrationOperation.self, forKey: .pending)
        guard revision <= XMPPPushRegistrationOperation.maximumRevision, acknowledgedRevision <= revision,
              pending.map({ $0.revision == revision && acknowledgedRevision < revision }) ?? (acknowledgedRevision == revision) else {
            throw XMPPNotificationError.invalidConfiguration
        }
    }

    /// A genuine new APNs callback supersedes even an unacknowledged same-token intent.
    /// The gateway might have committed that intent and subsequently invalidated it.
    @discardableResult public mutating func stageFreshRegistration(deviceToken: String) throws -> XMPPPushRegistrationOperation {
        try stage(action: .register, deviceToken: deviceToken)
    }

    @discardableResult public mutating func stageRevocation() throws -> XMPPPushRegistrationOperation {
        // An interrupted revocation reuses exactly its persisted revision.
        if let pending, pending.action == .revoke { return pending }
        return try stage(action: .revoke, deviceToken: nil)
    }

    private mutating func stage(action: XMPPPushRegistrationAction, deviceToken: String?) throws -> XMPPPushRegistrationOperation {
        guard revision < XMPPPushRegistrationOperation.maximumRevision else { throw XMPPNotificationError.invalidConfiguration }
        let operation = try XMPPPushRegistrationOperation(action: action, revision: revision + 1, deviceToken: deviceToken)
        revision = operation.revision; pending = operation
        return operation
    }

    /// A late reply for a replaced token/enable request cannot clear a newer logout intent.
    @discardableResult public mutating func acknowledge(_ result: XMPPPushRegistrationResult, for operation: XMPPPushRegistrationOperation) -> Bool {
        guard pending == operation, result.revision == operation.revision, result.action == operation.action else { return false }
        acknowledgedRevision = operation.revision; pending = nil
        return true
    }

    /// Settles `operation` without a gateway result: only for a revocation the gateway refused because it holds no such
    /// node for this account (item-not-found or forbidden), so nothing is left to revoke. The revision stays spent.
    @discardableResult public mutating func abandonPending(_ operation: XMPPPushRegistrationOperation) -> Bool {
        guard pending == operation else { return false }
        acknowledgedRevision = operation.revision; pending = nil
        return true
    }

    /// Call only with a status result from the authenticated configured component. This
    /// preserves the current local intent after reinstall/conflict; persist before retrying.
    @discardableResult public mutating func rebasePending(after result: XMPPPushRegistrationResult) throws -> XMPPPushRegistrationOperation? {
        guard let desired = pending else { return nil }
        guard result.revision >= desired.revision else { return desired }
        guard result.revision < XMPPPushRegistrationOperation.maximumRevision else { throw XMPPNotificationError.invalidConfiguration }
        let operation = try XMPPPushRegistrationOperation(action: desired.action, revision: result.revision + 1, deviceToken: desired.deviceToken)
        revision = operation.revision; pending = operation
        return operation
    }

    public var description: String { "PushRegistrationJournal(revision: \(revision), pending: \(pending != nil), credentials: redacted)" }
    public var debugDescription: String { description }
}
