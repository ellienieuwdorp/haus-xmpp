import Foundation
import Testing
@testable import XMPPProtocol

private func pushNode(_ xml: String) throws -> XMPPProtocol.XMLNode {
    var parser = XMLStreamFramer()
    let frames = try parser.feed(Data(("<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams'>" + xml).utf8))
    guard case .element(let node) = frames.last else { throw XMPPIQError.malformedResponse }
    return node
}

@Test func pushRegistrationEscapesOpaqueCredentialsAndUsesExactPublishOptionsForm() throws {
    let config = try XMPPPushConfiguration(serviceJID: "push.example.org", node: "node'<>&", publishOptions: ["secret": "secret<&'\"", "device": "test"])
    let node = try pushNode(PushNotifications.enableXML(config))
    #expect(node.name == "enable" && node.namespace == "urn:xmpp:push:0")
    #expect(node.attributes["jid"] == "push.example.org")
    #expect(node.attributes["node"] == "node'<>&")
    let form = try #require(node.child("x", namespace: "jabber:x:data"))
    #expect(form.attributes["type"] == "submit")
    let fields = Dictionary(uniqueKeysWithValues: form.children.map { ($0.attributes["var"]!, $0.child("value", namespace: "jabber:x:data")!.text) })
    #expect(fields == ["FORM_TYPE": "http://jabber.org/protocol/pubsub#publish-options", "secret": "secret<&'\"", "device": "test"])
    #expect(!String(describing: config).contains("secret"))
    #expect(!String(reflecting: config).contains("node'"))
    #expect(try JSONDecoder().decode(XMPPPushConfiguration.self, from: JSONEncoder().encode(config)) == config)
}

@Test func pushConfigurationRejectsMalformedServiceUnboundedCredentialsAndFormInjection() throws {
    for service in ["", "https://push.example.org", "push.example.org/resource", "push..example.org", "-push.example.org", "push.example.org\n", "a@@example.org", "push@", "bad<name@push.example.org", "name:port@push.example.org"] {
        #expect(throws: XMPPNotificationError.self) { try XMPPPushConfiguration(serviceJID: service, node: "node") }
    }
    for node in ["", "line\nbreak", String(repeating: "n", count: 1025), "bad\u{0}"] {
        #expect(throws: XMPPNotificationError.self) { try XMPPPushConfiguration(serviceJID: "push.example.org", node: node) }
    }
    for options in [["FORM_TYPE": "other"], ["secret": String(repeating: "s", count: 2049)], ["secret": "bad\u{0}"], ["space key": "value"], Dictionary(uniqueKeysWithValues: (0..<17).map { ("k\($0)", "v") })] {
        #expect(throws: XMPPNotificationError.self) { try XMPPPushConfiguration(serviceJID: "push.example.org", node: "node", publishOptions: options) }
    }
    let invalidJSON = Data(#"{"serviceJID":"push.example.org","node":"n","publishOptions":{"FORM_TYPE":"forged"}}"#.utf8)
    #expect(throws: XMPPNotificationError.self) { try JSONDecoder().decode(XMPPPushConfiguration.self, from: invalidJSON) }
}

@Test func disablingPushCannotAccidentallyDisableEveryDeviceNode() throws {
    let node = try pushNode(PushNotifications.disableXML(serviceJID: "gateway@push.example.org", node: "one-device"))
    #expect(node.name == "disable" && node.namespace == "urn:xmpp:push:0")
    #expect(node.attributes["node"] == "one-device")
    #expect(node.attributes["jid"] == "gateway@push.example.org")
    #expect(node.children.isEmpty)
    #expect(throws: XMPPNotificationError.self) { try PushNotifications.disableXML(serviceJID: "push.example.org", node: "") }
}

@Test func clientStateIndicationsAreNonStanzas() async throws {
    for active in [false, true] {
        let node = try pushNode(PushNotifications.clientStateXML(active: active))
        #expect(node.namespace == "urn:xmpp:csi:0")
        #expect(node.name == (active ? "active" : "inactive"))
        #expect(node.children.isEmpty && node.attributes.isEmpty)
    }
    let client = XMPPClient()
    #expect(await !client.supportsClientStateIndication)
    await #expect(throws: XMPPClientError.notConnected) { try await client.enablePush(XMPPPushConfiguration(serviceJID: "push.example.org", node: "node")) }
}
