import Foundation
import Testing
@testable import XMPPProtocol

private func stanza(_ xml: String) throws -> XMPPProtocol.XMLNode {
    var parser = XMLStreamFramer()
    let frames = try parser.feed(Data(("<stream:stream xmlns:stream='http://etherx.jabber.org/streams' xmlns='jabber:client'>" + xml).utf8))
    guard case .element(let node) = frames.last else { throw XMPPIQError.malformedResponse }
    return node
}
private let ns = XMPPChatState.namespace
private let account = "me@example.test"

@Test func bareComposingStanzaParsesAsAStateWithoutContent() throws {
    let node = try stanza("<message from='alex@example.test/phone' to='me@example.test' type='chat'><composing xmlns='\(ns)'/></message>")
    #expect(XMPPClient.parsedChatState(node, account: account, rooms: [:]) == XMPPChatState(chat: "alex@example.test", state: .composing))
    // Not a message: nothing else in the stanza becomes an event.
    #expect(XMPPClient.parsedMessage(node) == nil)
}

@Test func stateRidingOnABodyIsReportedAlongsideTheMessage() throws {
    let node = try stanza("<message from='alex@example.test/phone' type='chat' id='m1'><body>hi</body><active xmlns='\(ns)'/></message>")
    #expect(XMPPClient.parsedChatState(node, account: account, rooms: [:]) == XMPPChatState(chat: "alex@example.test", state: .active, ridesOnMessage: true))
    #expect(XMPPClient.parsedMessage(node)?.body == "hi")
}

@Test func everyStateNameParsesAndAmbiguityOrForeignTypesDoNot() throws {
    for state in XMPPChatState.State.allCases {
        let node = try stanza("<message from='alex@example.test' type='chat'><\(state.rawValue) xmlns='\(ns)'/></message>")
        #expect(XMPPClient.parsedChatState(node, account: account, rooms: [:])?.state == state)
    }
    for xml in ["<message from='alex@example.test' type='chat'><composing xmlns='\(ns)'/><paused xmlns='\(ns)'/></message>",
                "<message from='alex@example.test' type='chat'><typing xmlns='\(ns)'/></message>",
                "<message from='alex@example.test' type='chat'><composing/></message>",
                "<message from='alex@example.test' type='error'><composing xmlns='\(ns)'/></message>",
                "<message from='alex@example.test' type='headline'><composing xmlns='\(ns)'/></message>",
                // Our own other device, e.g. a state it sent reflected back.
                "<message from='me@example.test/tablet' type='chat'><composing xmlns='\(ns)'/></message>"] {
        #expect(XMPPClient.parsedChatState(try stanza(xml), account: account, rooms: [:]) == nil)
    }
}

@Test func groupStatesNeedAKnownRoomAndSkipOurOwnNickname() throws {
    var room = GroupRoomState()
    room.nickname = "me"
    room.occupants = ["team@rooms.example.test/maya": "maya@example.test", "team@rooms.example.test/tablet": account]
    let rooms = ["team@rooms.example.test": room]
    func state(_ from: String) throws -> XMPPChatState? {
        XMPPClient.parsedChatState(try stanza("<message from='\(from)' type='groupchat'><composing xmlns='\(ns)'/></message>"), account: account, rooms: rooms)
    }
    #expect(try state("team@rooms.example.test/maya") == XMPPChatState(chat: "team@rooms.example.test", participant: "maya@example.test", state: .composing))
    // No real address known yet: the nickname stands in.
    #expect(try state("team@rooms.example.test/sam")?.participant == "sam")
    #expect(try state("team@rooms.example.test/me") == nil)
    #expect(try state("team@rooms.example.test/tablet") == nil)
    #expect(try state("team@rooms.example.test") == nil)
    #expect(try state("other@rooms.example.test/maya") == nil)
}

@Test func outgoingStateIsABareHintedStanza() throws {
    let xml = try XMPPChatState.xml(.composing, to: "alex@example.test", id: "c1")
    #expect(xml == "<message to='alex@example.test' type='chat' id='c1'><composing xmlns='\(ns)'/><no-store xmlns='urn:xmpp:hints'/></message>")
    let group = try XMPPChatState.xml(.paused, to: "team@rooms.example.test", id: "c2", groupchat: true)
    #expect(group.contains("type='groupchat'") && group.contains("<paused xmlns='\(ns)'/>") && !group.contains("<body"))
    // The receiving side reads back what we send.
    let echoed = try stanza(xml.replacingOccurrences(of: "to='alex@example.test'", with: "from='alex@example.test/phone'"))
    #expect(XMPPClient.parsedChatState(echoed, account: account, rooms: [:])?.state == .composing)
    #expect(throws: XMPPClientError.self) { try XMPPChatState.xml(.active, to: "bad address", id: "c3") }
}

@Test func capsAdvertiseChatStates() {
    #expect(EntityCapabilities.features.contains(ns))
    #expect(EntityCapabilities.discoInfoQuery(node: nil).contains("<feature var='\(ns)'/>"))
}
