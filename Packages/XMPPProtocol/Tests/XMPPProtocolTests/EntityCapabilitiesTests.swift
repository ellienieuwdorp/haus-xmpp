import Foundation
import Testing
@testable import XMPPProtocol

@Test func capsVerificationMatchesTheXEP0115Example() {
    // XEP-0115 §5.2, "Exodus 0.9.1" with four features.
    let features = ["http://jabber.org/protocol/muc", "http://jabber.org/protocol/disco#items",
                    "http://jabber.org/protocol/disco#info", "http://jabber.org/protocol/caps"]
    #expect(EntityCapabilities.verification(identity: "client/pc//Exodus 0.9.1", features: features) == "QgayPKawpkPSDYmwT/WM94uAlu0=")
}

@Test func presenceCapsAndDiscoReplyAdvertiseTheSameNotifyFeatures() throws {
    let presence = EntityCapabilities.presenceElement
    #expect(presence.contains("hash='sha-1'") && presence.contains("ver='\(EntityCapabilities.verification)'"))
    let reply = EntityCapabilities.discoInfoQuery(node: EntityCapabilities.node + "#" + EntityCapabilities.verification)
    #expect(reply.contains("node='\(EntityCapabilities.node)#\(EntityCapabilities.verification)'"))
    for feature in ["urn:xmpp:avatar:metadata+notify", "http://jabber.org/protocol/caps"] + XMPPOMEMOProfile.allCases.map { $0.devicesNode + "+notify" } {
        #expect(reply.contains("<feature var='\(feature)'/>"))
    }
    #expect(!EntityCapabilities.discoInfoQuery(node: nil).contains(" node="))
}
