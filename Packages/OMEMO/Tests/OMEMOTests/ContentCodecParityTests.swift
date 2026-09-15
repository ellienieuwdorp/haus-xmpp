import Foundation
import XCTest
import XMPPProtocol
@testable import OMEMO

/// Plain stanzas and decrypted SCE content share one payload grammar. These pin that the two
/// public entry points agree, so a XEP added to one path cannot silently diverge on the other.
final class ContentCodecParityTests: XCTestCase {
    private let account = "alice@localhost"
    private let peer = "bob@localhost"

    private func envelope(_ content: String) -> Data {
        Data("<envelope xmlns='urn:xmpp:sce:1'><content>\(content)</content><rpad>pad</rpad><from jid='\(peer)'/><to jid='\(account)'/></envelope>".utf8)
    }
    private func stanza(_ content: String) -> String {
        "<message id='m1' to='\(peer)' type='chat'>\(content)</message>"
    }

    func testSameReactionElementDecodesIdenticallyOnBothPaths() throws {
        let reactions = "<reactions xmlns='urn:xmpp:reactions:0' id='t&lt;1&gt;'><reaction>👍</reaction><reaction>👍</reaction><reaction>ordinary text</reaction><reaction>❤️</reaction></reactions>"
        let plain = try XCTUnwrap(XMPPClient.decodeOutgoingReactionXML(stanza(reactions), from: account))
        let encrypted = try EncryptedContent.decode(envelope(reactions), sender: peer, recipient: account, modern: true)
        XCTAssertEqual(plain.targetID, "t<1>")
        XCTAssertEqual(plain.targetID, encrypted.reaction?.targetWireID)
        XCTAssertEqual(plain.reactions, ["❤️", "👍"])
        XCTAssertEqual(plain.reactions, encrypted.reaction?.reactions)
        // The serialisers agree too: what one path writes, the other reads back unchanged.
        let written = try XMPPClient.reactionXML(to: peer, targetID: "t<1>", reactions: ["👍", "❤️"], id: "r1")
        let sealed = try EncryptedContent.encodeReaction(targetWireID: "t<1>", reactions: ["👍", "❤️"], sender: account, recipient: peer, originID: "r1", modern: true)
        XCTAssertEqual(XMPPClient.decodeOutgoingReactionXML(written, from: account)?.reactions,
                       try EncryptedContent.decode(sealed, sender: account, recipient: peer, modern: true).reaction?.reactions)
    }

    func testHardeningLimitsRejectTheSameInputsOnBothPaths() throws {
        let reaction = "<reactions xmlns='urn:xmpp:reactions:0' id='t'><reaction>👍</reaction></reactions>"
        let deep = "<reactions xmlns='urn:xmpp:reactions:0' id='t'>" + String(repeating: "<reaction>", count: 18) + "👍" + String(repeating: "</reaction>", count: 18) + "</reactions>"
        let malicious = [
            deep,
            "<!DOCTYPE m [<!ENTITY e SYSTEM 'file:///etc/passwd'>]>" + reaction,
            "<?xml version='1.0'?>" + reaction,
            "<reactions xmlns='urn:xmpp:reactions:0' id='t'/><reactions xmlns='urn:xmpp:reactions:0' id='u'/>",
            "<reactions xmlns='urn:xmpp:reactions:0' id='t'><reaction><b/></reaction></reactions>",
            "<reactions xmlns='urn:xmpp:reactions:0' id='with space'><reaction>👍</reaction></reactions>"
        ]
        for input in malicious {
            XCTAssertNil(XMPPClient.decodeOutgoingReactionXML(stanza(input), from: account), input.prefix(60).description)
            XCTAssertThrowsError(try EncryptedContent.decode(envelope(input), sender: peer, recipient: account, modern: true), input.prefix(60).description)
        }
        // Control: the well-formed element passes both.
        XCTAssertNotNil(XMPPClient.decodeOutgoingReactionXML(stanza(reaction), from: account))
        XCTAssertNotNil(try EncryptedContent.decode(envelope(reaction), sender: peer, recipient: account, modern: true).reaction)
    }
}
