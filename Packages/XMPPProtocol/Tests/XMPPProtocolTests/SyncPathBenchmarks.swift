import Foundation
import XCTest
@testable import XMPPProtocol

/// Microbenchmarks for the per-page parse path of archive catch-up (docs/development/sync-performance.md). They only
/// run with HAUS_BENCHMARKS=1, so the default suite stays fast:
///   HAUS_BENCHMARKS=1 swift test --package-path Packages/XMPPProtocol [-c release] --filter SyncPathBenchmarks
/// The page is synthetic: legacy OMEMO messages from one peer device to eight recipient devices, as Prosody returns
/// them for an own-archive query, delivered in 64 KiB reads (`XMPPClient`'s receive size).
final class SyncPathBenchmarks: XCTestCase {
    private static let account = "app@localhost"
    private static let opening = "<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' from='localhost' id='s1' version='1.0'>"

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HAUS_BENCHMARKS"] == "1", "set HAUS_BENCHMARKS=1 to run benchmarks")
    }

    /// Deterministic base64 of `count` bytes, so every run parses the same input.
    private static func filler(_ count: Int, seed: Int) -> String {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ seed &* 17) }).base64EncodedString()
    }

    /// One archived message as the server sends it; the sender's address is mixed case so normalisation has work to do.
    static func result(_ index: Int) -> String {
        let keys = (0..<8).map { "<key rid='\(1000 + $0)'\($0 == 0 ? " prekey='true'" : "")>\(filler($0 == 0 ? 220 : 150, seed: index + $0))</key>" }.joined()
        let inner = "<message xmlns='jabber:client' from='Peer@LocalHost/Phone' type='chat' id='m\(index)'>"
            + "<encrypted xmlns='eu.siacs.conversations.axolotl'><header sid='4242'>\(keys)<iv>\(filler(12, seed: index))</iv></header>"
            + "<payload>\(filler(48, seed: index))</payload></encrypted><request xmlns='urn:xmpp:receipts'/>"
            + "<markable xmlns='urn:xmpp:chat-markers:0'/><store xmlns='urn:xmpp:hints'/>"
            + "<encryption xmlns='urn:xmpp:eme:0' name='OMEMO' namespace='eu.siacs.conversations.axolotl'/>"
            + "<body>I sent you an OMEMO encrypted message but your client doesn't seem to support that.</body></message>"
        return "<message xmlns='jabber:client' to='\(account)/phone'><result xmlns='urn:xmpp:mam:2' queryid='q1' id='a\(index)'>"
            + "<forwarded xmlns='urn:xmpp:forward:0'><delay xmlns='urn:xmpp:delay' stamp='2026-10-05T12:00:\(String(format: "%02d", index % 60))Z'/>"
            + "\(inner)</forwarded></result></message>"
    }

    /// The stream opening, `results` archived messages and the closing `<fin/>`, in 64 KiB reads.
    static func page(results: Int) -> [Data] {
        let fin = "<iq xmlns='jabber:client' type='result' id='q1'><fin xmlns='urn:xmpp:mam:2'><set xmlns='http://jabber.org/protocol/rsm'>"
            + "<first>a0</first><last>a\(results - 1)</last></set></fin></iq>"
        let bytes = Data((opening + (0..<results).map(result).joined() + fin).utf8)
        return stride(from: 0, to: bytes.count, by: 65_536).map { bytes[$0..<min($0 + 65_536, bytes.count)] }
    }

    private func frame(_ chunks: [Data]) -> [XMPPProtocol.XMLNode] {
        var framer = XMLStreamFramer()
        return chunks.flatMap { chunk in
            (try? framer.feed(chunk))?.compactMap { if case .element(let node) = $0 { node } else { nil } } ?? []
        }
    }

    private func measureFramer(results: Int) {
        let chunks = Self.page(results: results)
        var stanzas: [XMPPProtocol.XMLNode] = []
        measure { stanzas = frame(chunks) }
        XCTAssertEqual(stanzas.count, results + 1, "every result and the <fin/> iq")
    }

    func testFramerFeeds50ResultPage() { measureFramer(results: 50) }
    func testFramerFeeds100ResultPage() { measureFramer(results: 100) }

    /// `XMPPClient` normalises every inbound stanza tree before routing it.
    func testNormalisesMAMWrappedMessage() throws {
        let node = try XCTUnwrap(frame(Self.page(results: 1)).first)
        var normalised = node
        measure { for _ in 0..<1_000 { normalised = JID.normalizingAddresses(node) } }
        let inner = normalised.child("result", namespace: "urn:xmpp:mam:2")?.child("forwarded", namespace: "urn:xmpp:forward:0")?
            .child("message", namespace: "jabber:client")
        XCTAssertEqual(inner?.attributes["from"], "peer@localhost/Phone")
    }

    /// Everything the client does with a 50-result page before ArchiveSynchronizer sees it: framing, normalising each
    /// stanza, the archive provenance and OMEMO envelope parse, and the `<fin/>`.
    func testParsesWhole50ResultPage() throws {
        let chunks = Self.page(results: 50)
        var page: XMPPArchivePage?
        measure {
            var query = ArchiveQuery(queryID: "q1", accountBareJID: Self.account, accountFullJID: Self.account + "/phone", limit: 100)
            let stanzas = frame(chunks).map(JID.normalizingAddresses)
            for stanza in stanzas.dropLast() { try? query.receive(stanza) }
            page = try? query.finish(stanzas[stanzas.count - 1])
        }
        XCTAssertEqual(page?.messages.count, 50)
        XCTAssertTrue(page?.messages.allSatisfy { $0.encryptedMessage != nil } == true)
    }
}
