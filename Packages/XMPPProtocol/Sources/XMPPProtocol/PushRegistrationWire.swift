import Foundation

public enum XMPPPushRegistrationAction: String, Codable, Sendable { case register, revoke }

/// The APNs environment the device token belongs to. A development-signed build receives sandbox tokens, an App Store or
/// TestFlight build production tokens; the gateway must send to the matching APNs host.
public enum XMPPPushEnvironment: String, Codable, Sendable { case sandbox, production }

/// Persist before transmission. A revision must never be reused for another operation.
public struct XMPPPushRegistrationOperation: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let maximumRevision: UInt64 = 9_007_199_254_740_991
    public let action: XMPPPushRegistrationAction
    public let revision: UInt64
    public let deviceToken: String?

    public init(action: XMPPPushRegistrationAction, revision: UInt64, deviceToken: String? = nil) throws {
        guard revision > 0, revision <= Self.maximumRevision else { throw XMPPNotificationError.invalidConfiguration }
        switch action {
        case .register:
            guard let deviceToken, !deviceToken.isEmpty, deviceToken.utf8.count <= 1024,
                  deviceToken.utf8.count.isMultiple(of: 2), deviceToken.utf8.allSatisfy({
                      (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
                  }) else { throw XMPPNotificationError.invalidConfiguration }
        case .revoke:
            guard deviceToken == nil else { throw XMPPNotificationError.invalidConfiguration }
        }
        self.action = action; self.revision = revision; self.deviceToken = deviceToken?.lowercased()
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(action: values.decode(XMPPPushRegistrationAction.self, forKey: .action),
                      revision: values.decode(UInt64.self, forKey: .revision),
                      deviceToken: values.decodeIfPresent(String.self, forKey: .deviceToken))
    }
    public var description: String { "XMPPPushRegistrationOperation(\(action.rawValue), revision: \(revision), token: redacted)" }
    public var debugDescription: String { description }
}

/// This acknowledges gateway registration state, never APNs or device delivery.
public struct XMPPPushRegistrationResult: Codable, Sendable, Equatable {
    public let revision: UInt64
    public let action: XMPPPushRegistrationAction
    public init(revision: UInt64, action: XMPPPushRegistrationAction) throws {
        guard revision <= XMPPPushRegistrationOperation.maximumRevision else { throw XMPPNotificationError.invalidConfiguration }
        self.revision = revision; self.action = action
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(revision: values.decode(UInt64.self, forKey: .revision),
                      action: values.decode(XMPPPushRegistrationAction.self, forKey: .action))
    }
}

enum PushRegistrationWire {
    static let namespace = "https://xmpp.haus/push/registration/0"

    static func credentials(_ configuration: XMPPPushConfiguration) throws -> String {
        guard configuration.publishOptions.count == 1, let secret = configuration.publishOptions["secret"],
              [configuration.node, secret].allSatisfy({ value in
                  (32...128).contains(value.utf8.count) && value.utf8.allSatisfy {
                      (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
                  }
              }) else { throw XMPPNotificationError.invalidConfiguration }
        return "node='\(xmlEscaped(configuration.node))' secret='\(xmlEscaped(secret))'"
    }

    /// Only a registration names its environment and APNs topic: they travel with the token they describe. Without a
    /// topic the gateway uses its default one.
    static func operationXML(_ operation: XMPPPushRegistrationOperation, configuration: XMPPPushConfiguration,
                             environment: XMPPPushEnvironment, topic: String? = nil) throws -> String {
        if let topic {
            guard (1...255).contains(topic.utf8.count), topic.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46
            }) else { throw XMPPNotificationError.invalidConfiguration }
        }
        let token = operation.deviceToken.map {
            " token='\($0)' environment='\(environment.rawValue)'" + (topic.map { " topic='\($0)'" } ?? "")
        } ?? ""
        return "<\(operation.action.rawValue) xmlns='\(namespace)' \(try credentials(configuration)) revision='\(operation.revision)'\(token)/>"
    }

    static func statusXML(_ configuration: XMPPPushConfiguration) throws -> String {
        "<status xmlns='\(namespace)' \(try credentials(configuration))/>"
    }

    static func result(_ response: XMLNode) throws -> XMPPPushRegistrationResult {
        guard response.children.count == 1 else { throw XMPPIQError.malformedResponse }
        let value = response.children[0]
        guard value.name == "registration", value.namespace == namespace, value.children.isEmpty,
              value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Set(value.attributes.keys) == ["revision", "action"],
              let revisionText = value.attributes["revision"], (1...16).contains(revisionText.utf8.count),
              revisionText.utf8.allSatisfy({ (48...57).contains($0) }),
              let revision = UInt64(revisionText), revision <= XMPPPushRegistrationOperation.maximumRevision,
              let action = value.attributes["action"].flatMap(XMPPPushRegistrationAction.init(rawValue:)) else {
            throw XMPPIQError.malformedResponse
        }
        return try XMPPPushRegistrationResult(revision: revision, action: action)
    }
}

extension XMPPClient {
    /// A register for a node the gateway does not know creates it, owned by this account's bare JID. `topic` is the
    /// app's APNs topic (its bundle identifier); nil leaves it to the gateway's default.
    public func updatePushRegistration(_ operation: XMPPPushRegistrationOperation, configuration: XMPPPushConfiguration,
                                       environment: XMPPPushEnvironment, topic: String? = nil) async throws -> XMPPPushRegistrationResult {
        let payload = try PushRegistrationWire.operationXML(operation, configuration: configuration, environment: environment, topic: topic)
        let response = try await requestIQ(type: "set", to: configuration.serviceJID, payload: payload)
        let result = try PushRegistrationWire.result(response)
        guard result.revision == operation.revision, result.action == operation.action else { throw XMPPIQError.malformedResponse }
        return result
    }

    public func pushRegistrationStatus(configuration: XMPPPushConfiguration) async throws -> XMPPPushRegistrationResult {
        let payload = try PushRegistrationWire.statusXML(configuration)
        return try PushRegistrationWire.result(await requestIQ(type: "get", to: configuration.serviceJID, payload: payload))
    }
}
