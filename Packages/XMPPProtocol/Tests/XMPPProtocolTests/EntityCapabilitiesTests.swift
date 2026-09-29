import Foundation
import Testing
@testable import XMPPProtocol

@Test func capsVerificationMatchesTheXEP0115Example() {
    // XEP-0115 §5.2, "Exodus 0.9.1" with four features.
    let features = ["http://jabber.org/protocol/muc", "http://jabber.org/protocol/disco#items",
                    "http://jabber.org/protocol/disco#info", "http://jabber.org/protocol/caps"]
    #expect(EntityCapabilities.verification(identity: "client/pc//Exodus 0.9.1", features: features) == "QgayPKawpkPSDYmwT/WM94uAlu0=")
}

private func parsed(_ xml: String) throws -> XMPPProtocol.XMLNode { try XMLNode.parse(standalone: Data(xml.utf8)) }

/// A peer hashes the disco#info reply it receives and must reach the `ver` our presence announced,
/// or it re-queries and never trusts our `+notify` interests.
@Test func presenceCapsHashTheDiscoReplyAPeerReceives() throws {
    let caps = try parsed(EntityCapabilities.presenceElement)
    #expect(caps.name == "c" && caps.namespace == "http://jabber.org/protocol/caps" && caps.attributes["hash"] == "sha-1")
    let capsNode = try #require(caps.attributes["node"]), ver = try #require(caps.attributes["ver"])
    let request = try parsed("<iq xmlns='jabber:client' type='get' id='d1' from='alex@example.test/laptop'><query xmlns='http://jabber.org/protocol/disco#info' node='\(capsNode)#\(ver)'/></iq>")
    let reply = try parsed(try #require(PresenceWire.inlineResponse(request, accountFullJID: "me@example.test/phone", sharesLastActivity: false)))
    let query = try #require(reply.child("query", namespace: "http://jabber.org/protocol/disco#info"))
    #expect(query.attributes["node"] == "\(capsNode)#\(ver)")
    let identities = query.children("identity", namespace: query.namespace)
    try #require(identities.count == 1)
    let a = identities[0].attributes
    let identity = "\(a["category"] ?? "")/\(a["type"] ?? "")/\(a["xml:lang"] ?? "")/\(a["name"] ?? "")"
    let features = query.children("feature", namespace: query.namespace).compactMap { $0.attributes["var"] }
    #expect(EntityCapabilities.verification(identity: identity, features: features) == ver)
    let required = ["http://jabber.org/protocol/caps", "urn:xmpp:avatar:metadata+notify", XMPPChatState.namespace, "jabber:iq:last"]
        + XMPPOMEMOProfile.allCases.map { $0.devicesNode + "+notify" }
    for feature in required { #expect(features.contains(feature), "\(feature)") }
    #expect(!EntityCapabilities.discoInfoQuery(node: nil).contains(" node="))
}
