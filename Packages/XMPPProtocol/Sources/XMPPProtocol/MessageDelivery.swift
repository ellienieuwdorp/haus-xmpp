import Foundation

/// The XEP-0203 stamp our own server put on a stanza it held for this session: offline storage (`from` = our domain)
/// or a hibernated stream's queue (Prosody's mod_smacks stamps every queued stanza, `from` = our bare JID). Exactly
/// one such delay counts, clamped to now; a delay anyone else added is the sender's claim and is ignored. A peer can
/// still write one naming our server, so the stamp only places the message in time and never authenticates anything.
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
