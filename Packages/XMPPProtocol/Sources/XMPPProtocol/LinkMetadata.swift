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
