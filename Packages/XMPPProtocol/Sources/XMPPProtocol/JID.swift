import Foundation

/// An RFC 7622 address in normal form: the one spelling every key and comparison in this client uses. Parse input once
/// at the boundary (sign-in, a typed contact or room, a stanza off the wire) and keep the result; two addresses name
/// the same entity exactly when their normal forms are equal.
///
/// - Localpart: the PRECIS UsernameCaseMapped rules of RFC 8265 §3.3 without the bidi rule and without the
///   IdentifierClass letter/digit restriction. Fullwidth and halfwidth forms are width-mapped, the result lowercased
///   (Unicode toLowerCase) and NFC-normalised. Rejected: controls, spaces, default-ignorable and unassigned code
///   points, noncharacters, and the RFC 7622 §3.3.1 characters `" & ' / : < > @`.
/// - Domainpart: width-mapped, lowercased, NFC, one trailing dot removed (RFC 7622 §3.2). No IDNA conversion, so an
///   A-label and its U-label stay different spellings. Empty labels, spaces, controls and `@ / \ " & ' < > :` are
///   rejected, except inside a bracketed IP literal.
/// - Resourcepart: untouched (compared byte for byte). Only an empty resource and controls are rejected.
///
/// Each part is limited to 1023 UTF-8 bytes (RFC 7622 §3.1).
public struct JID: Hashable, Sendable, CustomStringConvertible {
    public let localpart: String?
    public let domainpart: String
    public let resourcepart: String?

    public static let maximumPartBytes = 1023

    public init?(_ string: String) {
        // RFC 7622 §3.1: the first '/' starts the resource; the first '@' before it ends the localpart.
        let slash = string.firstIndex(of: "/")
        let bare = slash.map { string[..<$0] } ?? Substring(string)
        let resource = slash.map { String(string[string.index(after: $0)...]) }
        let at = bare.firstIndex(of: "@")
        let local = at.map { String(bare[..<$0]) }
        let domain = String(at.map { bare[bare.index(after: $0)...] } ?? bare)
        self.init(localpart: local, domainpart: domain, resourcepart: resource)
    }

    public init?(localpart: String?, domainpart: String, resourcepart: String? = nil) {
        if let localpart {
            guard let normal = Self.normalizedLocalpart(localpart) else { return nil }
            self.localpart = normal
        } else { self.localpart = nil }
        guard let domain = Self.normalizedDomainpart(domainpart) else { return nil }
        self.domainpart = domain
        if let resourcepart {
            guard !resourcepart.isEmpty, resourcepart.utf8.count <= Self.maximumPartBytes,
                  resourcepart.unicodeScalars.allSatisfy({ $0.properties.generalCategory != .control }) else { return nil }
        }
        self.resourcepart = resourcepart
    }

    /// `local@domain` or `domain`.
    public var bare: String { localpart.map { $0 + "@" + domainpart } ?? domainpart }
    public var full: String { resourcepart.map { bare + "/" + $0 } ?? bare }
    public var description: String { full }

    /// The normal form of any address (bare or full, with or without a localpart), or nil when it is not a valid JID.
    public static func normalized(_ string: String) -> String? { JID(string)?.full }

    /// The normal bare form of an address that has a localpart (a user or a room), or nil.
    public static func normalizedBare(_ string: String) -> String? {
        guard let jid = JID(string), jid.localpart != nil else { return nil }
        return jid.bare
    }

    public static func normalizedLocalpart(_ value: String) -> String? {
        let mapped = mapped(value)
        guard !mapped.isEmpty, mapped.utf8.count <= maximumPartBytes,
              mapped.unicodeScalars.allSatisfy({ allowed($0) && !"\"&'/:<>@".unicodeScalars.contains($0) }) else { return nil }
        return mapped
    }

    public static func normalizedDomainpart(_ value: String) -> String? {
        var mapped = mapped(value)
        if mapped.hasSuffix("."), mapped.count > 1 { mapped.removeLast() }
        guard !mapped.isEmpty, mapped.utf8.count <= maximumPartBytes else { return nil }
        if mapped.hasPrefix("[") {
            // An IP literal (RFC 7622 §3.2): only hex digits, dots and colons inside the brackets.
            guard mapped.hasSuffix("]"), mapped.count > 2,
                  mapped.dropFirst().dropLast().allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." }) else { return nil }
            return mapped
        }
        guard mapped.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0.utf8.count <= 63 }),
              mapped.unicodeScalars.allSatisfy({ allowed($0) && !"\"&'/:<>@\\".unicodeScalars.contains($0) }) else { return nil }
        return mapped
    }

    /// Width mapping, then toLowerCase, then NFC (RFC 8265 §3.3.2 steps 1, 3 and 4).
    private static func mapped(_ value: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            // PRECIS width mapping (RFC 8264 §9.2): every `<wide>` and `<narrow>` decomposition lives in the Halfwidth
            // and Fullwidth Forms block, apart from U+3000, a space that is rejected anyway.
            if (0xFF01...0xFFEF).contains(scalar.value) {
                scalars.append(contentsOf: String(scalar).precomposedStringWithCompatibilityMapping.unicodeScalars)
            } else { scalars.append(scalar) }
        }
        return String(scalars).lowercased().precomposedStringWithCanonicalMapping
    }

    private static func allowed(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .surrogate, .unassigned, .spaceSeparator, .lineSeparator, .paragraphSeparator: return false
        default: return !scalar.properties.isDefaultIgnorableCodePoint && !scalar.properties.isNoncharacterCodePoint
        }
    }

    /// The stanza with the `from` and `to` of every `jabber:client` message, presence and iq in it (the stanza itself
    /// and anything forwarded inside it: carbons, archive results) in normal form. An address that is not a valid JID
    /// is left as it is, so the parsers that follow reject it as before.
    static func normalizingAddresses(_ node: XMLNode) -> XMLNode {
        var attributes = node.attributes
        if node.namespace == "jabber:client", ["message", "presence", "iq"].contains(node.name) {
            for key in ["from", "to"] { if let value = attributes[key], let normal = normalized(value) { attributes[key] = normal } }
        }
        return XMLNode(name: node.name, namespace: node.namespace, attributes: attributes, text: node.text,
                       children: node.children.map(normalizingAddresses), attributePrefixes: node.attributePrefixes)
    }
}

/// The server bound a different account than the one that signed in (RFC 6120 §7.7 lets it choose the resource,
/// never the bare JID). The session ends instead of adopting it.
public enum XMPPIdentityError: Error, Sendable, Equatable {
    case boundAccountMismatch
}
