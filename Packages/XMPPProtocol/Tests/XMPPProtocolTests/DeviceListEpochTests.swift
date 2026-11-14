import Foundation
import Testing
@testable import XMPPProtocol

private func message(_ xml: String) throws -> XMPPProtocol.XMLNode {
    var parser = XMLStreamFramer()
    let frames = try parser.feed(Data(("<stream:stream xmlns:stream='http://etherx.jabber.org/streams' xmlns='jabber:client'>" + xml).utf8))
    guard case .element(let node) = frames.last else { throw XMPPIQError.malformedResponse }
    return node
}

private let modernNode = XMPPOMEMOProfile.modern.devicesNode
private let event = "http://jabber.org/protocol/pubsub#event"

private func devicePush(_ owner: String, ids: [UInt32]) -> String {
    let devices = ids.map { "<device id='\($0)'/>" }.joined()
    return "<message from='\(owner)' to='me@example.org/phone'><event xmlns='\(event)'><items node='\(modernNode)'>"
        + "<item id='current'><devices xmlns='urn:xmpp:omemo:2'>\(devices)</devices></item></items></event></message>"
}

// Anything that could make a device list read on the stream out of date moves the epoch, and only a list received as a
// notification marks its owner as notified.
@Test func everyDeviceListEventBounceAndRosterChangeMovesTheEpoch() throws {
    let session = UUID()
    var observed = DeviceListObservation()
    let start = observed.epoch(session: session)
    observed.see(try message(devicePush("peer@example.org", ids: [7])), session: session)
    let pushed = observed.epoch(session: session)
    #expect(!pushed.isUnchanged(since: start))
    #expect(pushed.notifies("peer@example.org", profile: .modern))
    #expect(!pushed.notifies("peer@example.org", profile: .legacy))
    #expect(!pushed.notifies("other@example.org", profile: .modern))

    // A retraction or a list that does not parse still moves it, without proving anything about notifications.
    observed.see(try message("<message from='other@example.org'><event xmlns='\(event)'><retract node='\(modernNode)'/></event></message>"), session: session)
    let retracted = observed.epoch(session: session)
    #expect(!retracted.isUnchanged(since: pushed))
    #expect(!retracted.notifies("other@example.org", profile: .modern))

    observed.see(try message("<message from='peer@example.org' type='error' id='m1'><error type='cancel'>"
                             + "<item-not-found xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></message>"), session: session)
    let bounced = observed.epoch(session: session)
    #expect(!bounced.isUnchanged(since: retracted))

    // A chat message or another PEP node changes nothing.
    observed.see(try message("<message from='peer@example.org/phone' type='chat'><body>hi</body></message>"), session: session)
    observed.see(try message("<message from='peer@example.org'><event xmlns='\(event)'><items node='urn:xmpp:avatar:metadata'/></event></message>"),
                 session: session)
    #expect(observed.epoch(session: session).isUnchanged(since: bounced))

    observed.see(XMPPEvent.rosterItems([], replacesAll: true))
    let roster = observed.epoch(session: session)
    #expect(!roster.isUnchanged(since: bounced))
    #expect(!roster.notifies("peer@example.org", profile: .modern))

    observed.changed()
    #expect(!observed.epoch(session: session).isUnchanged(since: roster))
}

// What one stream was notified of says nothing about the next one.
@Test func aNewSessionStartsWithNoNotifiedOwners() throws {
    let first = UUID(), second = UUID()
    var observed = DeviceListObservation()
    observed.see(try message(devicePush("peer@example.org", ids: [7])), session: first)
    #expect(observed.epoch(session: first).notifies("peer@example.org", profile: .modern))
    #expect(!observed.epoch(session: second).notifies("peer@example.org", profile: .modern))
    #expect(!observed.epoch(session: second).isUnchanged(since: observed.epoch(session: first)))
    observed.see(try message("<message from='peer@example.org/phone' type='chat'><body>hi</body></message>"), session: second)
    #expect(!observed.epoch(session: first).notifies("peer@example.org", profile: .modern))
}

@Test func aClientThatIsNotOnlineVouchesForNothing() async {
    #expect(await XMPPClient().omemoDeviceEpoch() == nil)
}
