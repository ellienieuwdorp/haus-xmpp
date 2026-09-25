import Foundation
import Testing
@testable import XMPPProtocol

private func stanza(_ xml: String) throws -> XMPPProtocol.XMLNode {
    var parser = XMLStreamFramer()
    let frames = try parser.feed(Data(("<stream:stream xmlns:stream='http://etherx.jabber.org/streams' xmlns='jabber:client'>" + xml).utf8))
    guard case .element(let node) = frames.last else { throw XMPPIQError.malformedResponse }
    return node
}
private let account = "me@example.test"
private let full = "me@example.test/phone"
private func presence(_ xml: String, rooms: Set<String> = []) throws -> XMPPEvent? {
    PresenceWire.event(try stanza(xml), accountBareJID: account, accountFullJID: full, rooms: rooms)
}

@Test func availableAndUnavailablePresenceParseToTheContactsBareAddress() throws {
    #expect(try presence("<presence from='alex@example.test/laptop' to='\(full)'><show>away</show><status>brb</status><priority>5</priority></presence>")
            == .contactPresence(.init(contact: "alex@example.test", resource: "laptop", available: true)))
    #expect(try presence("<presence from='alex@example.test/laptop' type='unavailable'/>")
            == .contactPresence(.init(contact: "alex@example.test", resource: "laptop", available: false)))
    // A bare sender, e.g. the server's last unavailable presence after a probe.
    #expect(try presence("<presence from='alex@example.test' type='unavailable'/>")
            == .contactPresence(.init(contact: "alex@example.test", resource: nil, available: false)))
    // Our own other resource is kept; the app decides to ignore its account.
    #expect(try presence("<presence from='me@example.test/tablet'/>") == .contactPresence(.init(contact: account, resource: "tablet", available: true)))
}

@Test func idlePresenceCarriesItsSinceTimestamp() throws {
    let event = try presence("<presence from='alex@example.test/laptop'><idle xmlns='urn:xmpp:idle:1' since='2026-09-25T08:30:00Z'/></presence>")
    #expect(event == .contactPresence(.init(contact: "alex@example.test", resource: "laptop", available: true,
                                            idleSince: ArchiveQuery.timestamp("2026-09-25T08:30:00Z"))))
    // Fractional seconds parse; a malformed stamp or duplicated idle is just "not idle".
    if case .contactPresence(let p) = try presence("<presence from='alex@example.test/a'><idle xmlns='urn:xmpp:idle:1' since='2026-09-25T08:30:00.250Z'/></presence>") {
        #expect(p.idleSince != nil)
    } else { Issue.record("expected presence") }
    for xml in ["<presence from='alex@example.test/a'><idle xmlns='urn:xmpp:idle:1' since='yesterday'/></presence>",
                "<presence from='alex@example.test/a'><idle xmlns='urn:xmpp:idle:1' since='2026-09-25T08:30:00Z'/><idle xmlns='urn:xmpp:idle:1' since='2026-09-25T08:30:00Z'/></presence>",
                "<presence from='alex@example.test/a'><idle since='2026-09-25T08:30:00Z'/></presence>"] {
        guard case .contactPresence(let p) = try presence(xml) else { Issue.record("expected presence"); continue }
        #expect(p.idleSince == nil && p.available)
    }
    // Idle is meaningless on an unavailable presence.
    guard case .contactPresence(let gone) = try presence("<presence from='alex@example.test/a' type='unavailable'><idle xmlns='urn:xmpp:idle:1' since='2026-09-25T08:30:00Z'/></presence>") else {
        Issue.record("expected presence"); return
    }
    #expect(gone.idleSince == nil && !gone.available)
}

@Test func roomsForeignRecipientsErrorsAndProbesAreNotContactPresence() throws {
    #expect(try presence("<presence from='team@rooms.example.test/maya'/>", rooms: ["team@rooms.example.test"]) == nil)
    #expect(try presence("<presence from='team@rooms.example.test' type='subscribe'/>", rooms: ["team@rooms.example.test"]) == nil)
    for xml in ["<presence from='alex@example.test/a' to='someone@example.test'/>",
                "<presence from='alex@example.test/a' to='me@example.test/other'/>",
                "<presence from='alex@example.test/a' type='error'/>",
                "<presence from='alex@example.test' type='probe'/>",
                "<presence from='alex@example.test/a' type='busy'/>",
                "<presence from='example.test'/>",
                "<presence from='alex@example.test/'/>",
                "<presence/>"] {
        #expect(try presence(xml) == nil, "\(xml)")
    }
    #expect(try presence("<presence from='alex@example.test/a' to='\(account)'/>") != nil)
}

