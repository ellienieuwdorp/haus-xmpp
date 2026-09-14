import Foundation
import Security
import MessageStore

struct EncryptedContent: Equatable {
    let body: String
    let reply: MessageReply?

    static func encode(body: String, reply: MessageReply?, sender: String, recipient: String, modern: Bool) throws -> Data {
        guard !body.isEmpty, body.utf8.count <= 16_384, validXML(body),
              validAddress(sender), validAddress(recipient) else { throw OMEMOError.invalidContent }
        if let reply {
            guard !reply.messageID.isEmpty, reply.messageID.utf8.count <= 1024,
                  validXML(reply.messageID), validAddress(reply.senderID),
                  reply.body.utf8.count <= 16_384, validXML(reply.body),
                  reply.wireID.map({ !$0.isEmpty && $0.utf8.count <= 1024 && validXML($0) }) ?? true
            else { throw OMEMOError.invalidContent }
        }
        let quote = reply.map { "> \($0.senderID)\n" + $0.body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)\n" }.joined() + "\n" } ?? ""
        let text = quote + body
        if !modern { return Data(text.utf8) }
        var contents = "<body xmlns='jabber:client'>\(escape(text))</body>"
        if let reply, let wireID = reply.wireID {
            contents += "<reply xmlns='urn:xmpp:reply:0' to='\(escape(reply.senderID))' id='\(escape(wireID))'/>"
            contents += "<fallback xmlns='urn:xmpp:fallback:0' for='urn:xmpp:reply:0'><body start='0' end='\(quote.unicodeScalars.count)'/></fallback>"
        }
        var random = [UInt8](repeating: 0, count: Int.random(in: 32...128))
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw OMEMOError.stateUnavailable }
        return Data("<envelope xmlns='urn:xmpp:sce:1'><content>\(contents)</content><rpad>\(Data(random).base64EncodedString())</rpad><from jid='\(escape(sender))'/><to jid='\(escape(recipient))'/></envelope>".utf8)
    }

    static func decode(_ data: Data, sender: String, recipient: String, modern: Bool) throws -> EncryptedContent {
        guard data.count <= 131_072, let text = String(data: data, encoding: .utf8) else { throw OMEMOError.invalidContent }
        if !modern {
            guard !text.isEmpty else { throw OMEMOError.invalidContent }
            return EncryptedContent(body: text, reply: nil)
        }
        let root = try ContentParser.parse(data)
        let ns = "urn:xmpp:sce:1"
        guard root.name == "envelope", root.namespace == ns,
              root.match("rpad", ns).count == 1,
              root.match("content", ns).count == 1,
              root.match("from", ns).count <= 1, root.match("to", ns).count <= 1 else { throw OMEMOError.invalidContent }
        // A present affix must match the authenticated direct-message context. Missing from is
        // permitted by XEP-0384; this client always emits it. Group traffic has a separate contract.
        if let from = root.match("from", ns).first {
            guard from.attributes["jid"].map(bare) == sender else { throw OMEMOError.invalidContent }
        }
        if let to = root.match("to", ns).first {
            guard to.attributes["jid"].map(bare) == recipient else { throw OMEMOError.invalidContent }
        }
        let content = root.match("content", ns)[0]
        let bodies = content.match("body", "jabber:client")
        guard bodies.count == 1, !bodies[0].text.isEmpty, bodies[0].children.isEmpty else { throw OMEMOError.invalidContent }
        var body = bodies[0].text
        var reply: MessageReply?
        let references = content.match("reply", "urn:xmpp:reply:0")
        let fallbacks = content.match("fallback", "urn:xmpp:fallback:0").filter { $0.attributes["for"] == "urn:xmpp:reply:0" }
        if references.count == 1, fallbacks.count == 1,
           let id = references[0].attributes["id"], !id.isEmpty, id.utf8.count <= 1024,
           let author = references[0].attributes["to"], validAddress(author),
           fallbacks[0].match("body", "urn:xmpp:fallback:0").count == 1 {
            let range = fallbacks[0].match("body", "urn:xmpp:fallback:0")[0]
            let scalars = Array(body.unicodeScalars)
            if range.attributes["start"] == "0", let endText = range.attributes["end"], let end = Int(endText), end > 0, end < scalars.count {
                let quote = String(String.UnicodeScalarView(scalars[..<end]))
                let remaining = String(String.UnicodeScalarView(scalars[end...]))
                if quote.utf8.count <= 16_384 {
                    reply = MessageReply(messageID: id, senderID: author, body: unquote(quote, author: author), wireID: id)
                    body = remaining
                }
            }
        }
        return EncryptedContent(body: body, reply: reply)
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
    private static func validAddress(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 3071 && validXML(value)
            && !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) })
    }
    private static func validXML(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            let v = scalar.value
            return v == 9 || v == 10 || v == 13 || (0x20...0xd7ff).contains(v)
                || (0xe000...0xfffd).contains(v) || (0x10000...0x10ffff).contains(v)
        }
    }
    private static func bare(_ jid: String) -> String { String(jid.split(separator: "/", maxSplits: 1).first ?? "") }
    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "'", with: "&apos;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

private struct ContentNode {
    let name: String
    let namespace: String
    let attributes: [String: String]
    var text = ""
    var children: [ContentNode] = []
    func match(_ name: String, _ namespace: String) -> [ContentNode] { children.filter { $0.name == name && $0.namespace == namespace } }
}
private final class ContentParser: NSObject, XMLParserDelegate {
    private var stack: [ContentNode] = []
    private var root: ContentNode?
    private var invalid = false
    static func parse(_ data: Data) throws -> ContentNode {
        // No document declarations, entities or external resources in a decrypted SCE element.
        guard let text = String(data: data, encoding: .utf8), !text.contains("<!"), !text.contains("<?") else { throw OMEMOError.invalidContent }
        let delegate = ContentParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), !delegate.invalid, delegate.stack.isEmpty, let root = delegate.root else { throw OMEMOError.invalidContent }
        return root
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        guard stack.count < 16 else { invalid = true; parser.abortParsing(); return }
        stack.append(ContentNode(name: name, namespace: namespaceURI ?? "", attributes: attributes))
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if !stack.isEmpty { stack[stack.count - 1].text += string }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard let node = stack.popLast() else { invalid = true; return }
        if stack.isEmpty {
            if root != nil { invalid = true }
            root = node
        } else { stack[stack.count - 1].children.append(node) }
    }
}
