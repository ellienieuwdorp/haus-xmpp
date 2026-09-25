import Foundation
import Testing
@testable import XMPPProtocol

// The four inner shapes from docs/development/sync-review.md "Verification": each used to throw out of the page
// parser and wedge catch-up (F2). Outer provenance still throws; inner content becomes a rejected entry.
// Inner messages carry xmlns='jabber:client' as servers send them: inside <forwarded/> an unqualified
// <message/> would inherit urn:xmpp:forward:0 and be an unknown child, not archived content.

private let account = "alice@localhost"
private func probeQuery(limit: Int = 10) -> ArchiveQuery {
    ArchiveQuery(queryID: "q", accountBareJID: account, accountFullJID: account + "/ios", limit: limit)
}
private func probe(_ id: String, _ inner: String, wrapperFrom: String? = nil, wrapperTo: String = "alice@localhost/ios", queryID: String = "q",
                   forwardedExtra: String = "", resultExtra: String = "", delay: String = "<delay xmlns='urn:xmpp:delay' stamp='2026-09-01T10:00:00Z'/>") -> String {
    let from = wrapperFrom.map { " from='\($0)'" } ?? ""
    return "<message xmlns='jabber:client'\(from) to='\(wrapperTo)'><result xmlns='urn:xmpp:mam:2' queryid='\(queryID)' id='\(id)'><forwarded xmlns='urn:xmpp:forward:0'>\(delay)\(forwardedExtra)\(inner)</forwarded>\(resultExtra)</result></message>"
}
private let serverNotice = "<message xmlns='jabber:client' from='localhost' to='alice@localhost' type='normal' id='n1'><body>Maintenance tonight</body></message>"
private let emeOnly = "<message xmlns='jabber:client' from='bob@localhost/x' to='alice@localhost' type='chat' id='m2'><encryption xmlns='urn:xmpp:eme:0' namespace='urn:xmpp:openpgp:0'/><body>locked</body></message>"
private let unknownOMEMO = "<message xmlns='jabber:client' from='bob@localhost/x' to='alice@localhost' type='chat' id='m3'><encrypted xmlns='urn:xmpp:omemo:1'><header sid='1'/></encrypted></message>"
private let malformedKey = "<message xmlns='jabber:client' from='bob@localhost/x' to='alice@localhost' type='chat' id='m4'><encrypted xmlns='eu.siacs.conversations.axolotl'><header sid='7'><key rid='9'>@@notbase64@@</key><iv>AAAAAAAAAAAAAAAA</iv></header><payload>AAAA</payload></encrypted></message>"
private let plain = "<message xmlns='jabber:client' from='bob@localhost/x' to='alice@localhost' type='chat' id='p'><body>hello</body></message>"

@Test func archiveDirectBranchIsTotalForTheFourProbeShapes() throws {
    var query = probeQuery()
    for (index, inner) in [serverNotice, emeOnly, unknownOMEMO, malformedKey].enumerated() {
        try query.receive(recoveryNode(probe("\(index + 1)", inner)))
    }
    #expect(query.messages.count == 4)
    #expect(query.messages.map(\.rejectedContent) == [.foreignSender, .unsupportedDirectContent, .unsupportedDirectContent, .malformedEncryptedContent])
    #expect(query.messages.map(\.rejectedPeer) == [nil, "bob@localhost", "bob@localhost", "bob@localhost"])
    #expect(query.messages.allSatisfy { !$0.rejectedOutgoing && $0.rejectionArchive == account })
    // Nothing from a rejected entry reaches the application: no plaintext, no envelope, no event.
    #expect(query.messages.allSatisfy { $0.message == nil && $0.encryptedMessage == nil && $0.reaction == nil && $0.receipt == nil && $0.retraction == nil })
    #expect(query.messages.map(\.archiveID) == ["1", "2", "3", "4"])
    let fin = try recoveryNode("<iq type='result'><fin xmlns='urn:xmpp:mam:2' complete='true'><set xmlns='http://jabber.org/protocol/rsm'><last>4</last></set></fin></iq>")
    #expect(try query.finish(fin).lastID == "4")
}