@Test func subscriptionPresencesParseForEveryKind() throws {
    for kind in XMPPSubscriptionRequest.allCases {
        #expect(try presence("<presence from='alex@example.test' to='\(account)' type='\(kind.rawValue)'/>")
                == .subscription(.init(from: "alex@example.test", kind: kind)))
    }
    // A resource on the sender is reduced to the bare address the subscription belongs to.
    #expect(try presence("<presence from='alex@example.test/laptop' type='subscribe'/>") == .subscription(.init(from: "alex@example.test", kind: .subscribe)))
    #expect(try presence("<presence from='alex@example.test' to='mallory@example.test' type='subscribed'/>") == nil)
}

@Test func outgoingSubscriptionIsABareAddressedPresence() throws {
    #expect(try PresenceWire.subscriptionXML(.subscribe, to: "alex@example.test") == "<presence to='alex@example.test' type='subscribe'/>")
    #expect(try PresenceWire.subscriptionXML(.unsubscribed, to: "alex@example.test") == "<presence to='alex@example.test' type='unsubscribed'/>")
    for bad in ["alex@example.test/laptop", "example.test", "bad address@example.test", ""] {
        #expect(throws: XMPPClientError.self) { try PresenceWire.subscriptionXML(.subscribe, to: bad) }
    }
}

@Test func rosterFetchResultParsesItemsAndSkipsUnusableOnes() throws {
    let result = try stanza("""
        <iq type='result' id='r1' to='\(full)'><query xmlns='jabber:iq:roster' ver='v1'>\
        <item jid='alex@example.test' subscription='both' name='Alex'><group>Friends</group></item>\
        <item jid='maya@example.test' subscription='none' ask='subscribe'/>\
        <item jid='sam@example.test'/>\
        <item jid='gateway.example.test' subscription='both'/>\
        <item jid='odd@example.test' subscription='sideways'/>\
        <item jid='res@example.test/phone' subscription='to'/>\
        </query></iq>
        """)
    #expect(try PresenceWire.rosterResult(result) == [
        .init(jid: "alex@example.test", subscription: .both),
        .init(jid: "maya@example.test", subscription: .none, askPending: true),
        .init(jid: "sam@example.test", subscription: .none),
    ])
    #expect(try PresenceWire.rosterResult(try stanza("<iq type='result' id='r2'/>")) == [])
    #expect(try PresenceWire.rosterResult(try stanza("<iq type='result' id='r3'><query xmlns='jabber:iq:roster'/></iq>")) == [])
    #expect(throws: XMPPIQError.self) { try PresenceWire.rosterResult(try stanza("<iq type='result' id='r4'><query xmlns='jabber:iq:private'/></iq>")) }
}

@Test func rosterPushesAreAcceptedOnlyFromTheServerOrOurAccount() throws {
    let item = "<query xmlns='jabber:iq:roster'><item jid='alex@example.test' subscription='from'/></query>"
    #expect(PresenceWire.rosterPush(try stanza("<iq type='set' id='p1'>\(item)</iq>"), accountBareJID: account)
            == .init(jid: "alex@example.test", subscription: .from))
    #expect(PresenceWire.rosterPush(try stanza("<iq type='set' id='p2' from='\(account)'>\(item)</iq>"), accountBareJID: account) != nil)
    let removal = "<query xmlns='jabber:iq:roster'><item jid='alex@example.test' subscription='remove'/></query>"
    #expect(PresenceWire.rosterPush(try stanza("<iq type='set' id='p3'>\(removal)</iq>"), accountBareJID: account)?.subscription == .remove)
    // RFC 6121 §2.1.6: anyone else is a spoof; a push carries exactly one item.
    for xml in ["<iq type='set' id='p4' from='mallory@example.test'>\(item)</iq>",
                "<iq type='set' id='p5' from='\(full)'>\(item)</iq>",
                "<iq type='set' id='p6' from='example.test'>\(item)</iq>",
                "<iq type='get' id='p7'>\(item)</iq>",
                "<iq type='set' id='p8'><query xmlns='jabber:iq:roster'><item jid='a@example.test'/><item jid='b@example.test'/></query></iq>",
                "<iq type='set' id='p9'><query xmlns='jabber:iq:roster'/></iq>"] {
        #expect(PresenceWire.rosterPush(try stanza(xml), accountBareJID: account) == nil, "\(xml)")
    }
    // A rejected push falls through to the explicit rejection.
    let spoof = try stanza("<iq type='set' id='p4' from='mallory@example.test'>\(item)</iq>")
    #expect(PresenceWire.inlineResponse(spoof, accountFullJID: full, sharesLastActivity: true)?.contains("service-unavailable") == true)
}

