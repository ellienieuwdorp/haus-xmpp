import Foundation
import Testing
@testable import XMPPProtocol

private func registrationNode(_ xml: String) throws -> XMPPProtocol.XMLNode {
    var parser = XMLStreamFramer()
    let frames = try parser.feed(Data(("<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams'>" + xml).utf8))
    guard case .element(let node) = frames.last else { throw XMPPIQError.malformedResponse }
    return node
}

@Test func tokenRegistrationWireIsScopedStrictAndRedacted() throws {
    let config = try XMPPPushConfiguration(serviceJID: "push.example.org", node: String(repeating: "n", count: 43), publishOptions: ["secret": String(repeating: "s", count: 43)])
    let operation = try XMPPPushRegistrationOperation(action: .register, revision: 8, deviceToken: "AABBCCDD")
    let xml = try registrationNode(PushRegistrationWire.operationXML(operation, configuration: config, environment: .sandbox))
    #expect(xml.namespace == "https://xmpp.haus/push/registration/0" && xml.name == "register")
    #expect(xml.attributes["token"] == "aabbccdd" && xml.attributes["revision"] == "8")
    #expect(!String(describing: operation).contains("aabbccdd"))
    let revoke = try registrationNode(PushRegistrationWire.operationXML(XMPPPushRegistrationOperation(action: .revoke, revision: 9), configuration: config, environment: .sandbox))
    #expect(revoke.name == "revoke" && revoke.attributes["token"] == nil)
    #expect(try registrationNode(PushRegistrationWire.statusXML(config)).name == "status")
    for token in ["", "a", "gh", String(repeating: "aa", count: 513)] {
        #expect(throws: XMPPNotificationError.self) { try XMPPPushRegistrationOperation(action: .register, revision: 1, deviceToken: token) }
    }
    #expect(throws: XMPPNotificationError.self) { try XMPPPushRegistrationOperation(action: .revoke, revision: 1, deviceToken: "aabb") }
}

@Test func registrationReplyRejectsEchoedSecretsForeignAndDuplicateResults() throws {
    let ns = PushRegistrationWire.namespace
    let valid = try registrationNode("<iq type='result'><registration xmlns='\(ns)' revision='8' action='register'/></iq>")
    #expect(try PushRegistrationWire.result(valid) == XMPPPushRegistrationResult(revision: 8, action: .register))
    for payload in [
        "<registration xmlns='foreign' revision='8' action='register'/>",
        "<registration xmlns='\(ns)' revision='8' action='register' token='secret'/>",
        "<registration xmlns='\(ns)' revision='-1' action='register'/>",
        "<registration xmlns='\(ns)' revision='00000000000000000' action='register'/>",
        "<registration xmlns='\(ns)' revision='9007199254740992' action='register'/>",
        "<registration xmlns='\(ns)' revision='8' action='register'><nested/></registration>",
        "<registration xmlns='\(ns)' revision='8' action='register'/><registration xmlns='\(ns)' revision='8' action='register'/>"
    ] {
        #expect(throws: XMPPIQError.self) { try PushRegistrationWire.result(registrationNode("<iq type='result'>\(payload)</iq>")) }
    }
}

@Test func registerNamesTheAPNsEnvironmentAndRevokeDoesNot() throws {
    let config = try XMPPPushConfiguration(serviceJID: "push.xmpp.haus", node: "Ab-_" + String(repeating: "n", count: 39),
                                           publishOptions: ["secret": String(repeating: "s", count: 42) + "_"])
    let register = try XMPPPushRegistrationOperation(action: .register, revision: 1, deviceToken: "aabb")
    for environment in [XMPPPushEnvironment.sandbox, .production] {
        let xml = try registrationNode(PushRegistrationWire.operationXML(register, configuration: config, environment: environment))
        #expect(xml.attributes["environment"] == environment.rawValue)
        #expect(xml.name == "register" && xml.attributes["token"] == "aabb" && xml.attributes["revision"] == "1")
    }
    let revoke = try XMPPPushRegistrationOperation(action: .revoke, revision: 2)
    let revokeXML = try registrationNode(PushRegistrationWire.operationXML(revoke, configuration: config, environment: .production))
    #expect(revokeXML.attributes["environment"] == nil)
}
