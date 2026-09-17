import Foundation

/// The one grammar for message payload elements, shared by plain stanzas and decrypted SCE
/// `<content>`. Wrappers differ (a `<message>` stanza, an SCE envelope); the elements do not.
/// `strict` decoding is for authenticated content, where any ambiguity is tampering and
/// rejects the whole payload. Lenient decoding is for untrusted outer stanzas, where an
/// ambiguous extension is dropped and the rest of the stanza is still delivered.
public struct MessageContent: Sendable, Equatable {
    public struct Reply: Sendable, Equatable {
        /// Wire identity of the quoted message. Nil emits only the visible quote.
        public let id: String?
        public let to: String
        /// The exact fallback text prefixed to the body. Callers own its format.
        public let quote: String
        public init(id: String?, to: String, quote: String) { self.id = id; self.to = to; self.quote = quote }
    }
    public struct Reaction: Sendable, Equatable {
        public let targetID: String
        public let reactions: [String]
        public init(targetID: String, reactions: [String]) { self.targetID = targetID; self.reactions = reactions }
    }

    /// Body text after the reply quote, if any.
    public var body: String
    public var reply: Reply?
    public var reaction: Reaction?
    public var originID: String?
    /// One shared file. `body` is then its caption, which may be empty.
    public var fileSharing: FileSharing?

    public init(body: String, reply: Reply? = nil, reaction: Reaction? = nil, originID: String? = nil, fileSharing: FileSharing? = nil) {
        self.body = body; self.reply = reply; self.reaction = reaction; self.originID = originID; self.fileSharing = fileSharing
    }

    /// The full `<body>` text, quote included.
    public var text: String { (reply?.quote ?? "") + body }

    /// Body text a client without XEP-0447 sees: the URL (legacy `aesgcm://` form when
    /// encrypted) after the caption. The range is declared as a fallback so we can strip it.
    private var fileFallback: String? {
        guard let fileSharing else { return nil }
        let link = fileSharing.aesgcmURL ?? fileSharing.url
        return body.isEmpty ? link : "\n" + link
    }

    public static let maximumDepth = 16
    public static let maximumReactionCount = 12

    public func xml() throws -> String {
        guard Self.validXMLText(body), (!body.isEmpty || reaction != nil || fileSharing != nil),
              originID.map(Self.validIdentifier) ?? true else { throw XMPPClientError.invalidConfiguration }
        var xml = ""
        if let reply {
            guard reply.id.map(Self.validIdentifier) ?? true, Self.validAddress(reply.to),
                  !reply.quote.isEmpty, Self.validXMLText(reply.quote) else { throw XMPPClientError.invalidConfiguration }
        }
        if !body.isEmpty || reply != nil || fileSharing != nil {
            xml += "<body xmlns='jabber:client'>\(xmlEscaped(text + (fileFallback ?? "")))</body>"
        }
        if let reply, let id = reply.id {
            xml += "<reply xmlns='urn:xmpp:reply:0' to='\(xmlEscaped(reply.to))' id='\(xmlEscaped(id))'/>"
            xml += "<fallback xmlns='urn:xmpp:fallback:0' for='urn:xmpp:reply:0'><body start='0' end='\(reply.quote.unicodeScalars.count)'/></fallback>"
        }
        if let fileSharing, let fallback = fileFallback {
            xml += try fileSharing.xml()
            let start = text.unicodeScalars.count
            xml += "<fallback xmlns='urn:xmpp:fallback:0' for='\(FileSharing.namespace)'><body start='\(start)' end='\(start + fallback.unicodeScalars.count)'/></fallback>"
        }
        if let reaction {
            let values = try Self.normalizedReactions(reaction.reactions)
            guard Self.validIdentifier(reaction.targetID) else { throw XMPPClientError.invalidConfiguration }
            xml += "<reactions xmlns='urn:xmpp:reactions:0' id='\(xmlEscaped(reaction.targetID))'>"
            xml += values.map { "<reaction>\(xmlEscaped($0))</reaction>" }.joined() + "</reactions>"
        }
        if let originID { xml += "<origin-id xmlns='urn:xmpp:sid:0' id='\(xmlEscaped(originID))'/>" }
        return xml
    }

