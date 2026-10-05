import Foundation

public struct XMLNode: Sendable, Equatable {
    public let name: String
    public let namespace: String
    public let attributes: [String: String]
    public var text = ""
    public var children: [XMLNode] = []

    public init(name: String, namespace: String, attributes: [String: String], text: String = "", children: [XMLNode] = []) {
        self.name = name; self.namespace = namespace; self.attributes = attributes; self.text = text; self.children = children
    }

    public func child(_ name: String, namespace: String) -> XMLNode? {
        children.first { $0.name == name && $0.namespace == namespace }
    }
    public func children(_ name: String, namespace: String) -> [XMLNode] {
        children.filter { $0.name == name && $0.namespace == namespace }
    }
    /// Nesting depth of the deepest descendant; a leaf is 1.
    public var depth: Int { 1 + (children.map(\.depth).max() ?? 0) }

    /// One complete element outside any stream: a decrypted SCE payload. No declarations,
    /// comments, CDATA, entities or external resources, and the element limit is shallow.
    public static func parse(standalone data: Data, maxDepth: Int = MessageContent.maximumDepth) throws -> XMLNode {
        guard let text = String(data: data, encoding: .utf8), !text.contains("<!"), !text.contains("<?") else { throw XMLStreamError.forbiddenDeclaration }
        return try NodeParser.parse(text, maxDepth: maxDepth, singleRoot: true)
    }
}

enum XMLStreamError: Error, Equatable {
    case invalidXML, forbiddenDeclaration, limitExceeded, unexpectedStream
}

enum XMLStreamFrame: Sendable, Equatable {
    case opened
    case element(XMLNode)
    case closed
}

/// Frames an unclosed XMPP XML stream without interpreting incomplete UTF-8.
/// Each complete stanza is then validated by Apple's XML parser in stream namespace context.
struct XMLStreamFramer {
    let maximumBytes: Int
    private var pending: [UInt8] = []
    private var stanza: [UInt8] = []
    private var depth = 0
    private var streamOpening: String?
    private var streamQName: String?
    private var closed = false

    init(maximumBytes: Int = 1_048_576) { self.maximumBytes = maximumBytes }

    /// Bytes fed but not yet framed, apart from whitespace between elements.
    var hasBufferedInput: Bool { !stanza.isEmpty || !pending.allSatisfy(Self.whitespace) }

    mutating func feed(_ data: Data) throws -> [XMLStreamFrame] {
        guard pending.count + stanza.count + data.count <= maximumBytes else { throw XMLStreamError.limitExceeded }
        pending.append(contentsOf: data)
        var frames: [XMLStreamFrame] = []
        while !pending.isEmpty {
            guard !closed else {
                if pending.allSatisfy(Self.whitespace) { pending.removeAll(); break }
                throw XMLStreamError.unexpectedStream
            }
            if pending[0] != 60 { // <
                guard let end = pending.firstIndex(of: 60) else {
                    if depth == 0 && !pending.allSatisfy(Self.whitespace) { throw XMLStreamError.invalidXML }
                    break
                }
                let content = Array(pending[..<end])
                if depth == 0 {
                    guard content.allSatisfy(Self.whitespace) else { throw XMLStreamError.invalidXML }
                } else { stanza.append(contentsOf: content) }
                pending.removeFirst(end)
                continue
            }
            guard let tokenEnd = try Self.tokenEnd(pending) else { break }
            let bytes = Array(pending[...tokenEnd])
            guard let token = String(bytes: bytes, encoding: .utf8) else { throw XMLStreamError.invalidXML }
            pending.removeFirst(tokenEnd + 1)
            if token.hasPrefix("<?") {
                guard streamOpening == nil, token.hasPrefix("<?xml ") else { throw XMLStreamError.forbiddenDeclaration }
                continue
            }
            if token.hasPrefix("<!") {
                guard token.hasPrefix("<!--") || (depth > 0 && token.hasPrefix("<![CDATA[")) else { throw XMLStreamError.forbiddenDeclaration }
                if depth > 0 { stanza.append(contentsOf: bytes) }
                continue
            }
            let isEnd = token.hasPrefix("</")
            let isEmpty = token.hasSuffix("/>")
            if streamOpening == nil {
                guard !isEnd, !isEmpty else { throw XMLStreamError.unexpectedStream }
                let name = String(token.dropFirst().prefix { !$0.isWhitespace && $0 != ">" })
                let root = try NodeParser.parse(String(token.dropLast()) + "/>")
                guard root.name == "stream", root.namespace == "http://etherx.jabber.org/streams" else { throw XMLStreamError.unexpectedStream }
                streamOpening = token
                streamQName = name
                frames.append(.opened)
                continue
            }
            if depth == 0 && isEnd {
                guard token == "</\(streamQName!)>" else { throw XMLStreamError.unexpectedStream }
                closed = true
                frames.append(.closed)
                continue
            }
            stanza.append(contentsOf: bytes)
            if isEnd { depth -= 1 } else if !isEmpty { depth += 1 }
            guard depth >= 0, depth <= 64 else { throw XMLStreamError.limitExceeded }
            if depth == 0 {
                guard let xml = String(bytes: stanza, encoding: .utf8) else { throw XMLStreamError.invalidXML }
                let root = try NodeParser.parse(streamOpening! + xml + "</\(streamQName!)>")
                guard root.children.count == 1 else { throw XMLStreamError.invalidXML }
                frames.append(.element(root.children[0]))
                stanza.removeAll(keepingCapacity: true)
            }
        }
        return frames
    }

