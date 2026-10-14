import Foundation

extension MessageContent {
    /// XEP-0511 link metadata about one link in the body: an RDF `<Description rdf:about=…>` with OpenGraph children.
    /// It travels only inside an authenticated SCE `<content/>` (modern OMEMO, direct and group); legacy OMEMO and
    /// plaintext carry none. See docs/development/link-previews.md for the wire form and the receive rules.
    public struct LinkMetadata: Sendable, Equatable {
        public static let rdfNamespace = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
        public static let openGraphNamespace = "https://ogp.me/ns#"
        /// `og:image:alt` as XML: local name `alt` in this namespace (the XEP's `ogi:` prefix).
        public static let openGraphImageNamespace = "https://ogp.me/ns#image:"

        /// Receive bounds. A Description that breaks one drops all link metadata of its message; the text stays.
        public static let maximumDescriptions = 4
        public static let maximumTitleBytes = 1_024
        public static let maximumDescriptionBytes = 2_048
        public static let maximumImageAltBytes = 512
        /// Decoded bytes of an embedded image we accept. The base64 length is checked against this before decoding.
        public static let maximumImageBytes = 65_536
        /// Decoded bytes of the thumbnail we send (JPEG, within 400 px, else 256 px, else no image).
        public static let maximumSentImageBytes = 24_576
        /// `data:image/<subtype>;base64,` subtypes accepted on receive. We send only `image/jpeg`.
        public static let imageMediaTypes: Set<String> = ["image/jpeg", "image/png", "image/webp", "image/gif", "image/heic"]

        /// An `og:image`. Version 1 carries only an embedded `data:` image; remote URLs, `cid:` and `ni:` are ignored.
        public enum Image: Sendable, Equatable {
            /// `data:<type>;base64,<bytes>`, `type` one of `imageMediaTypes`.
            case data(type: String, bytes: Data)
        }

        /// `rdf:about`: exactly a previewable URL of the body (`LinkDetection.previewableURLs`), as its `absoluteString`.
        public var about: String
        public var title: String?
        /// `og:description`.
        public var description: String?
        public var image: Image?
        /// `og:image:alt`.
        public var imageAlt: String?

        public init(about: String, title: String? = nil, description: String? = nil, image: Image? = nil, imageAlt: String? = nil) {
            self.about = about; self.title = title; self.description = description; self.image = image; self.imageAlt = imageAlt
        }

        /// Card text as plain text: C0 and C1 controls and bidi embedding, override and isolate characters removed,
        /// runs of whitespace (newlines included) collapsed to one space, trimmed. Nil when nothing is left.
        /// Callers apply their own byte caps afterwards (receive drops an over-cap field, the fetcher shortens it).
        public static func plainText(_ text: String) -> String? {
            var result = String.UnicodeScalarView()
            var pendingSpace = false
            for scalar in text.unicodeScalars {
                if scalar.properties.isWhitespace || scalar == "\u{2028}" || scalar == "\u{2029}" {
                    pendingSpace = !result.isEmpty
                    continue
                }
                if isRemoved(scalar) { continue }
                if pendingSpace { result.append(" "); pendingSpace = false }
                result.append(scalar)
            }
            return result.isEmpty ? nil : String(result)
        }

        private static func isRemoved(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar.value {
            case 0x00...0x1F, 0x7F...0x9F: true
            // LRM, RLM, ALM, LRE…RLO, LRI…PDI.
            case 0x200E, 0x200F, 0x061C, 0x202A...0x202E, 0x2066...0x2069: true
            default: false
            }
        }
    }
}

// MARK: Codec

extension MessageContent.LinkMetadata {
    /// At most this many children per `<Description/>`; more is a malformed Description.
    static let maximumChildren = 16
    /// `ceil(maximumImageBytes / 3) * 4`: the longest base64 text that can decode within the image cap.
    static let maximumImageBase64Length = (maximumImageBytes + 2) / 3 * 4

    /// The Description as we send it: the form slixmpp, nbxmpp and Cheogram emit, with unprefixed OpenGraph children.
    /// Texts go out as `plainText` gives them; callers send only metadata that `validated(_:body:)` accepted.
    func xml() -> String {
        let rdf = Self.rdfNamespace, og = Self.openGraphNamespace
        var xml = "<Description xmlns='\(rdf)' xmlns:rdf='\(rdf)' rdf:about='\(xmlEscaped(about))'>"
        if let title = title.flatMap(Self.plainText) { xml += "<title xmlns='\(og)'>\(xmlEscaped(title))</title>" }
        if let description = description.flatMap(Self.plainText) { xml += "<description xmlns='\(og)'>\(xmlEscaped(description))</description>" }
        if case let .data(type, bytes)? = image {
            xml += "<image xmlns='\(og)'>data:\(type);base64,\(bytes.base64EncodedString())</image>"
            if let alt = imageAlt.flatMap(Self.plainText) { xml += "<alt xmlns='\(Self.openGraphImageNamespace)'>\(xmlEscaped(alt))</alt>" }
        }
        return xml + "</Description>"
    }

