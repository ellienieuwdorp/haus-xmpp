import Foundation

/// These profiles have different key derivation and payload formats. Never relabel ciphertext.
public enum XMPPOMEMOProfile: String, Sendable, Codable, CaseIterable {
    case legacy, modern

    public var namespace: String {
        self == .legacy ? "eu.siacs.conversations.axolotl" : "urn:xmpp:omemo:2"
    }
    public var devicesNode: String { self == .legacy ? namespace + ".devicelist" : namespace + ":devices" }
    public func bundlesNode(deviceID: UInt32) -> String {
        self == .legacy ? namespace + ".bundles:\(deviceID)" : namespace + ":bundles"
    }
}

public struct XMPPOMEMOBundle: Sendable, Equatable, Codable {
    public let profile: XMPPOMEMOProfile
    public let deviceID: UInt32
    public let identityKey: Data
    public let signedPreKeyID: UInt32
    public let signedPreKey: Data
    public let signedPreKeySignature: Data
    public let preKeys: [UInt32: Data]

    public init(profile: XMPPOMEMOProfile, deviceID: UInt32, identityKey: Data, signedPreKeyID: UInt32,
                signedPreKey: Data, signedPreKeySignature: Data, preKeys: [UInt32: Data]) {
        self.profile = profile; self.deviceID = deviceID; self.identityKey = identityKey
        self.signedPreKeyID = signedPreKeyID; self.signedPreKey = signedPreKey
        self.signedPreKeySignature = signedPreKeySignature; self.preKeys = preKeys
    }
}

public struct XMPPOMEMOKey: Sendable, Equatable, Codable {
    /// Modern OMEMO scopes recipient device IDs to a bare JID. Legacy headers do not carry this field.
    public let recipientJID: String?
    public let deviceID: UInt32
    public let keyExchange: Bool
    public let data: Data

    public init(recipientJID: String? = nil, deviceID: UInt32, keyExchange: Bool, data: Data) {
        self.recipientJID = recipientJID; self.deviceID = deviceID; self.keyExchange = keyExchange; self.data = data
    }
}

public struct XMPPOMEMOEnvelope: Sendable, Equatable, Codable {
    public let profile: XMPPOMEMOProfile
    public let senderDeviceID: UInt32
    public let keys: [XMPPOMEMOKey]
    public let iv: Data?
    /// Nil is a session-management/key-transport message, not an empty plaintext message.
    public let payload: Data?

    public init(profile: XMPPOMEMOProfile, senderDeviceID: UInt32, keys: [XMPPOMEMOKey], iv: Data? = nil, payload: Data?) {
        self.profile = profile; self.senderDeviceID = senderDeviceID; self.keys = keys; self.iv = iv; self.payload = payload
    }
}

public struct XMPPEncryptedMessage: Sendable, Equatable {
    public let id: String
    public let from: String
    public let to: String?
    public let originID: String?
    public let envelope: XMPPOMEMOEnvelope
    public let provenance: XMPPMessageProvenance
    /// Unencrypted outer `<request/>` / `<markable/>`: the sender wants a receipt or read marker back.
    public var requestsReceipt = false
    public var markable = false
    /// Unencrypted outer `<body/>` (the XEP-0384 fallback text): a content hint only, never shown and never authenticated.
    /// It tells an exclusion that the envelope would have been a message bubble rather than a reaction or receipt.
    public var hasFallbackBody = false
    /// Untrusted XEP-0308 reference outside the ciphertext, the only place legacy OMEMO can carry it.
    public var replaces: String? = nil

    public init(id: String, from: String, to: String?, originID: String?, envelope: XMPPOMEMOEnvelope, provenance: XMPPMessageProvenance = .direct,
                requestsReceipt: Bool = false, markable: Bool = false, hasFallbackBody: Bool = false, replaces: String? = nil) {
        self.id = id; self.from = from; self.to = to; self.originID = originID; self.envelope = envelope; self.provenance = provenance
        self.requestsReceipt = requestsReceipt; self.markable = markable; self.hasFallbackBody = hasFallbackBody; self.replaces = replaces
    }
}

