import Foundation
import Testing
@testable import XMPPProtocol

private func parse(_ xml: String) throws -> XMPPProtocol.XMLNode {
    try XMPPProtocol.XMLNode.parse(standalone: Data(("<message xmlns='jabber:client'>" + xml + "</message>").utf8))
}
private let key = Data(repeating: 0x11, count: 32), iv = Data(repeating: 0x22, count: 12)
private let plainHash = Data.sha256(Data("plain".utf8)), cipherHash = Data.sha256(Data("cipher".utf8))
private func sharing(encrypted: Bool = true) -> MessageContent.FileSharing {
    MessageContent.FileSharing(name: "beach & <sun>.jpg", mediaType: "image/jpeg", size: 1234, width: 800, height: 600, hash: plainHash,
                               url: "https://uploads.localhost:5281/abc/beach.jpg", key: encrypted ? key : nil, iv: encrypted ? iv : nil, cipherHash: encrypted ? cipherHash : nil)
}

@Test func encryptedFileRoundTripsWithCaptionAndFallbackStripped() throws {
    let content = MessageContent(body: "look 👀", originID: "m1", fileSharing: sharing())
    let node = try parse(try content.xml())
    let body = try #require(node.child("body", namespace: "jabber:client")?.text)
    #expect(body.hasPrefix("look 👀\naesgcm://uploads.localhost:5281/abc/beach.jpg#"))
    #expect(body.hasSuffix(iv.hexString + key.hexString))
    #expect(node.child("fallback", namespace: "urn:xmpp:fallback:0")?.attributes["for"] == "urn:xmpp:sfs:0")
    let decoded = try MessageContent.decode(node, strict: true)
    #expect(decoded.body == "look 👀")
    #expect(decoded.fileSharing == sharing())
    #expect(decoded.originID == "m1")
}

@Test func fileWithoutCaptionDecodesToEmptyBody() throws {
    let plain = try MessageContent.decode(try parse(try MessageContent(body: "", fileSharing: sharing(encrypted: false)).xml()), strict: true)
    #expect(plain.body.isEmpty)
    #expect(plain.fileSharing == sharing(encrypted: false))
    #expect(plain.fileSharing?.isEncrypted == false)
    // A foreign sender that put only the URL in the body without declaring a fallback still yields a clean caption.
    let foreign = try parse("<body xmlns='jabber:client'>https://uploads.localhost:5281/abc/beach.jpg</body>" + (try sharing(encrypted: false).xml()))
    #expect(try MessageContent.decode(foreign, strict: true).body.isEmpty)
}

@Test func malformedFileSharingIsRejectedStrictlyAndDroppedLeniently() throws {
    let good = try sharing().xml()
    for bad in [good.replacingOccurrences(of: "<key>", with: "<key>AAAA"),
                good.replacingOccurrences(of: "sha-256", with: "sha-1"),
                good.replacingOccurrences(of: "aes-256-gcm-nopadding:0", with: "aes-128-gcm-nopadding:0"),
                good.replacingOccurrences(of: "target='https://", with: "target='http://"),
                good + good] {
        let node = try parse("<body xmlns='jabber:client'>x</body>" + bad)
        #expect(throws: (any Error).self) { try MessageContent.decode(node, strict: true) }
        #expect(try MessageContent.decode(node, strict: false).fileSharing == nil)
    }
}

@Test func encoderRejectsInvalidMaterial() {
    var broken = sharing(); broken.iv = Data(repeating: 1, count: 16)
    #expect(throws: (any Error).self) { try MessageContent(body: "", fileSharing: broken).xml() }
    broken = sharing(); broken.url = "http://insecure.localhost/x"
    #expect(throws: (any Error).self) { try MessageContent(body: "", fileSharing: broken).xml() }
    broken = sharing(); broken.hash = Data()
    #expect(throws: (any Error).self) { try MessageContent(body: "", fileSharing: broken).xml() }
}

@Test func legacyBodyParsesTwelveByteIVOnly() throws {
    let material = iv.hexString + key.hexString
    let file = try #require(MessageContent.FileSharing.fromAESGCMBody("aesgcm://uploads.localhost:5281/abc/photo.PNG#" + material))
    #expect(file.url == "https://uploads.localhost:5281/abc/photo.PNG")
    #expect(file.key == key && file.iv == iv)
    #expect(file.mediaType == "image/png" && file.name == "photo.PNG")
    #expect(file.aesgcmURL == "aesgcm://uploads.localhost:5281/abc/photo.PNG#" + material)
    #expect(MessageContent.FileSharing.fromAESGCMBody("aesgcm://h/x#" + Data(repeating: 3, count: 48).hexString) == nil)
    #expect(MessageContent.FileSharing.fromAESGCMBody("https://h/x#" + material) == nil)
    #expect(MessageContent.FileSharing.fromAESGCMBody("aesgcm://h/x#" + material + " trailing") == nil)
}

@Test func uploadServiceAndSlotDecode() throws {
    let info = try XMPPProtocol.XMLNode.parse(standalone: Data("""
        <query xmlns='http://jabber.org/protocol/disco#info'><identity category='store' type='file'/>
        <feature var='urn:xmpp:http:upload:0'/><x xmlns='jabber:x:data' type='result'>
        <field var='FORM_TYPE' type='hidden'><value>urn:xmpp:http:upload:0</value></field>
        <field var='max-file-size'><value>26214400</value></field></x></query>
        """.utf8))
    #expect(XMPPUploadService.decode(jid: "uploads.localhost", info: info) == XMPPUploadService(jid: "uploads.localhost", maximumFileSize: 26_214_400))
    let bare = try XMPPProtocol.XMLNode.parse(standalone: Data("<query xmlns='http://jabber.org/protocol/disco#info'><feature var='urn:xmpp:mam:2'/></query>".utf8))
    #expect(XMPPUploadService.decode(jid: "rooms.localhost", info: bare) == nil)
    let response = try XMPPProtocol.XMLNode.parse(standalone: Data("""
        <iq xmlns='jabber:client' type='result' id='1'><slot xmlns='urn:xmpp:http:upload:0'>
        <put url='https://uploads.localhost:5281/put/x.jpg'><header name='Authorization'>Basic abc</header><header name='X-Evil'>no</header></put>
        <get url='https://uploads.localhost:5281/get/x.jpg'/></slot></iq>
        """.utf8))
    let slot = try XMPPUploadSlot.decode(response)
    #expect(slot.put.absoluteString == "https://uploads.localhost:5281/put/x.jpg")
    #expect(slot.get.absoluteString == "https://uploads.localhost:5281/get/x.jpg")
    #expect(slot.headers == ["Authorization": "Basic abc"])
    let insecure = try XMPPProtocol.XMLNode.parse(standalone: Data("<iq xmlns='jabber:client' type='result' id='1'><slot xmlns='urn:xmpp:http:upload:0'><put url='http://u/x'/><get url='https://u/x'/></slot></iq>".utf8))
    #expect(throws: (any Error).self) { try XMPPUploadSlot.decode(insecure) }
}
