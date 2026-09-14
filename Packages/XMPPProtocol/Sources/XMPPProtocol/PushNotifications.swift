import Foundation

/// The node and publish options are opaque gateway credentials, not notification content.
/// Keep them in protected storage. An APNs token need not be exposed to the account's XMPP server.
public struct XMPPPushConfiguration: Sendable, Equatable, Codable, CustomStringConvertible, CustomDebugStringConvertible {
    public let serviceJID: String
    public let node: String
    public let publishOptions: [String: String]

    public init(serviceJID: String, node: String, publishOptions: [String: String] = [:]) throws {
        try PushNotifications.validate(serviceJID: serviceJID, node: node, publishOptions: publishOptions)
        self.serviceJID = serviceJID; self.node = node; self.publishOptions = publishOptions
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(serviceJID: values.decode(String.self, forKey: .serviceJID),
                      node: values.decode(String.self, forKey: .node),
                      publishOptions: values.decode([String: String].self, forKey: .publishOptions))
    }
    public var description: String { "XMPPPushConfiguration(credentials: redacted)" }
    public var debugDescription: String { description }
}

public enum XMPPNotificationError: Error, Sendable, Equatable {
    case invalidConfiguration, pushUnavailable, clientStateUnavailable
}

enum PushNotifications {
    static let namespace = "urn:xmpp:push:0"
    static let clientStateNamespace = "urn:xmpp:csi:0"
    static let formNamespace = "jabber:x:data"
    static let publishOptionsForm = "http://jabber.org/protocol/pubsub#publish-options"

    static func validate(serviceJID: String, node: String, publishOptions: [String: String]) throws {
        let parts = serviceJID.split(separator: "@", omittingEmptySubsequences: false)
        guard !serviceJID.contains("/"), !serviceJID.contains(where: \.isWhitespace),
              serviceJID.utf8.count <= 3071, validText(serviceJID),
              (1...2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty }),
              parts.count == 1 || (parts[0].utf8.count <= 1023 && parts[0].utf8.allSatisfy {
                  (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
              }),
              let domain = parts.last, domain.utf8.count <= 253 else { throw XMPPNotificationError.invalidConfiguration }
        // Gateway registration returns an ASCII DNS/IDNA domain. Full international JID preparation
        // remains a separate stack requirement; never reinterpret a service credential here.
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
            label.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
        }), !node.isEmpty, node.utf8.count <= 1024, validText(node), !node.contains(where: \.isWhitespace),
              publishOptions.count <= 16, publishOptions["FORM_TYPE"] == nil,
              publishOptions.allSatisfy({ key, value in
                  !key.isEmpty && key.utf8.count <= 256 && !key.contains(where: \.isWhitespace) && validText(key) &&
                  value.utf8.count <= 2048 && validText(value) && !value.contains("\r")
              }), publishOptions.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count }) <= 8192 else {
            throw XMPPNotificationError.invalidConfiguration
        }
    }

    static func enableXML(_ configuration: XMPPPushConfiguration) -> String {
        let fields = configuration.publishOptions.keys.sorted().map { key in
            "<field var='\(xmlEscaped(key))'><value>\(xmlEscaped(configuration.publishOptions[key]!))</value></field>"
        }.joined()
        let form = fields.isEmpty ? "" : "<x xmlns='\(formNamespace)' type='submit'><field var='FORM_TYPE' type='hidden'><value>\(publishOptionsForm)</value></field>\(fields)</x>"
        return "<enable xmlns='\(namespace)' jid='\(xmlEscaped(configuration.serviceJID))' node='\(xmlEscaped(configuration.node))'>\(form)</enable>"
    }

    static func disableXML(serviceJID: String, node: String) throws -> String {
        try validate(serviceJID: serviceJID, node: node, publishOptions: [:])
        return "<disable xmlns='\(namespace)' jid='\(xmlEscaped(serviceJID))' node='\(xmlEscaped(node))'/>"
    }

    static func clientStateXML(active: Bool) -> String {
        "<\(active ? "active" : "inactive") xmlns='\(clientStateNamespace)'/>"
    }

    private static func validText(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy {
            $0.value == 9 || $0.value == 10 || $0.value == 13 ||
            (0x20...0xD7FF).contains($0.value) || (0xE000...0xFFFD).contains($0.value) || (0x10000...0x10FFFF).contains($0.value)
        }
    }
}
