import Foundation

/// The OpenGraph fields of a page's head, read by a tolerant tokenizer over at most the bytes the fetcher kept. No
/// WebKit, no `NSAttributedString(html:)` and no `XMLParser`, none of which suit untrusted, often invalid HTML.
/// Reads `og:title`, `og:description`, `og:image` and `og:image:alt`, falling back to `<title>` and
/// `<meta name=description>`; stops at `</head>` or `<body`. Values are as written, entities decoded.
struct LinkPreviewHead: Equatable {
    var title: String?
    var description: String?
    /// The image reference as written, relative or absolute.
    var image: String?
    var imageAlt: String?

    static func parse(_ data: Data, charset: String?) -> LinkPreviewHead {
        let text = decode(data, charset: charset)
        var scanner = Scanner(Array(text.unicodeScalars))
        var og: [String: String] = [:]
        var fallbackTitle: String?, fallbackDescription: String?
        scan: while let tag = scanner.nextTag() {
            switch tag {
            case .end("head"), .start("body", _):
                break scan
            case .start("meta", let attributes):
                guard let content = attributes["content"] else { continue }
                if let property = (attributes["property"] ?? attributes["name"])?.lowercased(), property.hasPrefix("og:") {
                    // The first of each wins: a page lists its main image first.
                    let key = property == "og:image:url" || property == "og:image:secure_url" ? "og:image" : property
                    if og[key] == nil { og[key] = content }
                } else if attributes["name"]?.lowercased() == "description", fallbackDescription == nil {
                    fallbackDescription = content
                }
            case .start("title", _):
                let raw = scanner.rawText(until: "title")
                if fallbackTitle == nil { fallbackTitle = decodeEntities(raw) }
            case .start(let name, _) where ["script", "style", "noscript", "template", "textarea"].contains(name):
                _ = scanner.rawText(until: name)
            default:
                continue
            }
        }
        func value(_ text: String?) -> String? {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
        return LinkPreviewHead(title: value(og["og:title"]) ?? value(fallbackTitle),
                               description: value(og["og:description"]) ?? value(fallbackDescription),
                               image: value(og["og:image"]), imageAlt: value(og["og:image:alt"]))
    }

    /// Whether `data` from `from` on holds `</head` or `<body`, where a page's metadata has ended.
    static func endsHead(_ data: Data, from: Int) -> Bool {
        let markers: [[UInt8]] = [Array("</head".utf8), Array("<body".utf8)]
        let bytes = data.count
        guard bytes > from else { return false }
        return data.withUnsafeBytes { raw -> Bool in
            let buffer = raw.bindMemory(to: UInt8.self)
            var index = from
            while index < bytes {
                if buffer[index] == UInt8(ascii: "<") {
                    for marker in markers where index + marker.count <= bytes {
                        var matches = true
                        for offset in 1..<marker.count where lowered(buffer[index + offset]) != marker[offset] {
                            matches = false
                            break
                        }
                        if matches { return true }
                    }
                }
                index += 1
            }
            return false
        }
    }

    private static func lowered(_ byte: UInt8) -> UInt8 { (65...90).contains(byte) ? byte + 32 : byte }

    // MARK: Charset

    /// The `Content-Type` charset, else a `<meta charset>` or `http-equiv` one near the start, else UTF-8. Invalid
    /// UTF-8 (a page cut at its cap mid-character, or mislabelled) decodes with replacement characters.
    static func decode(_ data: Data, charset: String?) -> String {
        let label = charset ?? declaredCharset(in: data.prefix(2_048))
        if let label, let encoding = encoding(named: label), encoding != .utf8, let text = String(data: data, encoding: encoding) {
            return text
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func encoding(named label: String) -> String.Encoding? {
        let cf = CFStringConvertIANACharSetNameToEncoding(label.trimmingCharacters(in: .whitespaces) as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    private static func declaredCharset(in data: Data) -> String? {
        // Every encoding a page may declare this way is ASCII-compatible for the declaration itself.
        let head = String(decoding: data.map { $0 < 0x80 ? $0 : UInt8(ascii: " ") }, as: UTF8.self).lowercased()
        guard let range = head.range(of: "charset=") else { return nil }
        let rest = head[range.upperBound...].drop { $0 == "\"" || $0 == "'" || $0 == " " }
        let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ":" || $0 == "." }
        return name.isEmpty ? nil : String(name)
    }

    // MARK: Entities

    /// The Latin-1 names (U+00A0 to U+00FF, in order) and the punctuation pages use most.
    private static let named: [String: String] = {
        let latin1 = """
            nbsp iexcl cent pound curren yen brvbar sect uml copy ordf laquo not shy reg macr deg plusmn sup2 sup3 acute micro \
            para middot cedil sup1 ordm raquo frac14 frac12 frac34 iquest Agrave Aacute Acirc Atilde Auml Aring AElig Ccedil \
            Egrave Eacute Ecirc Euml Igrave Iacute Icirc Iuml ETH Ntilde Ograve Oacute Ocirc Otilde Ouml times Oslash Ugrave \
            Uacute Ucirc Uuml Yacute THORN szlig agrave aacute acirc atilde auml aring aelig ccedil egrave eacute ecirc euml \
            igrave iacute icirc iuml eth ntilde ograve oacute ocirc otilde ouml divide oslash ugrave uacute ucirc uuml yacute \
            thorn yuml
            """.split(separator: " ")
        var table = Dictionary(uniqueKeysWithValues: latin1.enumerated().map { (String($1), String(Character(Unicode.Scalar(UInt8(0xA0 + $0))))) })
        table.merge(["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "hellip": "…", "mdash": "—", "ndash": "–", "lsquo": "‘",
                     "rsquo": "’", "ldquo": "“", "rdquo": "”", "bull": "•", "trade": "™", "euro": "€", "OElig": "Œ", "oelig": "œ"]) { $1 }
        return table
    }()

    /// Numeric references and the common named ones; anything else stays as written.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            guard let semicolon = after.prefix(12).firstIndex(of: ";") else {
                result += "&"
                rest = after
                continue
            }
            let name = after[..<semicolon]
            var replacement: String?
            if name.hasPrefix("#x") || name.hasPrefix("#X") {
                replacement = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if name.hasPrefix("#") {
                replacement = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                replacement = named[String(name)]
            }
            if let replacement {
                result += replacement
                rest = after[after.index(after: semicolon)...]
            } else {
                result += "&"
                rest = after
            }
        }
        return result + rest
    }

    // MARK: Tokenizer

    enum Tag: Equatable {
        case start(String, [String: String])
        case end(String)
    }

    struct Scanner {
        private let text: [Unicode.Scalar]
        private var index = 0

        init(_ text: [Unicode.Scalar]) { self.text = text }

        /// The next start or end tag; comments, doctypes and processing instructions are skipped.
        mutating func nextTag() -> Tag? {
            while index < text.count {
                guard text[index] == "<" else { index += 1; continue }
                if starts(with: "<!--") {
                    index = find("-->").map { $0 + 3 } ?? text.count
                    continue
                }
                if starts(with: "<!") || starts(with: "<?") {
                    index = find(">").map { $0 + 1 } ?? text.count
                    continue
                }
                let closing = index + 1 < text.count && text[index + 1] == "/"
                var cursor = index + (closing ? 2 : 1)
                let nameStart = cursor
                while cursor < text.count, Self.isNameCharacter(text[cursor]) { cursor += 1 }
                guard cursor > nameStart else { index += 1; continue }
                let name = String(String.UnicodeScalarView(text[nameStart..<cursor])).lowercased()
                index = cursor
                if closing {
                    index = find(">").map { $0 + 1 } ?? text.count
                    return .end(name)
                }
                return .start(name, attributes())
            }
            return nil
        }

        /// The text up to `</name`, which is consumed with its tag.
        mutating func rawText(until name: String) -> String {
            let start = index
            while index < text.count {
                if text[index] == "<", starts(with: "</" + name, caseInsensitive: true) {
                    let raw = String(String.UnicodeScalarView(text[start..<index]))
                    index = find(">").map { $0 + 1 } ?? text.count
                    return raw
                }
                index += 1
            }
            return String(String.UnicodeScalarView(text[start..<text.count]))
        }

        /// Attributes up to the tag's `>`, names lowercased, values entity-decoded. A repeated name keeps its first value.
        private mutating func attributes() -> [String: String] {
            var result: [String: String] = [:]
            while index < text.count {
                let scalar = text[index]
                if scalar == ">" { index += 1; break }
                if scalar.properties.isWhitespace || scalar == "/" { index += 1; continue }
                let nameStart = index
                while index < text.count, !text[index].properties.isWhitespace, !["=", ">", "/"].contains(text[index]) { index += 1 }
                let name = String(String.UnicodeScalarView(text[nameStart..<index])).lowercased()
                skipWhitespace()
                var value = ""
                if index < text.count, text[index] == "=" {
                    index += 1
                    skipWhitespace()
                    if index < text.count, text[index] == "\"" || text[index] == "'" {
                        let quote = text[index]
                        index += 1
                        let valueStart = index
                        while index < text.count, text[index] != quote { index += 1 }
                        value = String(String.UnicodeScalarView(text[valueStart..<index]))
                        index = min(index + 1, text.count)
                    } else {
                        let valueStart = index
                        while index < text.count, !text[index].properties.isWhitespace, text[index] != ">" { index += 1 }
                        value = String(String.UnicodeScalarView(text[valueStart..<index]))
                    }
                }
                if !name.isEmpty, result[name] == nil { result[name] = LinkPreviewHead.decodeEntities(value) }
            }
            return result
        }

        private mutating func skipWhitespace() {
            while index < text.count, text[index].properties.isWhitespace { index += 1 }
        }

        private func starts(with prefix: String, caseInsensitive: Bool = false) -> Bool {
            var cursor = index
            for scalar in prefix.unicodeScalars {
                guard cursor < text.count else { return false }
                let candidate = text[cursor]
                let same = caseInsensitive ? candidate.properties.lowercaseMapping == scalar.properties.lowercaseMapping : candidate == scalar
                guard same else { return false }
                cursor += 1
            }
            return true
        }

        private func find(_ marker: String) -> Int? {
            let scalars = Array(marker.unicodeScalars)
            var cursor = index
            while cursor + scalars.count <= text.count {
                if text[cursor] == scalars[0], Array(text[cursor..<cursor + scalars.count]) == scalars { return cursor }
                cursor += 1
            }
            return nil
        }

        private static func isNameCharacter(_ scalar: Unicode.Scalar) -> Bool {
            scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar == "-" || scalar == ":")
        }
    }
}
