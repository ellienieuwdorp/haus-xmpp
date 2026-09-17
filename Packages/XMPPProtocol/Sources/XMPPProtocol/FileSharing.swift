import CryptoKit
import Foundation

extension MessageContent {
    /// XEP-0447 stateless file sharing with XEP-0446 metadata and, when `key` is set, XEP-0448
    /// encrypted sources (AES-256-GCM, the XEP-0454 cipher). Hashes are raw SHA-256 bytes.
    public struct FileSharing: Sendable, Equatable {
        public static let namespace = "urn:xmpp:sfs:0"
        public static let metadataNamespace = "urn:xmpp:file:metadata:0"
        public static let hashesNamespace = "urn:xmpp:hashes:2"
        public static let encryptedNamespace = "urn:xmpp:esfs:0"
        public static let urlDataNamespace = "http://jabber.org/protocol/url-data"
        public static let cipher = "urn:xmpp:ciphers:aes-256-gcm-nopadding:0"

        public var name: String
        public var mediaType: String
        public var size: Int
        public var width: Int?
        public var height: Int?
        /// SHA-256 of the plaintext file; empty for a legacy `aesgcm://` body, which carries none.
        public var hash: Data
        public var url: String
        public var key: Data?
        public var iv: Data?
        /// SHA-256 of the uploaded ciphertext, when the sender included one.
        public var cipherHash: Data?

        public init(name: String, mediaType: String, size: Int, width: Int? = nil, height: Int? = nil, hash: Data, url: String,
                    key: Data? = nil, iv: Data? = nil, cipherHash: Data? = nil) {
            self.name = name; self.mediaType = mediaType; self.size = size; self.width = width; self.height = height
            self.hash = hash; self.url = url; self.key = key; self.iv = iv; self.cipherHash = cipherHash
        }

        public var isEncrypted: Bool { key != nil }

        /// The legacy (XEP-0454) form a body carries: the https URL with IV and key in the fragment.
        public var aesgcmURL: String? {
            guard let key, let iv, let https = URL(string: url), https.scheme == "https", let host = https.host else { return nil }
            var path = https.path; if let query = https.query { path += "?" + query }
            return "aesgcm://" + host + (https.port.map { ":\($0)" } ?? "") + path + "#" + (iv + key).map { String(format: "%02x", $0) }.joined()
        }

        /// Parses an `aesgcm://` body (12-byte IV, 32-byte key). A 16-byte IV is an older
        /// Conversations form this client does not decrypt; such a body stays plain text.
        public static func fromAESGCMBody(_ body: String) -> FileSharing? {
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("aesgcm://"), !trimmed.contains(where: { $0.isWhitespace }), trimmed.utf8.count <= 2_048,
                  let fragmentStart = trimmed.lastIndex(of: "#") else { return nil }
            let fragment = trimmed[trimmed.index(after: fragmentStart)...]
            guard fragment.count == 88, let material = Data(hex: String(fragment)) else { return nil }
            let https = "https://" + trimmed.dropFirst("aesgcm://".count)[..<fragmentStart]
            guard validURL(https), let url = URL(string: https) else { return nil }
            let name = url.lastPathComponent.isEmpty || url.lastPathComponent == "/" ? "file" : url.lastPathComponent
            return FileSharing(name: name, mediaType: mediaType(forExtension: url.pathExtension), size: 0, hash: Data(), url: https,
                               key: material.suffix(32), iv: material.prefix(12), cipherHash: nil)
        }

        public static func mediaType(forExtension ext: String) -> String {
            switch ext.lowercased() {
            case "jpg", "jpeg": "image/jpeg"
            case "png": "image/png"
            case "gif": "image/gif"
            case "heic": "image/heic"
            case "webp": "image/webp"
            case "mp4", "m4v": "video/mp4"
            case "mov": "video/quicktime"
            case "m4a": "audio/mp4"
            case "mp3": "audio/mpeg"
            case "pdf": "application/pdf"
            default: "application/octet-stream"
            }
        }

        public static func validURL(_ value: String) -> Bool {
            guard value.utf8.count <= 2_048, !value.contains(where: { $0.isWhitespace }), MessageContent.validXMLText(value),
                  let url = URL(string: value), url.scheme == "https", url.host?.isEmpty == false else { return false }
            return true
        }