    /// `metadata` as it may be sent with `body` (the text after any reply quote): texts as `plainText`, an alt only with
    /// its image, and only when every entry passes the rules a receiver applies (`decode`). Anything else gives `[]`,
    /// so a peer never receives metadata it would drop, and the caller can tell the preview did not ride along.
    static func validated(_ metadata: [Self], body: String) -> [Self] {
        guard !metadata.isEmpty, !body.isEmpty, metadata.count <= maximumDescriptions,
              Set(metadata.map(\.about)).count == metadata.count else { return [] }
        let previewable = Set(LinkDetection.previewableURLs(in: body).map(\.absoluteString))
        var result: [Self] = []
        for entry in metadata {
            guard previewable.contains(entry.about), MessageContent.validXMLText(entry.about) else { return [] }
            var clean = Self(about: entry.about)
            clean.title = entry.title.flatMap(Self.plainText)
            clean.description = entry.description.flatMap(Self.plainText)
            if case let .data(type, bytes)? = entry.image {
                guard imageMediaTypes.contains(type), !bytes.isEmpty, bytes.count <= maximumImageBytes else { return [] }
                clean.image = entry.image
                clean.imageAlt = entry.imageAlt.flatMap(Self.plainText)
            }
            guard clean.title != nil || clean.image != nil,
                  (clean.title?.utf8.count ?? 0) <= maximumTitleBytes, (clean.description?.utf8.count ?? 0) <= maximumDescriptionBytes,
                  (clean.imageAlt?.utf8.count ?? 0) <= maximumImageAltBytes,
                  [clean.title, clean.description, clean.imageAlt].allSatisfy({ $0.map(MessageContent.validXMLText) ?? true }) else { return [] }
            result.append(clean)
        }
        return result
    }

    /// The link metadata of authenticated `<content/>` (`node`) whose body after any reply quote is `body`, in the
    /// order its links appear in the body. A Description must be about a previewable link of `body` (`rdf:about` read
    /// by namespace, any prefix), and texts and the embedded image must keep within the receive bounds. Any broken
    /// rule drops every Description of the message (an empty result) and never the message itself. A Description with
    /// neither title nor image is ignored; remote, `cid:` and `ni:` images are ignored. Several languages for one link:
    /// the first in `preferredLanguages` order, else the first given.
    static func decode(in node: XMLNode, body: String, preferredLanguages: [String] = Locale.preferredLanguages) -> [Self] {
        let descriptions = node.children("Description", namespace: rdfNamespace)
        guard !descriptions.isEmpty, !body.isEmpty, descriptions.count <= maximumDescriptions else { return [] }
        let previewable = LinkDetection.previewableURLs(in: body).map(\.absoluteString)
        var candidates: [(language: String?, metadata: Self?)] = []
        var seen = Set<String>()
        for description in descriptions {
            guard let about = description.attribute("about", namespace: rdfNamespace), previewable.contains(about),
                  description.attributes["about"].map({ $0 == about }) ?? true,
                  description.children.count <= maximumChildren else { return [] }
            let language = description.attributes["xml:lang"]
            guard seen.insert(about + "\u{0}" + (language ?? "")).inserted else { return [] }
            guard let decoded = decodeProperties(of: description, about: about) else { return [] }
            candidates.append((language, decoded))
        }
        let languages = preferredLanguages.map { $0.lowercased() }
        func rank(_ language: String?) -> Int {
            guard let language = language?.lowercased() else { return languages.count }
            let primary = language.split(separator: "-").first.map(String.init) ?? language
            return languages.firstIndex { $0 == language || $0.hasPrefix(primary + "-") || $0 == primary } ?? languages.count + 1
        }
        return previewable.compactMap { url in
            candidates.filter { $0.metadata?.about == url }
                .enumerated().min { (rank($0.element.language), $0.offset) < (rank($1.element.language), $1.offset) }?.element.metadata
        }
    }

    /// Nil when the Description breaks a rule; `.some(nil)` when it only has nothing to show (no title, no image).
    private static func decodeProperties(of description: XMLNode, about: String) -> Self?? {
        var result = Self(about: about)
        var seen = Set<String>()
        for child in description.children {
            let property: WritableKeyPath<Self, String?>?
            let cap: Int
            switch (child.namespace, child.name) {
            case (openGraphNamespace, "title"): property = \.title; cap = maximumTitleBytes
            case (openGraphNamespace, "description"): property = \.description; cap = maximumDescriptionBytes
            case (openGraphImageNamespace, "alt"): property = \.imageAlt; cap = maximumImageAltBytes
            case (openGraphNamespace, "image"): property = nil; cap = 0
            default: continue
            }
            // Each property read is one leaf; a repeat is ambiguous.
            guard child.children.isEmpty, seen.insert(child.namespace + child.name).inserted else { return nil }
            if let property {
                let text = plainText(child.text)
                guard (text?.utf8.count ?? 0) <= cap else { return nil }
                result[keyPath: property] = text
            } else {
                switch embeddedImage(child.text) {
                case .malformed: return nil
                case .ignored: break
                case .image(let image): result.image = image
                }
            }
        }
        if result.image == nil { result.imageAlt = nil }
        guard result.title != nil || result.image != nil else { return .some(nil) }
        return result
    }

    private enum ImageValue { case image(Image), ignored, malformed }

    /// `data:image/<type>;base64,<payload>` within the bounds. Another scheme (a remote URL, `cid:`, `ni:`) or media
    /// type is ignored; a `data:` image whose base64 is broken, empty or over the cap breaks the Description.
    private static func embeddedImage(_ text: String) -> ImageValue {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.prefix(5).lowercased() == "data:" else { return .ignored }
        guard let comma = value.firstIndex(of: ",") else { return .malformed }
        let header = value[value.index(value.startIndex, offsetBy: 5)..<comma].lowercased().split(separator: ";").map(String.init)
        guard let type = header.first, imageMediaTypes.contains(type), header.dropFirst() == ["base64"] else { return .ignored }
        // Line breaks inside base64 are tolerated; the length is checked before anything is decoded.
        let compact = String(value[value.index(after: comma)...].unicodeScalars.filter { !$0.properties.isWhitespace })
        guard compact.utf8.count <= maximumImageBase64Length, let bytes = Data(base64Encoded: compact),
              !bytes.isEmpty, bytes.count <= maximumImageBytes else { return .malformed }
        return .image(.data(type: type, bytes: bytes))
    }
}