    private static func whitespace(_ byte: UInt8) -> Bool { byte == 32 || byte == 9 || byte == 10 || byte == 13 }

    private static func tokenEnd(_ bytes: [UInt8]) throws -> Int? {
        if bytes.starts(with: Array("<!--".utf8)) { return sequenceEnd(Array("-->".utf8), in: bytes) }
        if bytes.starts(with: Array("<![CDATA[".utf8)) { return sequenceEnd(Array("]]>".utf8), in: bytes) }
        // An incomplete declaration prefix may become a comment or CDATA on the next read.
        if bytes.starts(with: [60, 33]) {
            if ["<!--", "<![CDATA["].contains(where: { Array($0.utf8).starts(with: bytes) }) { return nil }
            throw XMLStreamError.forbiddenDeclaration
        }
        var quote: UInt8?
        for i in 1..<bytes.count {
            let b = bytes[i]
            if let q = quote { if b == q { quote = nil } }
            else if b == 34 || b == 39 { quote = b }
            else if b == 62 { return i }
        }
        return nil
    }

    private static func sequenceEnd(_ sequence: [UInt8], in bytes: [UInt8]) -> Int? {
        guard bytes.count >= sequence.count else { return nil }
        for i in 0...(bytes.count - sequence.count) where bytes[i..<(i + sequence.count)].elementsEqual(sequence) {
            return i + sequence.count - 1
        }
        return nil
    }
}

private final class NodeParser: NSObject, XMLParserDelegate {
    private var stack: [XMLNode] = []
    private var root: XMLNode?
    private var invalid = false
    private var prefixes: [String: [String]] = ["xml": ["http://www.w3.org/XML/1998/namespace"]]
    private let maxDepth: Int
    private let singleRoot: Bool
    private init(maxDepth: Int, singleRoot: Bool) { self.maxDepth = maxDepth; self.singleRoot = singleRoot }

    static func parse(_ xml: String, maxDepth: Int = 66, singleRoot: Bool = false) throws -> XMLNode {
        let delegate = NodeParser(maxDepth: maxDepth, singleRoot: singleRoot)
        let parser = XMLParser(data: Data(xml.utf8))
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), !delegate.invalid, let root = delegate.root else { throw XMLStreamError.invalidXML }
        return root
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if qualifiedName?.contains(":") == true && (namespaceURI ?? "").isEmpty { invalid = true; parser.abortParsing(); return }
        for key in attributes.keys where key.contains(":") {
            let prefix = String(key.prefix { $0 != ":" })
            guard prefix == "xmlns" || prefixes[prefix]?.last?.isEmpty == false else { invalid = true; parser.abortParsing(); return }
        }
        guard stack.count < maxDepth, attributes.count <= 128 else { invalid = true; parser.abortParsing(); return }
        stack.append(XMLNode(name: name, namespace: namespaceURI ?? "", attributes: attributes))
    }
    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) { prefixes[prefix, default: []].append(namespaceURI) }
    func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) { _ = prefixes[prefix]?.popLast() }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if !stack.isEmpty { stack[stack.count - 1].text += string }
    }
    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        guard let value = String(data: data, encoding: .utf8) else { invalid = true; parser.abortParsing(); return }
        self.parser(parser, foundCharacters: value)
    }
    func parser(_ parser: XMLParser, didEndElement: String, namespaceURI: String?, qualifiedName: String?) {
        guard let node = stack.popLast() else { invalid = true; return }
        if stack.isEmpty {
            if singleRoot, root != nil { invalid = true }
            root = node
        } else { stack[stack.count - 1].children.append(node) }
    }
    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { invalid = true }
    func parser(_ parser: XMLParser, validationErrorOccurred validationError: Error) { invalid = true }
    func parser(_ parser: XMLParser, resolveExternalEntityName: String, systemID: String?) -> Data? {
        invalid = true; parser.abortParsing(); return nil
    }
}

func xmlEscaped(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
}