        func xml() throws -> String {
            guard !name.isEmpty, name.utf8.count <= 255, MessageContent.validXMLText(name), !name.contains("/"),
                  !mediaType.isEmpty, mediaType.utf8.count <= 128, MessageContent.validXMLText(mediaType),
                  size >= 0, hash.count == 32, Self.validURL(url),
                  (key == nil) == (iv == nil), key.map({ $0.count == 32 }) ?? true, iv.map({ $0.count == 12 }) ?? true,
                  cipherHash.map({ $0.count == 32 }) ?? true, cipherHash == nil || key != nil else { throw XMPPClientError.invalidConfiguration }
            var file = "<file xmlns='\(Self.metadataNamespace)'><media-type>\(xmlEscaped(mediaType))</media-type><name>\(xmlEscaped(name))</name><size>\(size)</size>"
            if let width, let height, width > 0, height > 0 { file += "<width>\(width)</width><height>\(height)</height>" }
            file += "<hash xmlns='\(Self.hashesNamespace)' algo='sha-256'>\(hash.base64EncodedString())</hash></file>"
            let urlData = "<url-data xmlns='\(Self.urlDataNamespace)' target='\(xmlEscaped(url))'/>"
            let sources: String
            if let key, let iv {
                sources = "<encrypted xmlns='\(Self.encryptedNamespace)' cipher='\(Self.cipher)'><key>\(key.base64EncodedString())</key><iv>\(iv.base64EncodedString())</iv>"
                    + (cipherHash.map { "<hash xmlns='\(Self.hashesNamespace)' algo='sha-256'>\($0.base64EncodedString())</hash>" } ?? "")
                    + "<sources xmlns='\(Self.namespace)'>\(urlData)</sources></encrypted>"
            } else { sources = urlData }
            return "<file-sharing xmlns='\(Self.namespace)' disposition='inline'>\(file)<sources>\(sources)</sources></file-sharing>"
        }

        /// `nil` when the element is malformed; strict callers treat that as tampering.
        static func decode(_ node: XMLNode) -> FileSharing? {
            guard node.children("file", namespace: metadataNamespace).count == 1, node.children("sources", namespace: namespace).count == 1,
                  let file = node.child("file", namespace: metadataNamespace), let sources = node.child("sources", namespace: namespace) else { return nil }
            func text(_ name: String) -> String? {
                let matches = file.children(name, namespace: metadataNamespace)
                guard matches.count == 1, matches[0].children.isEmpty else { return nil }
                return matches[0].text
            }
            guard let mediaType = text("media-type"), !mediaType.isEmpty, mediaType.utf8.count <= 128,
                  let name = text("name"), !name.isEmpty, name.utf8.count <= 255, !name.contains("/"),
                  let hash = sha256(file) else { return nil }
            let size = text("size").flatMap(Int.init) ?? 0
            guard size >= 0 else { return nil }
            let width = text("width").flatMap(Int.init), height = text("height").flatMap(Int.init)
            var result = FileSharing(name: name, mediaType: mediaType, size: size,
                                     width: width.flatMap { $0 > 0 && $0 <= 65_535 ? $0 : nil }, height: height.flatMap { $0 > 0 && $0 <= 65_535 ? $0 : nil },
                                     hash: hash, url: "")
            let encrypted = sources.children("encrypted", namespace: encryptedNamespace)
            if encrypted.count == 1 {
                let container = encrypted[0]
                guard container.attributes["cipher"] == cipher,
                      let key = base64(container, "key", encryptedNamespace), key.count == 32,
                      let iv = base64(container, "iv", encryptedNamespace), iv.count == 12,
                      container.children("sources", namespace: namespace).count == 1,
                      let inner = container.child("sources", namespace: namespace),
                      let url = url(inner.children("url-data", namespace: urlDataNamespace)) else { return nil }
                if !container.children("hash", namespace: hashesNamespace).isEmpty {
                    guard let cipherHash = sha256(container) else { return nil }
                    result.cipherHash = cipherHash
                }
                result.key = key; result.iv = iv; result.url = url
            } else if encrypted.isEmpty, let url = url(sources.children("url-data", namespace: urlDataNamespace)) {
                result.url = url
            } else { return nil }
            return result
        }

        private static func url(_ candidates: [XMLNode]) -> String? {
            // The first well-formed https source wins; other transports are ignored.
            candidates.compactMap { $0.attributes["target"] }.first(where: validURL)
        }
        private static func sha256(_ parent: XMLNode) -> Data? {
            let hashes = parent.children("hash", namespace: hashesNamespace).filter { $0.attributes["algo"] == "sha-256" }
            guard hashes.count == 1, hashes[0].children.isEmpty,
                  let data = Data(base64Encoded: hashes[0].text.filter { !$0.isWhitespace }), data.count == 32 else { return nil }
            return data
        }
        private static func base64(_ parent: XMLNode, _ name: String, _ namespace: String) -> Data? {
            let matches = parent.children(name, namespace: namespace)
            guard matches.count == 1, matches[0].children.isEmpty else { return nil }
            return Data(base64Encoded: matches[0].text.filter { !$0.isWhitespace })
        }
    }
}

extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte); index = next
        }
        self.init(bytes)
    }
    public static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    public var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