@Test func lastActivityAnswersParseAndOnlyTheQueriedContactMayAnswer() throws {
    #expect(try PresenceWire.lastActivitySeconds(try stanza("<iq type='result' from='alex@example.test'><query xmlns='jabber:iq:last' seconds='903'/></iq>")) == 903)
    #expect(try PresenceWire.lastActivitySeconds(try stanza("<iq type='result' from='alex@example.test'><query xmlns='jabber:iq:last' seconds='0'/></iq>")) == 0)
    for xml in ["<iq type='result'><query xmlns='jabber:iq:last'/></iq>",
                "<iq type='result'><query xmlns='jabber:iq:last' seconds='-5'/></iq>",
                "<iq type='result'><query xmlns='jabber:iq:last' seconds='99999999999999'/></iq>",
                "<iq type='result'><query xmlns='jabber:iq:version' seconds='1'/></iq>"] {
        #expect(throws: XMPPIQError.self) { try PresenceWire.lastActivitySeconds(try stanza(xml)) }
    }
    let scope = IQReplyScope(recipient: "alex@example.test", accountBareJID: account, accountFullJID: full, serverDomain: "example.test")
    let answer = "<query xmlns='jabber:iq:last' seconds='5'/>"
    #expect(scope.accepts(try stanza("<iq type='result' id='l1' from='alex@example.test' to='\(full)'>\(answer)</iq>")))
    for from in ["alex@example.test/laptop", "mallory@example.test", "example.test", account] {
        #expect(!scope.accepts(try stanza("<iq type='result' id='l1' from='\(from)' to='\(full)'>\(answer)</iq>")), "\(from)")
    }
    #expect(!scope.accepts(try stanza("<iq type='result' id='l1' to='\(full)'>\(answer)</iq>")))
    // The server refusing because we hold no subscription surfaces as its condition.
    let forbidden = try stanza("<iq type='error' id='l1' from='alex@example.test'><error type='auth'><forbidden xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>")
    #expect(scope.accepts(forbidden))
    #expect(throws: XMPPIQError.stanza(condition: "forbidden")) { try IQReplyScope.result(forbidden) }
}

@Test func lastActivityQueryToOurFullJIDFollowsTheSharingSwitch() throws {
    let query = try stanza("<iq type='get' id='q1' from='alex@example.test/laptop' to='\(full)'><query xmlns='jabber:iq:last'/></iq>")
    #expect(PresenceWire.inlineResponse(query, accountFullJID: full, sharesLastActivity: true)
            == "<iq type='result' id='q1' to='alex@example.test/laptop'><query xmlns='jabber:iq:last' seconds='0'/></iq>")
    #expect(PresenceWire.inlineResponse(query, accountFullJID: full, sharesLastActivity: false)
            == "<iq type='error' id='q1' to='alex@example.test/laptop'><error type='cancel'><service-unavailable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>")
    // Only a get addressed to this resource is ours to answer.
    for xml in ["<iq type='get' id='q2' from='alex@example.test/laptop' to='\(account)'><query xmlns='jabber:iq:last'/></iq>",
                "<iq type='get' id='q3' from='alex@example.test/laptop'><query xmlns='jabber:iq:last'/></iq>",
                "<iq type='set' id='q4' from='alex@example.test/laptop' to='\(full)'><query xmlns='jabber:iq:last'/></iq>"] {
        #expect(PresenceWire.inlineResponse(try stanza(xml), accountFullJID: full, sharesLastActivity: true)?.contains("service-unavailable") == true, "\(xml)")
    }
}

@Test func existingInlineAnswersAreUnchanged() throws {
    let disco = try stanza("<iq type='get' id='d1' from='alex@example.test/laptop'><query xmlns='http://jabber.org/protocol/disco#info' node='n'/></iq>")
    #expect(PresenceWire.inlineResponse(disco, accountFullJID: full, sharesLastActivity: false)
            == "<iq type='result' id='d1' to='alex@example.test/laptop'>\(EntityCapabilities.discoInfoQuery(node: "n"))</iq>")
    let ping = try stanza("<iq type='get' id='p1' from='example.test'><ping xmlns='urn:xmpp:ping'/></iq>")
    #expect(PresenceWire.inlineResponse(ping, accountFullJID: full, sharesLastActivity: false) == "<iq type='result' id='p1' to='example.test'/>")
    let other = try stanza("<iq type='get' id='v1'><query xmlns='jabber:iq:version'/></iq>")
    #expect(PresenceWire.inlineResponse(other, accountFullJID: full, sharesLastActivity: true)
            == "<iq type='error' id='v1'><error type='cancel'><service-unavailable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>")
    #expect(PresenceWire.inlineResponse(try stanza("<iq type='result' id='x'/>"), accountFullJID: full, sharesLastActivity: true) == nil)
}

@Test func capsAdvertiseLastActivity() {
    #expect(EntityCapabilities.features.contains("jabber:iq:last"))
    #expect(EntityCapabilities.discoInfoQuery(node: nil).contains("<feature var='jabber:iq:last'/>"))
}
