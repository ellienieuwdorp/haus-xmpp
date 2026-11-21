import Foundation

public struct XMLNode: Sendable, Equatable {
    public let name: String
    public let namespace: String
    public let attributes: [String: String]
    public var text = ""
    public var children: [XMLNode] = []
    /// The namespace bound to each prefix of a prefixed attribute where the parser met this element; `xml` and `xmlns`
    /// are not recorded. Read attributes with `attribute(_:namespace:)`.
    public let attributePrefixes: [String: String]

    public init(name: String, namespace: String, attributes: [String: String], text: String = "", children: [XMLNode] = [],
                attributePrefixes: [String: String] = [:]) {
        self.name = name; self.namespace = namespace; self.attributes = attributes; self.text = text; self.children = children
        self.attributePrefixes = attributePrefixes
    }

    /// Matches whatever prefix the sender bound. An unprefixed attribute is in no namespace, so it never matches; two
    /// attributes with the same expanded name give nil.
    public func attribute(_ localName: String, namespace: String) -> String? {
        if namespace == Self.xmlNamespace { return attributes["xml:" + localName] }
        let matches = attributes.filter { key, _ in
            guard let colon = key.firstIndex(of: ":"), key[key.index(after: colon)...] == localName else { return false }
            return attributePrefixes[String(key[..<colon])] == namespace
        }
        return matches.count == 1 ? matches.first?.value : nil
    }

    static let xmlNamespace = "http://www.w3.org/XML/1998/namespace"

    public func child(_ name: String, namespace: String) -> XMLNode? {
        children.first { $0.name == name && $0.namespace == namespace }
    }
    public func children(_ name: String, namespace: String) -> [XMLNode] {
        children.filter { $0.name == name && $0.namespace == namespace }
    }
    /// A leaf is 1.
    public var depth: Int { 1 + (children.map(\.depth).max() ?? 0) }

    /// One complete element outside any stream, such as a decrypted SCE payload. No declarations, comments, CDATA,
    /// entities or external resources.
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
    // A well-formed element past the depth or attribute limit. It keeps only what lies within the limits, for the
    // client to count and address it; its content is never read.
    case rejected(XMLNode)
    case closed
}

// Frames an unclosed stream without interpreting incomplete UTF-8; Apple's XML parser validates each complete stanza
// in stream namespace context. Past `maximumDepth` the framer only counts depth, so a deep subtree is never buffered;
// `maximumBytes` bounds a stanza including what it skipped.
struct XMLStreamFramer {
    static let maximumDepth = 64
    let maximumBytes: Int
    private var pending: [UInt8] = []
    private var stanza: [UInt8] = []
    private var skipped = 0
    private var tooDeep = false
    private var depth = 0
    private var streamOpening: String?
    private var streamQName: String?
    private var closed = false

    init(maximumBytes: Int = 1_048_576) { self.maximumBytes = maximumBytes }

    // Ignores whitespace between elements.
    var hasBufferedInput: Bool { !stanza.isEmpty || !pending.allSatisfy(Self.whitespace) }

