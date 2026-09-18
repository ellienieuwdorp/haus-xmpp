import CryptoKit
import Foundation

/// XEP-0084 metadata for one published avatar; `id` is the SHA-1 of the bytes and names the data item.
public struct XMPPAvatarMetadata: Sendable, Equatable {
    public let id: String
    public let type: String
    public let bytes: Int
    public init(id: String, type: String, bytes: Int) { self.id = id; self.type = type; self.bytes = bytes }
}

/// XEP-0084 (PEP) and XEP-0153/0054 (vCard) avatar payloads. Bytes are attacker-controlled: only
/// raster types, a size cap and a hash that matches the advertised id get through.
public enum AvatarWire {
    public static let metadataNode = "urn:xmpp:avatar:metadata"
    public static let dataNode = "urn:xmpp:avatar:data"
    public static let vcardNamespace = "vcard-temp"
    public static let maximumBytes = 512 * 1_024
    public static let types: Set<String> = ["image/png", "image/jpeg", "image/gif"]

    /// The first usable inline (`url`-less) info; nil for an empty `<metadata/>`, which means "no avatar".
    static func parseMetadata(_ metadata: XMLNode) throws -> XMPPAvatarMetadata? {
        guard metadata.name == "metadata", metadata.namespace == metadataNode else { throw XMPPIQError.malformedResponse }
        let infos = metadata.children.filter { $0.name == "info" && $0.namespace == metadataNode }
        guard infos.count <= 32 else { throw XMPPIQError.malformedResponse }
        return infos.lazy.compactMap { info -> XMPPAvatarMetadata? in
            guard info.attributes["url"] == nil, let id = info.attributes["id"], validHash(id),
                  let type = info.attributes["type"]?.lowercased(), types.contains(type),
                  let bytes = info.attributes["bytes"].flatMap(Int.init), bytes > 0, bytes <= maximumBytes else { return nil }
            return XMPPAvatarMetadata(id: id.lowercased(), type: type, bytes: bytes)
        }.first
    }

    static func parseData(_ data: XMLNode) throws -> Data {
        guard data.name == "data", data.namespace == dataNode, data.children.isEmpty else { throw XMPPIQError.malformedResponse }
        return try decodeBase64(data.text)
    }

    /// `<PHOTO><TYPE/><BINVAL/></PHOTO>` from a vCard; nil when the card carries no usable photo.
    static func parseVCardPhoto(_ vcard: XMLNode) throws -> (type: String, data: Data)? {
        guard vcard.name == "vCard", vcard.namespace == vcardNamespace else { throw XMPPIQError.malformedResponse }
        guard let photo = vcard.child("PHOTO", namespace: vcardNamespace),
              let type = photo.child("TYPE", namespace: vcardNamespace)?.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              types.contains(type), let binval = photo.child("BINVAL", namespace: vcardNamespace) else { return nil }
        return (type, try decodeBase64(binval.text))
    }

    public static func hash(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func validHash(_ id: String) -> Bool { id.count == 40 && id.allSatisfy(\.isHexDigit) }

    private static func decodeBase64(_ text: String) throws -> Data {
        guard text.utf8.count <= maximumBytes * 4 / 3 + 4_096,
              let data = Data(base64Encoded: text.filter { !$0.isWhitespace }), !data.isEmpty, data.count <= maximumBytes else {
            throw XMPPIQError.malformedResponse
        }
        return data
    }
}
