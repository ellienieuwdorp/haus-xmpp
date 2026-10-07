import Foundation
import Testing
@testable import XMPPProtocol

private func omemoNode(_ xml: String) throws -> XMPPProtocol.XMLNode {
    var parser = XMLStreamFramer()
    let frames = try parser.feed(Data(("<stream:stream xmlns:stream='http://etherx.jabber.org/streams' xmlns='jabber:client'>" + xml).utf8))
    guard case .element(let node) = frames.last else { throw XMPPIQError.malformedResponse }
    return node
}

private func decodeEncrypted(_ xml: String) throws -> XMPPEncryptedMessage { try OMEMOWire.parseMessage(omemoNode(xml)) }

private func bundle(_ profile: XMPPOMEMOProfile) -> XMPPOMEMOBundle {
    let key = profile == .legacy ? Data([5] + Array(repeating: UInt8(42), count: 32)) : Data(repeating: 42, count: 32)
    return XMPPOMEMOBundle(profile: profile, deviceID: 123, identityKey: key, signedPreKeyID: 7,
                           signedPreKey: key, signedPreKeySignature: Data(repeating: 10, count: 64),
                           preKeys: Dictionary(uniqueKeysWithValues: (1...100).map { (UInt32($0), key) }))
}

@Test func bothProfilesRoundTripDeviceListsAndBundles() throws {
    for profile in XMPPOMEMOProfile.allCases {
        let devices = try omemoNode(OMEMOWire.devicesXML([33, 11], profile: profile))
        #expect(try OMEMOWire.parseDevices(devices, profile: profile) == [11, 33])
        let original = bundle(profile)
        let node = try omemoNode(OMEMOWire.bundleXML(original))
        #expect(try OMEMOWire.parseBundle(node, deviceID: 123, profile: profile) == original)
    }
}

@Test func encryptedStanzasKeepCiphertextAndNeverCarryPlaintextFallbacks() throws {
    for profile in XMPPOMEMOProfile.allCases {
        let envelope = XMPPOMEMOEnvelope(profile: profile, senderDeviceID: 91,
                                        keys: [XMPPOMEMOKey(recipientJID: profile == .modern ? "b@example.test" : nil,
                                                            deviceID: 123, keyExchange: true, data: Data([1, 2, 3]))],
                                        iv: profile == .legacy ? Data(repeating: 10, count: 12) : nil, payload: Data([4, 5, 6]))
        let xml = try XMPPClient.encryptedMessageXML(to: "b@example.test", envelope: envelope, id: "durable-1")
        #expect(!xml.contains("<body"))
        let fromXML = xml.replacingOccurrences(of: "<message ", with: "<message from='a@example.test/phone' ")
        let decoded = try decodeEncrypted(fromXML)
        #expect(decoded.id == "durable-1")
        #expect(decoded.originID == "durable-1")
        #expect(decoded.envelope == envelope)
        #expect(XMPPClient.parsedMessage(try omemoNode(fromXML)) == nil)
    }
}

@Test func rejectAmbiguousMalformedAndCrossNamespaceEncryptedContent() throws {
    let ns = XMPPOMEMOProfile.legacy.namespace
    let good = "<encrypted xmlns='\(ns)'><header sid='91'><key rid='123'>AQID</key><iv>AQEBAQEBAQEBAQEB</iv></header><payload>BAUG</payload></encrypted>"
    let variants = [
        good + good,
        good.replacingOccurrences(of: "sid='91'", with: "sid='0'"),
        good.replacingOccurrences(of: "rid='123'", with: "rid='2147483648'"),
        good.replacingOccurrences(of: "<key rid='123'>AQID</key>", with: "<key rid='123'>AQID</key><key rid='123'>BAUG</key>"),
        good.replacingOccurrences(of: "<header ", with: "<header xmlns='urn:wrong' "),
        good.replacingOccurrences(of: "<key ", with: "<key prekey='perhaps' "),
        good.replacingOccurrences(of: "AQID", with: "not-base64!"),
        good.replacingOccurrences(of: "<payload>BAUG</payload>", with: "<payload><nested/>BAUG</payload>"),
        good.replacingOccurrences(of: ns, with: "urn:xmpp:omemo:99")
    ]
    for encrypted in variants {
        let xml = "<message from='a@example.test' type='chat'><body>UNTRUSTED PLAINTEXT</body>\(encrypted)</message>"
        #expect(throws: (any Error).self) { try decodeEncrypted(xml) }
        #expect(XMPPClient.parsedMessage(try omemoNode(xml)) == nil)
    }
}