    mutating func feed(_ data: Data) throws -> [XMLStreamFrame] {
        guard pending.count + stanza.count + skipped + data.count <= maximumBytes else { throw XMLStreamError.limitExceeded }
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
                } else { keep(content, inside: depth) }
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
                if depth > 0 { keep(bytes, inside: depth) }
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
            if let frame = try advance(bytes, isEnd: isEnd, isEmpty: isEmpty) { frames.append(frame) }
        }
        return frames
    }

    // Takes one tag inside a stanza; the stanza's frame once its root closes.
    private mutating func advance(_ bytes: [UInt8], isEnd: Bool, isEmpty: Bool) throws -> XMLStreamFrame? {
        // The level of the element this tag opens or closes.
        let level = isEnd ? depth : depth + 1
        if level > Self.maximumDepth { tooDeep = true }
        keep(bytes, inside: level)
        if isEnd { depth -= 1 } else if !isEmpty { depth += 1 }
        guard depth == 0 else { return nil }
        defer { stanza.removeAll(keepingCapacity: true); skipped = 0; tooDeep = false }
        guard let opening = streamOpening, let qName = streamQName, let xml = String(bytes: stanza, encoding: .utf8) else {
            throw XMLStreamError.invalidXML
        }
        let (root, overLimit) = try NodeParser.parseBounded(opening + xml + "</\(qName)>")
        guard root.children.count == 1 else { throw XMLStreamError.invalidXML }
        return tooDeep || overLimit ? .rejected(root.children[0]) : .element(root.children[0])
    }

    // A subtree that starts past the depth limit stays out of the buffer whole, so what is kept stays well-formed.
    private mutating func keep(_ bytes: some Collection<UInt8>, inside level: Int) {
        if level > Self.maximumDepth { skipped += bytes.count } else { stanza.append(contentsOf: bytes) }
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
    static let maximumAttributes = 128
    private var stack: [XMLNode] = []
    private var root: XMLNode?
    private var invalid = false
    // Bounded: an element past a limit keeps its name and namespace, and its attributes, text and subtree are skipped.
    private var overLimit = false
    private var skipping = 0
    private var prefixes: [String: [String]] = ["xml": [XMLNode.xmlNamespace]]
    private let maxDepth: Int
    private let singleRoot: Bool
    private let bounded: Bool
    private init(maxDepth: Int, singleRoot: Bool, bounded: Bool) { self.maxDepth = maxDepth; self.singleRoot = singleRoot; self.bounded = bounded }

    static func parse(_ xml: String, maxDepth: Int = 66, singleRoot: Bool = false) throws -> XMLNode {
        try run(NodeParser(maxDepth: maxDepth, singleRoot: singleRoot, bounded: false), xml).root
    }

    // The stream wrapper with its stanza; `overLimit` when an element exceeded the depth or attribute limit.
    static func parseBounded(_ xml: String) throws -> (root: XMLNode, overLimit: Bool) {
        try run(NodeParser(maxDepth: XMLStreamFramer.maximumDepth + 1, singleRoot: false, bounded: true), xml)
    }

    private static func run(_ delegate: NodeParser, _ xml: String) throws -> (root: XMLNode, overLimit: Bool) {
        let parser = XMLParser(data: Data(xml.utf8))
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), !delegate.invalid, let root = delegate.root else { throw XMLStreamError.invalidXML }
        return (root, delegate.overLimit)
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if skipping > 0 { skipping += 1; return }
        if qualifiedName?.contains(":") == true && (namespaceURI ?? "").isEmpty { invalid = true; parser.abortParsing(); return }
        var attributePrefixes: [String: String] = [:]
        for key in attributes.keys where key.contains(":") {
            let prefix = String(key.prefix { $0 != ":" })
            guard prefix == "xmlns" || prefixes[prefix]?.last?.isEmpty == false else { invalid = true; parser.abortParsing(); return }
            if prefix != "xmlns" && prefix != "xml" { attributePrefixes[prefix] = prefixes[prefix]?.last }
        }
        guard stack.count < maxDepth, attributes.count <= Self.maximumAttributes else {
            guard bounded else { invalid = true; parser.abortParsing(); return }
            overLimit = true; skipping = 1
            stack.append(XMLNode(name: name, namespace: namespaceURI ?? "", attributes: [:]))
            return
        }
        stack.append(XMLNode(name: name, namespace: namespaceURI ?? "", attributes: attributes, attributePrefixes: attributePrefixes))
    }
    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) { prefixes[prefix, default: []].append(namespaceURI) }
    func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) { _ = prefixes[prefix]?.popLast() }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if skipping == 0, !stack.isEmpty { stack[stack.count - 1].text += string }
    }
    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        guard let value = String(data: data, encoding: .utf8) else { invalid = true; parser.abortParsing(); return }
        self.parser(parser, foundCharacters: value)
    }
    func parser(_ parser: XMLParser, didEndElement: String, namespaceURI: String?, qualifiedName: String?) {
        if skipping > 1 { skipping -= 1; return }
        skipping = 0
        guard let node = stack.popLast() else { invalid = true; return }
        if stack.isEmpty {
            if singleRoot, root != nil { invalid = true }
            root = node
        } else { stack[stack.count - 1].children.append(node) }
    }
    func parser(_ parser: XMLParser, parseErrorOccurred parseError: any Error) { invalid = true }
    func parser(_ parser: XMLParser, validationErrorOccurred validationError: any Error) { invalid = true }
    func parser(_ parser: XMLParser, resolveExternalEntityName: String, systemID: String?) -> Data? {
        invalid = true; parser.abortParsing(); return nil
    }
}

func xmlEscaped(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
}