public enum XMPPIQError: Error, Sendable, Equatable {
    case stanza(condition: String)
    case malformedResponse
    case requestLimit
}

/// Pure bounded OMEMO XML codecs. Signature verification and trust are the crypto package's responsibility.
enum OMEMOWire {
    static let pubsub = "http://jabber.org/protocol/pubsub"
    static let eventNamespace = pubsub + "#event"
    static let maximumDevices = 512
    static let maximumKeys = 1_024

    static func validID(_ id: UInt32) -> Bool { id > 0 && id <= UInt32(Int32.max) }
    static func id(_ text: String?) throws -> UInt32 {
        guard let text, !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
              let result = UInt32(text), validID(result) else { throw XMPPIQError.malformedResponse }
        return result
    }
    static func bareJID(_ jid: String) -> String? {
        guard !jid.isEmpty, jid.utf8.count <= 3_071, !jid.contains(where: { $0.isWhitespace || $0.isNewline }),
              jid.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f && $0.value != 0xfffe && $0.value != 0xffff }) else { return nil }
        let bare = String(jid.prefix { $0 != "/" })
        let pieces = bare.split(separator: "@", omittingEmptySubsequences: false)
        guard pieces.count == 2, !pieces[0].isEmpty, !pieces[1].isEmpty else { return nil }
        return bare
    }
    static func singleton(_ parent: XMLNode, _ name: String, _ namespace: String) throws -> XMLNode {
        let matches = parent.children.filter { $0.name == name && $0.namespace == namespace }
        guard matches.count == 1 else { throw XMPPIQError.malformedResponse }
        return matches[0]
    }
    static func binary(_ node: XMLNode, maximum: Int = 16_384) throws -> Data {
        guard node.children.isEmpty, node.text.utf8.count <= maximum * 2 else { throw XMPPIQError.malformedResponse }
        let text = node.text.filter { ![" ", "\n", "\r", "\t"].contains($0) }
        guard let data = Data(base64Encoded: text), !data.isEmpty, data.count <= maximum else { throw XMPPIQError.malformedResponse }
        return data
    }
    static func boolean(_ value: String?) throws -> Bool {
        switch value {
        case nil, "false", "0": return false
        case "true", "1": return true
        default: throw XMPPIQError.malformedResponse
        }
    }
    static func validate(_ bundle: XMPPOMEMOBundle) throws {
        let length = bundle.profile == .legacy ? 33 : 32
        guard validID(bundle.deviceID), validID(bundle.signedPreKeyID), bundle.identityKey.count == length,
              bundle.signedPreKey.count == length, bundle.signedPreKeySignature.count == 64,
              !bundle.preKeys.isEmpty, bundle.preKeys.count <= 1_000,
              bundle.preKeys.allSatisfy({ validID($0.key) && $0.value.count == length }),
              bundle.profile == .legacy || bundle.preKeys.count >= 25 else { throw XMPPIQError.malformedResponse }
        if bundle.profile == .legacy {
            guard bundle.identityKey.first == 5, bundle.signedPreKey.first == 5,
                  bundle.preKeys.values.allSatisfy({ $0.first == 5 }) else { throw XMPPIQError.malformedResponse }
        }
    }
    static func validate(_ envelope: XMPPOMEMOEnvelope) throws {
        guard validID(envelope.senderDeviceID), !envelope.keys.isEmpty, envelope.keys.count <= maximumKeys,
              envelope.payload.map({ !$0.isEmpty && $0.count <= 524_288 }) ?? true else { throw XMPPIQError.malformedResponse }
        if envelope.profile == .legacy {
            guard envelope.iv?.count == 12 || envelope.iv?.count == 16 else { throw XMPPIQError.malformedResponse }
        } else if envelope.iv != nil { throw XMPPIQError.malformedResponse }
        var seen: Set<String> = []
        for key in envelope.keys {
            guard validID(key.deviceID), !key.data.isEmpty, key.data.count <= 16_384 else { throw XMPPIQError.malformedResponse }
            if envelope.profile == .modern {
                guard let jid = key.recipientJID, bareJID(jid) == jid else { throw XMPPIQError.malformedResponse }
            } else if key.recipientJID != nil { throw XMPPIQError.malformedResponse }
            guard seen.insert("\(key.recipientJID ?? "")/\(key.deviceID)").inserted else { throw XMPPIQError.malformedResponse }
        }
    }
    static func devicesXML(_ devices: [UInt32], profile: XMPPOMEMOProfile) throws -> String {
        guard devices.count <= maximumDevices, Set(devices).count == devices.count, devices.allSatisfy(validID) else { throw XMPPIQError.malformedResponse }
        let name = profile == .legacy ? "list" : "devices"
        return "<\(name) xmlns='\(profile.namespace)'>" + devices.sorted().map { "<device id='\($0)'/>" }.joined() + "</\(name)>"
    }
    static func parseDevices(_ node: XMLNode, profile: XMPPOMEMOProfile) throws -> [UInt32] {
        guard node.name == (profile == .legacy ? "list" : "devices"), node.namespace == profile.namespace,
              node.children.count <= maximumDevices, node.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw XMPPIQError.malformedResponse }
        let values = try node.children.map { child in
            guard child.name == "device", child.namespace == profile.namespace, child.children.isEmpty,
                  child.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw XMPPIQError.malformedResponse }
            // Never surface a server-controlled label before its signature has been verified.
            return try id(child.attributes["id"])
        }
        guard Set(values).count == values.count else { throw XMPPIQError.malformedResponse }
        return values.sorted()
    }
    static func bundleXML(_ bundle: XMPPOMEMOBundle) throws -> String {
        try validate(bundle)
        let legacy = bundle.profile == .legacy
        let spk = legacy ? "signedPreKeyPublic" : "spk"
        let sig = legacy ? "signedPreKeySignature" : "spks"
        let ik = legacy ? "identityKey" : "ik"
        let pk = legacy ? "preKeyPublic" : "pk"
        let spkID = legacy ? "signedPreKeyId" : "id"
        let pkID = legacy ? "preKeyId" : "id"
        let prekeys = bundle.preKeys.sorted { $0.key < $1.key }.map { "<\(pk) \(pkID)='\($0.key)'>\($0.value.base64EncodedString())</\(pk)>" }.joined()
        return "<bundle xmlns='\(bundle.profile.namespace)'><\(spk) \(spkID)='\(bundle.signedPreKeyID)'>\(bundle.signedPreKey.base64EncodedString())</\(spk)><\(sig)>\(bundle.signedPreKeySignature.base64EncodedString())</\(sig)><\(ik)>\(bundle.identityKey.base64EncodedString())</\(ik)><prekeys>\(prekeys)</prekeys></bundle>"
    }
    static func parseBundle(_ node: XMLNode, deviceID: UInt32, profile: XMPPOMEMOProfile) throws -> XMPPOMEMOBundle {
        guard node.name == "bundle", node.namespace == profile.namespace, node.children.count == 4 else { throw XMPPIQError.malformedResponse }
        let legacy = profile == .legacy, ns = profile.namespace
        let spk = try singleton(node, legacy ? "signedPreKeyPublic" : "spk", ns)
        let sig = try singleton(node, legacy ? "signedPreKeySignature" : "spks", ns)
        let ik = try singleton(node, legacy ? "identityKey" : "ik", ns)
        let prekeys = try singleton(node, "prekeys", ns)
        guard prekeys.children.count <= 1_000 else { throw XMPPIQError.malformedResponse }
        var keys: [UInt32: Data] = [:]
        for key in prekeys.children {
            guard key.name == (legacy ? "preKeyPublic" : "pk"), key.namespace == ns else { throw XMPPIQError.malformedResponse }
            let keyID = try id(key.attributes[legacy ? "preKeyId" : "id"])
            guard keys[keyID] == nil else { throw XMPPIQError.malformedResponse }
            keys[keyID] = try binary(key, maximum: 33)
        }
        let bundle = XMPPOMEMOBundle(profile: profile, deviceID: deviceID, identityKey: try binary(ik, maximum: 33),
                                    signedPreKeyID: try id(spk.attributes[legacy ? "signedPreKeyId" : "id"]),
                                    signedPreKey: try binary(spk, maximum: 33), signedPreKeySignature: try binary(sig, maximum: 64), preKeys: keys)
        try validate(bundle)
        return bundle
    }
    static func envelopeXML(_ envelope: XMPPOMEMOEnvelope) throws -> String {
        try validate(envelope)
        let legacy = envelope.profile == .legacy
        func keyXML(_ key: XMPPOMEMOKey) -> String {
            "<key rid='\(key.deviceID)'" + (key.keyExchange ? " \(legacy ? "prekey" : "kex")='true'" : "") + ">\(key.data.base64EncodedString())</key>"
        }
        var keys = ""
        if legacy { keys = envelope.keys.map(keyXML).joined() }
        else {
            let groups = Dictionary(grouping: envelope.keys, by: { $0.recipientJID! })
            keys = groups.keys.sorted().map { jid in
                "<keys jid='\(xmlEscaped(jid))'>" + groups[jid]!.sorted { $0.deviceID < $1.deviceID }.map(keyXML).joined() + "</keys>"
            }.joined()
        }
        let iv = envelope.iv.map { "<iv>\($0.base64EncodedString())</iv>" } ?? ""
        let payload = envelope.payload.map { "<payload>\($0.base64EncodedString())</payload>" } ?? ""
        return "<encrypted xmlns='\(envelope.profile.namespace)'><header sid='\(envelope.senderDeviceID)'>\(keys)\(iv)</header>\(payload)</encrypted>"
    }
    static func parseEnvelope(_ node: XMLNode) throws -> XMPPOMEMOEnvelope {
        guard node.name == "encrypted", let profile = XMPPOMEMOProfile.allCases.first(where: { $0.namespace == node.namespace }),
              (1...2).contains(node.children.count) else { throw XMPPIQError.malformedResponse }
        let ns = profile.namespace, legacy = profile == .legacy
        let header = try singleton(node, "header", ns)
        let payloads = node.children.filter { $0.name == "payload" && $0.namespace == ns }
        guard payloads.count <= 1, node.children.count == 1 + payloads.count,
              header.children.count <= maximumKeys + 1 else { throw XMPPIQError.malformedResponse }
        var keys: [XMPPOMEMOKey] = []
        func parseKey(_ node: XMLNode, jid: String?) throws -> XMPPOMEMOKey {
            guard node.name == "key", node.namespace == ns else { throw XMPPIQError.malformedResponse }
            return XMPPOMEMOKey(recipientJID: jid, deviceID: try id(node.attributes["rid"]),
                                keyExchange: try boolean(node.attributes[legacy ? "prekey" : "kex"]), data: try binary(node))
        }
        var iv: Data?
        if legacy {
            iv = try binary(singleton(header, "iv", ns), maximum: 16)
            for child in header.children where child.name != "iv" || child.namespace != ns { keys.append(try parseKey(child, jid: nil)) }
        } else {
            var groups: Set<String> = []
            for group in header.children {
                guard group.name == "keys", group.namespace == ns, let jid = group.attributes["jid"], bareJID(jid) == jid,
                      groups.insert(jid).inserted, !group.children.isEmpty,
                      keys.count + group.children.count <= maximumKeys else { throw XMPPIQError.malformedResponse }
                for child in group.children { keys.append(try parseKey(child, jid: jid)) }
            }
        }
        let envelope = XMPPOMEMOEnvelope(profile: profile, senderDeviceID: try id(header.attributes["sid"]), keys: keys,
                                         iv: iv, payload: try payloads.first.map { try binary($0, maximum: 524_288) })
        try validate(envelope)
        return envelope
    }
    static func hasEncryptedContent(_ node: XMLNode) -> Bool {
        node.children.contains { ($0.name == "encrypted" && ($0.namespace == XMPPOMEMOProfile.legacy.namespace || $0.namespace.hasPrefix("urn:xmpp:omemo:"))) || ($0.name == "encryption" && $0.namespace == "urn:xmpp:eme:0") }
    }
    static func parseMessage(_ node: XMLNode, provenance: XMPPMessageProvenance = .direct) throws -> XMPPEncryptedMessage {
        guard node.name == "message", node.namespace == "jabber:client", let from = node.attributes["from"], bareJID(from) != nil,
              node.attributes["type"] == nil || ["chat", "normal"].contains(node.attributes["type"]!),
              node.children.filter({ $0.name == "encrypted" }).count == 1,
              let encrypted = node.children.first(where: { $0.name == "encrypted" }) else { throw XMPPIQError.malformedResponse }
        if let id = node.attributes["id"], !validStanzaID(id) { throw XMPPIQError.malformedResponse }
        let origins = node.children.filter { $0.name == "origin-id" && $0.namespace == "urn:xmpp:sid:0" }
        let origin = origins.count == 1 ? origins[0].attributes["id"] : nil
        let replaces = node.children.filter { $0.name == "replace" && $0.namespace == "urn:xmpp:message-correct:0" }
        let replace = replaces.count == 1 ? replaces[0].attributes["id"] : nil
        return XMPPEncryptedMessage(id: node.attributes["id"] ?? UUID().uuidString, from: from, to: node.attributes["to"],
                                    originID: origin.flatMap { validStanzaID($0) ? $0 : nil }, envelope: try parseEnvelope(encrypted), provenance: provenance,
                                    requestsReceipt: !node.children("request", namespace: "urn:xmpp:receipts").isEmpty,
                                    markable: !node.children("markable", namespace: "urn:xmpp:chat-markers:0").isEmpty,
                                    hasFallbackBody: !node.children("body", namespace: "jabber:client").isEmpty,
                                    replaces: replace.flatMap { validStanzaID($0) ? $0 : nil })
    }
    static func validStanzaID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1_024 && !value.contains(where: { $0.isWhitespace }) &&
        value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7f && $0.value != 0xfffe && $0.value != 0xffff }
    }
    static func messageXML(to: String, envelope: XMPPOMEMOEnvelope, id: String, requestReceipt: Bool = false, markable: Bool = false, replaces: String? = nil) throws -> String {
        guard bareJID(to) != nil, validStanzaID(id), replaces.map(validStanzaID) ?? true else { throw XMPPClientError.invalidConfiguration }
        // No body or reply metadata is emitted outside the encrypted payload. Receipt requests carry no
        // content, so they ride outside where every deployed client (Conversations, slixmpp) reads them;
        // a legacy correction reference rides outside because legacy OMEMO has no envelope to hold it.
        let hints = (requestReceipt ? "<request xmlns='urn:xmpp:receipts'/>" : "") + (markable ? "<markable xmlns='urn:xmpp:chat-markers:0'/>" : "")
        let replace = replaces.map { "<replace xmlns='urn:xmpp:message-correct:0' id='\(xmlEscaped($0))'/>" } ?? ""
        let result = "<message to='\(xmlEscaped(to))' type='chat' id='\(xmlEscaped(id))'>\(try envelopeXML(envelope))\(replace)<origin-id xmlns='urn:xmpp:sid:0' id='\(xmlEscaped(id))'/><store xmlns='urn:xmpp:hints'/><encryption xmlns='urn:xmpp:eme:0' namespace='\(envelope.profile.namespace)' name='OMEMO'/>\(hints)</message>"
        guard result.utf8.count <= 1_048_000 else { throw XMPPClientError.invalidConfiguration }
        return result
    }
}