@Test func modernRecipientsAreScopedByJIDAndEmptyMessagesArePreserved() throws {
    let xml = "<message from='a@example.test/phone'><encrypted xmlns='urn:xmpp:omemo:2'><header sid='5'><keys jid='a@example.test'><key rid='7' kex='true'>AQID</key></keys><keys jid='b@example.test'><key rid='7'>BAUG</key></keys></header></encrypted></message>"
    let message = try decodeEncrypted(xml)
    #expect(message.envelope.keys.count == 2)
    #expect(message.envelope.payload == nil)
    #expect(message.envelope.iv == nil)
    #expect(throws: (any Error).self) { try decodeEncrypted(xml.replacingOccurrences(of: "jid='b@example.test'", with: "jid='a@example.test'")) }
    #expect(throws: (any Error).self) { try decodeEncrypted(xml.replacingOccurrences(of: "jid='b@example.test'", with: "jid='b@example.test/resource'")) }
}

@Test func malformedBundlesAndDeviceListsCannotReplaceValidState() throws {
    let profile = XMPPOMEMOProfile.modern
    let original = try OMEMOWire.bundleXML(bundle(profile))
    for xml in [original.replacingOccurrences(of: "<spks>", with: "<spks xmlns='urn:wrong'>"),
                original.replacingOccurrences(of: "<pk id='2'>", with: "<pk id='1'>"),
                original.replacingOccurrences(of: "<spk id='7'>", with: "<spk id='0'>")] {
        #expect(throws: (any Error).self) { try OMEMOWire.parseBundle(omemoNode(xml), deviceID: 123, profile: profile) }
    }
    for xml in ["<devices xmlns='urn:xmpp:omemo:2'><device id='0'/></devices>",
                "<devices xmlns='urn:xmpp:omemo:2'><device id='1'/><device id='1'/></devices>",
                "<devices xmlns='urn:xmpp:omemo:2'><device xmlns='urn:wrong' id='1'/></devices>"] {
        #expect(throws: (any Error).self) { try OMEMOWire.parseDevices(omemoNode(xml), profile: profile) }
    }
}

@Test func iqRepliesRequireTheAddressedEntityAndOurDestination() throws {
    let scope = IQReplyScope(recipient: "b@example.test", accountBareJID: "a@example.test", accountFullJID: "a@example.test/phone", serverDomain: "example.test")
    #expect(scope.accepts(try omemoNode("<iq from='b@example.test' to='a@example.test/phone' type='result' id='1'/>")))
    // An error from the addressed entity is its answer (XEP-0012 `forbidden`), not someone else's.
    #expect(scope.accepts(try omemoNode("<iq from='b@example.test' type='error' id='1'/>")))
    for attributes in ["from='evil@example.test'", "from='b@example.test/other'", "from='example.test'", "from='a@example.test'", "", "from='b@example.test' to='evil@example.test'"] {
        #expect(!scope.accepts(try omemoNode("<iq \(attributes) type='result' id='1'/>")))
    }
    #expect(!scope.accepts(try omemoNode("<iq xmlns='urn:wrong' from='b@example.test' type='result' id='1'/>")))
    #expect(!scope.accepts(try omemoNode("<iq from='b@example.test' type='set' id='1'/>")))
    let own = IQReplyScope(recipient: nil, accountBareJID: "a@example.test", accountFullJID: "a@example.test/phone", serverDomain: "example.test")
    #expect(own.accepts(try omemoNode("<iq type='result' id='1'/>")))
    #expect(!own.accepts(try omemoNode("<iq from='a@example.test/evil' type='result' id='1'/>")))
    // Addresses compare in normal form: a query to a typed `B@Example.Test` is answered by `b@example.test`, and an
    // account entered with capitals still gets its own server's answers. Another entity is still refused.
    let typed = IQReplyScope(recipient: "B@Example.Test", accountBareJID: "A@example.test", accountFullJID: "A@example.test/phone", serverDomain: "Example.Test")
    #expect(typed.accepts(try omemoNode("<iq from='b@example.test' to='a@example.test/phone' type='result' id='1'/>")))
    #expect(!typed.accepts(try omemoNode("<iq from='c@example.test' to='a@example.test/phone' type='result' id='1'/>")))
    #expect(!typed.accepts(try omemoNode("<iq from='b@example.test/Other' type='result' id='1'/>")))
    let ownTyped = IQReplyScope(recipient: "A@Example.Test", accountBareJID: "a@example.test", accountFullJID: "a@example.test/phone", serverDomain: "example.test")
    for from in ["", "from='a@example.test'", "from='example.test'", "from='a@example.test/phone'"] {
        #expect(ownTyped.accepts(try omemoNode("<iq \(from) type='result' id='1'/>")))
    }
    #expect(!ownTyped.accepts(try omemoNode("<iq from='a@example.test/evil' type='result' id='1'/>")))
}

