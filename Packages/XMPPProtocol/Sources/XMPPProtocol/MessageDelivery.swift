import Foundation

/// A bounced `<message type='error'>` (RFC 6120 §8.3). Only the id, address and defined condition are read: the
/// payload may echo our ciphertext and is never parsed, and the bouncer's `<text/>` is never shown.
public struct XMPPMessageError: Sendable, Equatable {
    public let id: String
    /// Normal form: the address we sent to (its server bouncing it), or one of its resources.
    public let from: String
    /// An RFC 6120 §8.3.3 defined condition; `undefined-condition` for anything else.
    public let condition: String
    /// nil when missing or unknown.
    public let type: String?
    /// XEP-0191: our own block list refused it.
    public let blockedByUs: Bool

    public init(id: String, from: String, condition: String, type: String? = nil, blockedByUs: Bool = false) {
        self.id = id; self.from = from; self.condition = condition; self.type = type; self.blockedByUs = blockedByUs
    }

    /// RFC 6120 §8.3.3.
    public static let conditions: Set<String> = [
        "bad-request", "conflict", "feature-not-implemented", "forbidden", "gone", "internal-server-error", "item-not-found",
        "jid-malformed", "not-acceptable", "not-allowed", "not-authorized", "policy-violation", "recipient-unavailable",
        "redirect", "registration-required", "remote-server-not-found", "remote-server-timeout", "resource-constraint",
        "service-unavailable", "subscription-required", "undefined-condition", "unexpected-request"
    ]
    static let stanzasNamespace = "urn:ietf:params:xml:ns:xmpp-stanzas"
    static let blockingErrorsNamespace = "urn:xmpp:blocking:errors"

    // nil unless an error message with a valid id and sender and exactly one `<error/>`.
    static func parse(_ node: XMLNode) -> XMPPMessageError? {
        guard node.name == "message", node.namespace == "jabber:client", node.attributes["type"] == "error",
              let id = node.attributes["id"], OMEMOWire.validStanzaID(id),
              let from = node.attributes["from"], JID.normalized(from) == from else { return nil }
        let errors = node.children("error", namespace: "jabber:client")
        guard errors.count == 1 else { return nil }
        let error = errors[0]
        let named = error.children.first { $0.namespace == stanzasNamespace && $0.name != "text" }?.name
        let type = error.attributes["type"].flatMap { ["auth", "cancel", "continue", "modify", "wait"].contains($0) ? $0 : nil }
        return XMPPMessageError(id: id, from: from, condition: named.flatMap { conditions.contains($0) ? $0 : nil } ?? "undefined-condition",
                                type: type, blockedByUs: error.child("blocked", namespace: blockingErrorsNamespace) != nil)
    }

    /// `from` when it is a bare JID (a server bouncing for the address, or a room). nil for a bare domain, for an error
    /// one of a peer's resources wrote (it says nothing about the others), and for `recipient-unavailable`: RFC 6120
    /// makes it temporary, and Prosody's mod_smacks sends it from the bare JID for each stanza one session lost while
    /// the peer's other sessions may have received it.
    public var bouncedAddress: String? {
        guard condition != "recipient-unavailable", let jid = JID(from), jid.resourcepart == nil, jid.localpart != nil else { return nil }
        return jid.bare
    }

    /// The condition, or `blocked` when our own block list refused it.
    public var rejection: String { blockedByUs ? "blocked" : condition }

    /// XEP-0045 §7.2.1 and XEP-0410: a room that answers with `not-acceptable` or `not-allowed` no longer counts us as
    /// an occupant.
    public var meansNotInRoom: Bool { condition == "not-acceptable" || condition == "not-allowed" }
}

// XEP-0203 delay from our own server on a stanza it held (offline storage, or mod_smacks' hibernation queue). Exactly
// one counts, clamped to now; others are the sender's claim. A peer can forge one, so `ServerStampWindow` gates it
// and it only places the message in time, never authenticates.
enum ServerStamp {
    static let namespace = "urn:xmpp:delay"

    static func of(_ node: XMLNode, accountBareJID: String, now: Date = Date()) -> Date? {
        guard let domain = JID(accountBareJID)?.domainpart else { return nil }
        let ours = node.children("delay", namespace: namespace).filter { delay in
            guard let from = delay.attributes["from"], let jid = JID(from), jid.resourcepart == nil else { return false }
            return jid.bare == accountBareJID || jid.bare == domain
        }
        guard ours.count == 1, let stamp = ours[0].attributes["stamp"], let date = ArchiveQuery.timestamp(stamp) else { return nil }
        return min(date, now)
    }
}

// Our server stamps only what it held while we were away and sends it all at once after `<resumed/>` or initial
// presence. A stamp counts until the first undelayed message, the first answer to our own request or `catchUpLimit`,
// and is no older than `floor`: the previous stream's last contact less `floorMargin` (skew, unacknowledged stanzas).
struct ServerStampWindow {
    static let catchUpLimit: TimeInterval = 60
    static let floorMargin: TimeInterval = 300

    let floor: Date?
    let closesAt: Date

    init(floor: Date?, openedAt: Date = Date()) {
        self.floor = floor; closesAt = openedAt.addingTimeInterval(Self.catchUpLimit)
    }

    // `expiresAt` minus the server's timeout, less the margin; nil on the first session on this device.
    static func floor(after snapshot: XMPPStreamManagementSnapshot?) -> Date? {
        guard let expiresAt = snapshot?.expiresAt, let timeout = snapshot?.resumeTimeoutSeconds else { return nil }
        return expiresAt.addingTimeInterval(-TimeInterval(timeout) - floorMargin)
    }

    // `stanza` as it reached us: a carbon's wrapper, not what it forwards.
    func ends(with stanza: XMLNode, now: Date = Date()) -> Bool {
        now >= closesAt || stanza.child("delay", namespace: ServerStamp.namespace) == nil
    }

    func stamp(of stanza: XMLNode, accountBareJID: String, now: Date = Date()) -> Date? {
        guard !ends(with: stanza, now: now), let stamp = ServerStamp.of(stanza, accountBareJID: accountBareJID, now: now),
              floor.map({ stamp >= $0 }) ?? true else { return nil }
        return stamp
    }
}
