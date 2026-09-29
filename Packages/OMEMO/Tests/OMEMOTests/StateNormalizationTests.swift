import Foundation
import Testing
import XMPPProtocol
@testable import OMEMO

/// Encryption state saved before addresses were normalised names owners as they were typed. It must read back in
/// normal form without raising any trust decision, and an entry already in normal form wins a collision.
@Test func savedOwnersAreReadInNormalFormWithoutRaisingTrust() throws {
    let key = Data(repeating: 5, count: 33), otherKey = Data(repeating: 6, count: 33)
    func device(_ jid: String, _ id: UInt32, _ identity: Data, _ trust: DeviceTrust) -> String {
        #"{"jid":"\#(jid)","profile":"legacy","deviceID":\#(id),"identityKey":"\#(identity.base64EncodedString())","trust":"\#(trust.rawValue)","active":true,"identityChanged":false}"#
    }
    let json = #"""
    {"format":1,"engines":{},
     "devices":[\#(device("bob@localhost", 7, key, .undecided)),\#(device("Bob@LocalHost", 7, key, .verified)),\#(device("Carol@LocalHost", 9, otherKey, .accepted))],
     "profiles":{"Carol@LocalHost":"legacy","bob@localhost":"modern","Bob@localhost":"legacy"},
     "incompatiblePeers":{"Carol@LocalHost":true},
     "groupRooms":{"Team@Rooms.LocalHost":["Carol@LocalHost","carol@localhost","bob@localhost"]}}
    """#
    let state = try JSONDecoder().decode(AccountEncryptionState.self, from: Data(json.utf8))
    #expect(state.devices.map(\.jid) == ["bob@localhost", "carol@localhost"])
    // The collision keeps the entry already in normal form: its trust is not raised to the variant's.
    #expect(state.devices.first { $0.jid == "bob@localhost" }?.trust == .undecided)
    #expect(state.devices.first { $0.jid == "carol@localhost" }?.trust == .accepted)
    #expect(state.profiles == ["bob@localhost": .modern, "carol@localhost": .legacy])
    #expect(state.incompatiblePeers == ["carol@localhost": true])
    #expect(state.groupRooms == ["team@rooms.localhost": ["carol@localhost", "bob@localhost"]])
}