@Test func iqErrorsPreserveExactConditionAndRejectForgedNamespaces() throws {
    let xml = "<iq from='b@example.test' type='error'><error type='cancel'><item-not-found xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>"
    #expect(throws: XMPPIQError.stanza(condition: "item-not-found")) { try IQReplyScope.result(omemoNode(xml)) }
    #expect(throws: XMPPIQError.malformedResponse) { try IQReplyScope.result(omemoNode(xml.replacingOccurrences(of: "urn:ietf:params:xml:ns:xmpp-stanzas", with: "urn:wrong"))) }
    // A server that adds a second condition still refused: the first one is the answer, not a malformed reply.
    let doubled = xml.replacingOccurrences(of: "</error>", with: "<undefined-condition xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error>")
    #expect(throws: XMPPIQError.stanza(condition: "item-not-found")) { try IQReplyScope.result(omemoNode(doubled)) }
}

@Test func trustedCarbonsPreserveDirectionAndRejectForgedOrNestedWrappers() throws {
    func carbon(_ direction: String, inner: String) -> String {
        "<message from='a@example.test' to='a@example.test/phone'><\(direction) xmlns='urn:xmpp:carbons:2'><forwarded xmlns='urn:xmpp:forward:0'>\(inner)</forwarded></\(direction)></message>"
    }
    let received = carbon("received", inner: "<message xmlns='jabber:client' from='b@example.test/laptop' to='a@example.test/tablet' id='1'><body>hi</body></message>")
    let sent = carbon("sent", inner: "<message xmlns='jabber:client' from='a@example.test/tablet' to='b@example.test' id='2'><body>bye</body></message>")
    let (incoming, receivedProvenance) = try Carbons.unwrap(omemoNode(received), accountBareJID: "a@example.test", accountFullJID: "a@example.test/phone")
    let (outgoing, sentProvenance) = try Carbons.unwrap(omemoNode(sent), accountBareJID: "a@example.test", accountFullJID: "a@example.test/phone")
    #expect(receivedProvenance == .receivedCarbon)
    #expect(sentProvenance == .sentCarbon)
    #expect(XMPPClient.parsedMessage(incoming, provenance: receivedProvenance)?.provenance == .receivedCarbon)
    #expect(XMPPClient.parsedMessage(outgoing, provenance: sentProvenance)?.from == "a@example.test/tablet")
    for xml in [received.replacingOccurrences(of: "from='a@example.test'", with: "from='evil@example.test'"),
                received.replacingOccurrences(of: "from='a@example.test'", with: "from='a@example.test/evil'"),
                received.replacingOccurrences(of: "to='a@example.test/phone'", with: "to='a@example.test/elsewhere'"),
                received.replacingOccurrences(of: "urn:xmpp:forward:0", with: "urn:wrong"),
                received.replacingOccurrences(of: "urn:xmpp:carbons:2", with: "urn:xmpp:carbons:1"),
                received.replacingOccurrences(of: "to='a@example.test/tablet'", with: "to='evil@example.test'"),
                sent.replacingOccurrences(of: "from='a@example.test/tablet'", with: "from='b@example.test'"),
                carbon("received", inner: received)] {
        #expect(throws: (any Error).self) { try Carbons.unwrap(omemoNode(xml), accountBareJID: "a@example.test", accountFullJID: "a@example.test/phone") }
        #expect(XMPPClient.parsedMessage(try omemoNode(xml)) == nil)
    }
    let ambiguous = received.replacingOccurrences(of: "</received>", with: "</received><sent xmlns='urn:xmpp:carbons:2'/>")
    #expect(throws: (any Error).self) { try Carbons.unwrap(omemoNode(ambiguous), accountBareJID: "a@example.test", accountFullJID: "a@example.test/phone") }
}

@Test func emptyPubsubNodesReadAsMissing() throws {
    let empty = "<iq type='result'><pubsub xmlns='http://jabber.org/protocol/pubsub'><items node='eu.siacs.conversations.axolotl.devicelist'/></pubsub></iq>"
    #expect(try XMPPClient.decodeDeviceList(omemoNode(empty), profile: .legacy) == [])
    let bundle = "<iq type='result'><pubsub xmlns='http://jabber.org/protocol/pubsub'><items node='eu.siacs.conversations.axolotl.bundles:7'/></pubsub></iq>"
    #expect(throws: XMPPIQError.stanza(condition: "item-not-found")) { try XMPPClient.decodeBundle(omemoNode(bundle), deviceID: 7, profile: .legacy) }
    let two = "<iq type='result'><pubsub xmlns='http://jabber.org/protocol/pubsub'><items node='eu.siacs.conversations.axolotl.devicelist'><item id='a'/><item id='b'/></items></pubsub></iq>"
    #expect(throws: XMPPIQError.malformedResponse) { try XMPPClient.decodeDeviceList(omemoNode(two), profile: .legacy) }
}
