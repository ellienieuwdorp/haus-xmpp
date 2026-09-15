import Foundation
import Security
import MessageStore
import XMPPProtocol

/// SCE (XEP-0420) envelope around the shared `MessageContent` grammar. Only the wrapper,
/// the affix checks and the trust decisions live here; the payload elements are decoded once,
/// strictly, by XMPPProtocol.
struct EncryptedContent: Equatable {
    let body: String
    let reply: MessageReply?
    var reaction: ReactionContent? = nil
    var originID: String? = nil
    var timestamp: Date? = nil

    static func encode(body: String, reply: MessageReply?, sender: String, recipient: String, modern: Bool, originID: String? = nil) throws -> Data {
        guard !body.isEmpty, body.utf8.count <= 16_384, MessageContent.validXMLText(body),
              MessageContent.validAddress(sender), MessageContent.validAddress(recipient) else { throw OMEMOError.invalidContent }
        if let reply {
            guard !reply.messageID.isEmpty, reply.messageID.utf8.count <= 1024,
                  MessageContent.validXMLText(reply.messageID), MessageContent.validAddress(reply.senderID),
                  reply.body.utf8.count <= 16_384, MessageContent.validXMLText(reply.body),
                  reply.wireID.map({ !$0.isEmpty && $0.utf8.count <= 1024 && MessageContent.validXMLText($0) }) ?? true
            else { throw OMEMOError.invalidContent }
        }
        let quote = reply.map { "> \($0.senderID)\n" + $0.body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)\n" }.joined() + "\n" } ?? ""
        if !modern { return Data((quote + body).utf8) }
        let content = MessageContent(body: body, reply: reply.map { .init(id: $0.wireID, to: $0.senderID, quote: quote) }, originID: originID)
        return try wrap(content, sender: sender, recipient: recipient)
    }

    static func encodeReaction(targetWireID: String, reactions: [String], sender: String,
                               recipient: String, originID: String, modern: Bool) throws -> Data {
        guard modern else { throw OMEMOError.unsupportedEncryptedReactions }
        let content = MessageContent(body: "", reaction: .init(targetID: targetWireID, reactions: reactions), originID: originID)
        return try wrap(content, sender: sender, recipient: recipient)
    }

    private static func wrap(_ content: MessageContent, sender: String, recipient: String) throws -> Data {
        guard MessageContent.validAddress(sender), MessageContent.validAddress(recipient), let contents = try? content.xml() else { throw OMEMOError.invalidContent }
        var random = [UInt8](repeating: 0, count: Int.random(in: 32...128))
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw OMEMOError.stateUnavailable }
        return Data("<envelope xmlns='urn:xmpp:sce:1'><content>\(contents)</content><rpad>\(Data(random).base64EncodedString())</rpad><from jid='\(escape(sender))'/><to jid='\(escape(recipient))'/></envelope>".utf8)
    }

    static func decode(_ data: Data, sender: String, recipient: String, modern: Bool, sendingTime: Date? = nil, requireGroupAffixes: Bool = false) throws -> EncryptedContent {
        guard data.count <= 131_072, let text = String(data: data, encoding: .utf8) else { throw OMEMOError.invalidContent }
        if !modern {
            guard !text.isEmpty else { throw OMEMOError.invalidContent }
            return EncryptedContent(body: text, reply: nil)
        }
        guard let root = try? XMPPProtocol.XMLNode.parse(standalone: data) else { throw OMEMOError.invalidContent }
        let ns = "urn:xmpp:sce:1"
        guard root.name == "envelope", root.namespace == ns,
              root.children("rpad", namespace: ns).count == 1,
              root.children("content", namespace: ns).count == 1,
              root.children("from", namespace: ns).count <= 1, root.children("to", namespace: ns).count <= 1, root.children("time", namespace: ns).count <= 1 else { throw OMEMOError.invalidContent }
        if requireGroupAffixes {
            guard root.children("from", namespace: ns).count == 1, root.children("to", namespace: ns).count == 1 else { throw OMEMOError.invalidContent }
        }
        // A present affix must match the authenticated direct-message context. Missing from is
        // permitted by XEP-0384; this client always emits it. Group traffic has a separate contract.
        if let from = root.child("from", namespace: ns) {
            guard from.attributes["jid"].map(bare) == sender else { throw OMEMOError.invalidContent }
        }
        if let to = root.child("to", namespace: ns) {
            guard to.attributes["jid"].map(bare) == recipient else { throw OMEMOError.invalidContent }
        }
        var timestamp: Date?
        if let time = root.child("time", namespace: ns) {
            guard let raw = time.attributes["stamp"], raw.utf8.count <= 64,
                  let parsed = parseTimestamp(raw), time.children.isEmpty else { throw OMEMOError.invalidContent }
            // A signed time is optional. When present SCE requires comparison with the
            // trusted archive/live sending context; never accept an arbitrary future time.
            let reference = sendingTime ?? Date()
            guard abs(parsed.timeIntervalSince(reference)) <= 300 else { throw OMEMOError.invalidContent }
            timestamp = parsed
        }
        guard let content = try? MessageContent.decode(root.children("content", namespace: ns)[0], strict: true),
              !content.body.isEmpty || content.reaction != nil else { throw OMEMOError.invalidContent }
        let reply = content.reply.flatMap { reply in
            reply.id.map { MessageReply(messageID: $0, senderID: reply.to, body: unquote(reply.quote, author: reply.to), wireID: $0) }
        }
        return EncryptedContent(body: content.body, reply: reply,
                                reaction: content.reaction.map { ReactionContent(targetWireID: $0.targetID, reactions: $0.reactions) },
                                originID: content.originID, timestamp: timestamp)
    }

    // Remove only the exact quotation syntax emitted by this adapter. Foreign fallback
    // layouts remain readable verbatim; a heuristic must never discard source text.
    private static func unquote(_ quote: String, author: String) -> String {
        let prefix = "> \(author)\n"
        guard quote.hasPrefix(prefix), quote.hasSuffix("\n\n") else { return quote }
        let lines = quote.dropFirst(prefix.count).dropLast(2).split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.allSatisfy({ $0.hasPrefix("> ") }) else { return quote }
        return lines.map { String($0.dropFirst(2)) }.joined(separator: "\n")
    }
    private static func parseTimestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
    private static func bare(_ jid: String) -> String { String(jid.split(separator: "/", maxSplits: 1).first ?? "") }
    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "'", with: "&apos;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

struct ReactionContent: Equatable, Sendable {
    let targetWireID: String
    let reactions: [String]
    static func normalized(_ values: [String]) throws -> [String] {
        guard let normalized = try? MessageContent.normalizedReactions(values) else { throw OMEMOError.invalidContent }
        return normalized
    }
    static func isEmoji(_ value: String) -> Bool { MessageContent.isEmoji(value) }
}
