import Foundation

/// A `<message type='error'>`: a server returned one of our stanzas (RFC 6120 §8.3). Only the id, the address and the
/// defined condition are read. The payload may echo our own ciphertext and is never parsed; the `<text/>` is written
/// by whoever bounced it and is never shown.
public struct XMPPMessageError: Sendable, Equatable {
    /// The id of the stanza that was returned: ours, when we sent it.
    public let id: String
    /// Who returned it, in normal form: the address we sent to (its server bouncing it), or one of its resources.
    public let from: String
    /// An RFC 6120 §8.3.3 defined condition; `undefined-condition` for anything else.
    public let condition: String
    /// `auth`, `cancel`, `continue`, `modify` or `wait`; nil when missing or unknown.
    public let type: String?
    /// XEP-0191: our own block list refused it (`<blocked xmlns='urn:xmpp:blocking:errors'/>`).
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

    /// Nil unless the stanza is an error message with a valid id and sender and exactly one `<error/>`.
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

    /// The address whose server returned the stanza: `from` when it is a bare JID (a server bouncing for the address we
    /// sent to, or a room). Nil for an error one of a peer's resources wrote, which says nothing about the peer's other
    /// resources, and for a bare domain.
    public var bouncedAddress: String? {
        guard let jid = JID(from), jid.resourcepart == nil, jid.localpart != nil else { return nil }
        return jid.bare
    }

    /// What the store records: the condition, or `blocked` when our own block list refused it.
    public var rejection: String { blockedByUs ? "blocked" : condition }

    /// XEP-0045 §7.2.1 and XEP-0410: a room that answers a message with `not-acceptable` (or `not-allowed`) no longer
    /// counts us as an occupant.
    var meansNotInRoom: Bool { condition == "not-acceptable" || condition == "not-allowed" }
}

/// The XEP-0203 stamp our own server put on a stanza it held for this session: offline storage (`from` = our domain)
/// or a hibernated stream's queue (Prosody's mod_smacks stamps every queued stanza, `from` = our bare JID). Exactly
/// one such delay counts, clamped to now; a delay anyone else added is the sender's claim and is ignored. A peer can
/// still write one naming our server, so `ServerStampWindow` decides when a stamp can be real, and the stamp only
/// places the message in time: it never authenticates anything.
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

/// When a stamp of ours can be real. Our server stamps only what it held while this session was away, and it sends all
/// of that at once: the hibernation queue right after `<resumed/>`, offline storage right after initial presence. So a
/// stamp counts only during that catch-up, which ends at the first message with no delay at all (live traffic), the
/// first answer to one of our own requests (sent after going online, so the server answers it after the catch-up), or
/// `catchUpLimit` after going online, whichever comes first. A delay naming our server on a later message was written
/// by its sender. Within the catch-up a stamp is also no older than `floor`: the previous stream's last contact, less
/// `floorMargin` for clock skew and for stanzas received but not yet acknowledged. Nothing older is still queued.
struct ServerStampWindow {
    static let catchUpLimit: TimeInterval = 60
    static let floorMargin: TimeInterval = 300

    let floor: Date?
    let closesAt: Date

    init(floor: Date?, openedAt: Date = Date()) {
        self.floor = floor; closesAt = openedAt.addingTimeInterval(Self.catchUpLimit)
    }

    /// The earliest stamp a stream resuming `snapshot` (or binding afresh after it) can carry: its last contact, which
    /// `expiresAt` holds plus the server's timeout, less the margin. Nil when unknown: the first session on this device.
    static func floor(after snapshot: XMPPStreamManagementSnapshot?) -> Date? {
        guard let expiresAt = snapshot?.expiresAt, let timeout = snapshot?.resumeTimeoutSeconds else { return nil }
        return expiresAt.addingTimeInterval(-TimeInterval(timeout) - floorMargin)
    }

    /// Whether `stanza` (as it reached us: a carbon's wrapper, not what it forwards) ends the catch-up.
    func ends(with stanza: XMLNode, now: Date = Date()) -> Bool {
        now >= closesAt || stanza.child("delay", namespace: ServerStamp.namespace) == nil
    }

    /// Our server's stamp on `stanza` when it can be real; nil otherwise.
    func stamp(of stanza: XMLNode, accountBareJID: String, now: Date = Date()) -> Date? {
        guard !ends(with: stanza, now: now), let stamp = ServerStamp.of(stanza, accountBareJID: accountBareJID, now: now),
              floor.map({ stamp >= $0 }) ?? true else { return nil }
        return stamp
    }
}