@Test func archiveRejectsOwnSendWithUnsupportedContentAsOutgoing() throws {
    var query = probeQuery()
    let ownEME = "<message xmlns='jabber:client' from='alice@localhost/phone' to='bob@localhost' type='chat' id='o1'><encryption xmlns='urn:xmpp:eme:0' namespace='urn:xmpp:openpgp:0'/><body>locked</body></message>"
    try query.receive(recoveryNode(probe("own", ownEME)))
    let entry = try #require(query.messages.first)
    #expect(entry.rejectedContent == .unsupportedDirectContent && entry.rejectedOutgoing && entry.rejectedPeer == "bob@localhost")
    // A second known-namespace envelope is ambiguous content, not a wrapper failure.
    let doubled = "<message xmlns='jabber:client' from='alice@localhost/phone' to='bob@localhost' type='chat' id='o2'>"
        + "<encrypted xmlns='urn:xmpp:omemo:2'><header sid='1'/></encrypted><encrypted xmlns='eu.siacs.conversations.axolotl'><header sid='1'/></encrypted></message>"
    try query.receive(recoveryNode(probe("own-2", doubled)))
    #expect(query.messages.last?.rejectedContent == .unsupportedDirectContent && query.messages.last?.rejectedOutgoing == true)
}

@Test func archiveWrapperProvenanceStillThrows() throws {
    var query = probeQuery(limit: 2)
    let shapes = [
        probe("a", plain, wrapperFrom: "evil@localhost"),
        probe("a", plain, wrapperTo: "alice@localhost/other"),
        probe("a", plain, queryID: "other"),
        probe("a b", plain),
        probe("a", plain, forwardedExtra: plain),                                          // two <message/> children
        probe("a", plain, forwardedExtra: "<delay xmlns='urn:xmpp:delay' stamp='2026-09-01T10:00:00Z'/>"), // two <delay/>
        probe("a", plain, resultExtra: "<extra xmlns='urn:example'/>"),                    // <result/> with two children
        probe("a", plain, delay: ""),                                                      // missing <delay/>
        probe("a", plain, delay: "<delay xmlns='urn:xmpp:delay' stamp='yesterday'/>")
    ]
    for xml in shapes {
        #expect(throws: XMPPIQError.malformedResponse) { try query.receive(recoveryNode(xml)) }
    }
    #expect(query.messages.isEmpty && query.identifiers.isEmpty)
    try query.receive(recoveryNode(probe("dup", plain)))
    #expect(throws: XMPPIQError.malformedResponse) { try query.receive(recoveryNode(probe("dup", plain))) }
    try query.receive(recoveryNode(probe("second", plain)))
    // The page is full: a third result is over the requested limit.
    #expect(throws: XMPPIQError.malformedResponse) { try query.receive(recoveryNode(probe("third", plain))) }
    #expect(query.messages.map(\.archiveID) == ["dup", "second"])
}

@Test func archiveToleratesUnknownForwardedChildren() throws {
    var query = probeQuery()
    let stanzaID = "<stanza-id xmlns='urn:xmpp:sid:0' id='x' by='alice@localhost'/>"
    try query.receive(recoveryNode(probe("1", plain, forwardedExtra: stanzaID)))
    let entry = try #require(query.messages.first)
    #expect(entry.message?.body == "hello" && entry.rejectedContent == nil)
    #expect(entry.timestamp == Date(timeIntervalSince1970: 1_788_256_800))
    // A redacted position may also carry unknown children beside its <delay/>.
    try query.receive(recoveryNode(probe("2", "", forwardedExtra: stanzaID)))
    #expect(query.messages.last?.archiveID == "2" && query.messages.last?.message == nil && query.messages.last?.rejectedContent == nil)
}