    /// `node` is the element whose children carry the payload: a `<message>` or an SCE `<content>`.
    public static func decode(_ node: XMLNode, strict: Bool) throws -> MessageContent {
        guard node.depth <= maximumDepth else { throw XMPPClientError.invalidConfiguration }
        func ambiguous() throws { if strict { throw XMPPClientError.invalidConfiguration } }

        let bodies = node.children("body", namespace: "jabber:client")
        if strict { guard bodies.count <= 1, bodies.allSatisfy({ !$0.text.isEmpty && $0.children.isEmpty }) else { throw XMPPClientError.invalidConfiguration } }
        var body = bodies.first?.text ?? ""

        let origins = node.children("origin-id", namespace: "urn:xmpp:sid:0")
        var originID: String?
        // Multiple origin IDs are ambiguous; never pick one based on XML order.
        if origins.count > 1 { try ambiguous() }
        else if let origin = origins.first {
            if let id = origin.attributes["id"], validIdentifier(id), origin.children.isEmpty, origin.text.isEmpty { originID = id } else { try ambiguous() }
        }

        let reactionNodes = node.children("reactions", namespace: "urn:xmpp:reactions:0")
        var reaction: Reaction?
        if reactionNodes.count > 1 { try ambiguous() }
        else if let container = reactionNodes.first {
            // XEP-0444 sends the complete set; an empty set withdraws. Duplicate and non-emoji
            // values are ignored, as the XEP permits, so a foreign client cannot poison a ratchet.
            if let target = container.attributes["id"], validIdentifier(target), container.children.count <= 48,
               container.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               container.children.allSatisfy({ $0.name == "reaction" && $0.namespace == "urn:xmpp:reactions:0" && $0.children.isEmpty && validXMLText($0.text) }) {
                let values = Array(Set(container.children.map(\.text).filter(isEmoji))).sorted()
                if values.count <= maximumReactionCount { reaction = Reaction(targetID: target, reactions: values) } else { try ambiguous() }
            } else { try ambiguous() }
        }

        var fileSharing: FileSharing?
        let files = node.children("file-sharing", namespace: FileSharing.namespace)
        if files.count > 1 { try ambiguous() }
        else if let file = files.first {
            if let decoded = FileSharing.decode(file) {
                fileSharing = decoded
                // Strip the URL we (or a like-minded sender) appended for clients without XEP-0447.
                let ranges = node.children("fallback", namespace: "urn:xmpp:fallback:0").filter { $0.attributes["for"] == FileSharing.namespace }
                    .flatMap { $0.children("body", namespace: "urn:xmpp:fallback:0") }
                let scalars = Array(body.unicodeScalars)
                if ranges.count == 1, let start = ranges[0].attributes["start"].flatMap(Int.init), let end = ranges[0].attributes["end"].flatMap(Int.init),
                   start >= 0, start < end, end <= scalars.count {
                    body = String(String.UnicodeScalarView(scalars[..<start] + scalars[end...]))
                } else if ranges.isEmpty, body.trimmingCharacters(in: .whitespacesAndNewlines) == decoded.url {
                    body = ""
                }
            } else { try ambiguous() }
        }

        var reply: Reply?
        let references = node.children("reply", namespace: "urn:xmpp:reply:0")
        let fallbacks = node.children("fallback", namespace: "urn:xmpp:fallback:0").filter { $0.attributes["for"] == "urn:xmpp:reply:0" }
        // A malformed fallback never discards message text: the body stays verbatim without a reply.
        if references.count == 1, fallbacks.count == 1,
           let id = references[0].attributes["id"], validIdentifier(id),
           let author = references[0].attributes["to"], validAddress(author),
           fallbacks[0].children("body", namespace: "urn:xmpp:fallback:0").count == 1 {
            let range = fallbacks[0].children("body", namespace: "urn:xmpp:fallback:0")[0]
            let scalars = Array(body.unicodeScalars)
            if range.attributes["start"] == "0", let endText = range.attributes["end"], let end = Int(endText), end > 0, end < scalars.count {
                let quote = String(String.UnicodeScalarView(scalars[..<end]))
                if quote.utf8.count <= 16_384 {
                    reply = Reply(id: id, to: author, quote: quote)
                    body = String(String.UnicodeScalarView(scalars[end...]))
                }
            }
        }
        return MessageContent(body: body, reply: reply, reaction: reaction, originID: originID, fileSharing: fileSharing)
    }

    /// Complete set, deduplicated and sorted, so equal intentions produce equal bytes.
    public static func normalizedReactions(_ values: [String]) throws -> [String] {
        guard values.count <= maximumReactionCount, values.allSatisfy(isEmoji) else { throw XMPPClientError.invalidConfiguration }
        return Array(Set(values)).sorted()
    }

    public static func isEmoji(_ value: String) -> Bool {
        guard value.count == 1, value.utf8.count <= 64 else { return false }
        let scalars = value.unicodeScalars
        // Unicode's emoji property includes bare ASCII digits. Those need a keycap
        // sequence; text-presentation emoji require VS16 to count as an emoji here.
        return scalars.contains { $0.properties.isEmojiPresentation }
            || (scalars.contains { $0.properties.isEmoji } && scalars.contains { $0.value == 0xfe0f || $0.value == 0x20e3 })
    }

    /// Keep attribute normalization from changing a caller's durable identifier.
    public static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1_024 && !value.contains(where: { $0.isWhitespace }) && validXMLText(value)
    }
    public static func validAddress(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 3_071 && !value.contains(where: { $0.isWhitespace }) && validXMLText(value)
    }
    public static func validXMLText(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy {
            $0.value == 9 || $0.value == 10 || $0.value == 13 ||
            (0x20...0xD7FF).contains($0.value) || (0xE000...0xFFFD).contains($0.value) ||
            (0x10000...0x10FFFF).contains($0.value)
        }
    }
}
