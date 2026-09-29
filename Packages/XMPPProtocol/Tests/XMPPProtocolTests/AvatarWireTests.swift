import Foundation
import Testing
@testable import XMPPProtocol

private func node(_ xml: String) throws -> XMPPProtocol.XMLNode {
    var parser = XMLStreamFramer()
    let frames = try parser.feed(Data(("<stream:stream xmlns:stream='http://etherx.jabber.org/streams' xmlns='jabber:client'>" + xml).utf8))
    guard case .element(let node) = frames.last else { throw XMPPIQError.malformedResponse }
    return node
}

private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4])
private let pngHash = AvatarWire.hash(png)

private func metadataResult(_ infos: String) -> String {
    "<iq type='result' from='b@example.test' id='1'><pubsub xmlns='http://jabber.org/protocol/pubsub'><items node='urn:xmpp:avatar:metadata'><item id='\(pngHash)'><metadata xmlns='urn:xmpp:avatar:metadata'>\(infos)</metadata></item></items></pubsub></iq>"
}

@Test func metadataPicksTheInlineRasterInfoAndTreatsEmptyAsRemoved() throws {
    let infos = "<info id='\(pngHash)' type='image/svg+xml' bytes='12'/><info id='\(pngHash)' url='https://x/y.png' type='image/png' bytes='12'/><info id='\(pngHash.uppercased())' type='image/PNG' bytes='12' width='64' height='64'/>"
    #expect(try XMPPClient.decodeAvatarMetadata(node(metadataResult(infos))) == XMPPAvatarMetadata(id: pngHash, type: "image/png", bytes: 12))
    #expect(try XMPPClient.decodeAvatarMetadata(node(metadataResult(""))) == nil)
    let empty = "<iq type='result' from='b@example.test' id='1'><pubsub xmlns='http://jabber.org/protocol/pubsub'><items node='urn:xmpp:avatar:metadata'/></pubsub></iq>"
    #expect(try XMPPClient.decodeAvatarMetadata(node(empty)) == nil)
    let oversized = "<info id='\(pngHash)' type='image/png' bytes='\(AvatarWire.maximumBytes + 1)'/>"
    #expect(try XMPPClient.decodeAvatarMetadata(node(metadataResult(oversized))) == nil)
    let badHash = "<info id='not-a-sha1' type='image/png' bytes='12'/>"
    #expect(try XMPPClient.decodeAvatarMetadata(node(metadataResult(badHash))) == nil)
}

@Test func dataMustHashToTheRequestedID() throws {
    func result(id: String, base64: String) -> String {
        "<iq type='result' from='b@example.test' id='2'><pubsub xmlns='http://jabber.org/protocol/pubsub'><items node='urn:xmpp:avatar:data'><item id='\(id)'><data xmlns='urn:xmpp:avatar:data'>\(base64)</data></item></items></pubsub></iq>"
    }
    let encoded = png.base64EncodedString()
    #expect(try XMPPClient.decodeAvatarData(node(result(id: pngHash, base64: "\n  " + encoded + "\n")), id: pngHash) == png)
    let tampered = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 5]).base64EncodedString()
    #expect(throws: XMPPIQError.malformedResponse) { try XMPPClient.decodeAvatarData(node(result(id: pngHash, base64: tampered)), id: pngHash) }
    #expect(throws: XMPPIQError.malformedResponse) { try XMPPClient.decodeAvatarData(node(result(id: "0" + pngHash.dropFirst(), base64: encoded)), id: pngHash) }
    #expect(throws: XMPPIQError.malformedResponse) { try XMPPClient.decodeAvatarData(node(result(id: pngHash, base64: "")), id: pngHash) }
    let missing = "<iq type='result' from='b@example.test' id='2'><pubsub xmlns='http://jabber.org/protocol/pubsub'><items node='urn:xmpp:avatar:data'/></pubsub></iq>"
    #expect(throws: XMPPIQError.stanza(condition: "item-not-found")) { try XMPPClient.decodeAvatarData(node(missing), id: pngHash) }
}

@Test func notifyEventsDecodeIntoAvatarMetadataOnlyFromBareOwners() throws {
    func event(from: String, infos: String) -> String {
        "<message from='\(from)' to='a@example.test' type='headline'><event xmlns='http://jabber.org/protocol/pubsub#event'><items node='urn:xmpp:avatar:metadata'><item id='\(pngHash)'><metadata xmlns='urn:xmpp:avatar:metadata'>\(infos)</metadata></item></items></event></message>"
    }
    let info = "<info id='\(pngHash)' type='image/png' bytes='12'/>"
    let changed = try #require(XMPPClient.avatarUpdate(node(event(from: "b@example.test", infos: info))))
    #expect(changed.owner == "b@example.test" && changed.metadata == XMPPAvatarMetadata(id: pngHash, type: "image/png", bytes: 12))
    let removed = try #require(XMPPClient.avatarUpdate(node(event(from: "b@example.test", infos: ""))))
    #expect(removed.owner == "b@example.test" && removed.metadata == nil)
    #expect(XMPPClient.avatarUpdate(try node(event(from: "b@example.test/phone", infos: info))) == nil)
    #expect(XMPPClient.avatarUpdate(try node("<message from='b@example.test'><body>hi</body></message>")) == nil)
}
