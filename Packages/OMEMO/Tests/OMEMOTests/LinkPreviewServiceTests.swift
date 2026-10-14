import Foundation
import MessageStore
import XCTest
import XMPPProtocol
@testable import OMEMO

/// XEP-0511 metadata frozen into our outgoing row rides inside the modern SCE envelope and is committed with the
/// authenticated message on the other side (the path the notification extension runs too). Legacy OMEMO has nowhere
/// private to carry it, so it never goes, and our stored preview goes with it.
@MainActor
final class LinkPreviewServiceTests: XCTestCase {
    private let link = "https://example.org/news"
    private func ownPreview(_ url: String = "https://example.org/news") -> StoredLinkPreview {
        StoredLinkPreview(url: url, title: "Council approves", summary: "Spring.", imageData: Data([0xFF, 0xD8, 0xFF, 0xE0]),
                          imageType: "image/jpeg", imageAlt: "Dusk", source: .own)
    }
    private func asSender(_ preview: StoredLinkPreview) -> StoredLinkPreview { var copy = preview; copy.source = .sender; return copy }

    func testOwnPreviewRidesOnlyInsideModernEnvelopesAndArrivesAsTheSendersPreview() async throws {
        for profile in [XMPPOMEMOProfile.modern, .legacy] {
            let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
            try await f.initialize(profile)
            let outgoing = try await f.queue("Read \(link)", linkPreview: ownPreview())
            let preparation = try await f.a.prepareAvailableMessages(account: f.alice, transport: f.aTransport)
            XCTAssertEqual(preparation.messageIDs, [outgoing.id], "\(profile)")
            XCTAssertEqual(preparation.droppedLinkPreviews, profile == .modern ? [] : [outgoing.id], "\(profile)")
            let mine = try await f.aStore.message(accountID: f.alice, messageID: outgoing.id)
            XCTAssertEqual(mine?.linkPreview, profile == .modern ? ownPreview() : nil, "\(profile): our bubble shows what the peer gets")

            let envelope = try await f.a.outgoingEnvelope(account: f.alice, messageID: outgoing.id)
            let inserted = try await f.b.receive(account: f.bob, message: XMPPEncryptedMessage(id: outgoing.id, from: f.alice, to: f.bob, originID: outgoing.id,
                                                                                             envelope: envelope), transport: f.bTransport)
            XCTAssertTrue(inserted, "\(profile)")
            let received = try await f.bStore.messages(accountID: f.bob, chatID: f.alice).first
            XCTAssertEqual(received?.body, "Read \(link)", "\(profile)")
            XCTAssertEqual(received?.linkPreview, profile == .modern ? asSender(ownPreview()) : nil, "\(profile)")
        }
    }

    /// An edit sends the whole new message: the preview goes along while its link stays in the text, and an edit
    /// without the link removes it on both sides.
    func testEditsKeepThePreviewOnlyWhileItsLinkRemains() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let outgoing = try await f.queue("Read \(link)", linkPreview: ownPreview())
        try await f.a.prepareQueuedMessages(account: f.alice, transport: f.aTransport)
        let original = try await f.a.outgoingEnvelope(account: f.alice, messageID: outgoing.id)
        _ = try await f.b.receive(account: f.bob, message: XMPPEncryptedMessage(id: outgoing.id, from: f.alice, to: f.bob, originID: outgoing.id,
                                                                              envelope: original), transport: f.bTransport)
        let delivered = try await f.bStore.messages(accountID: f.bob, chatID: f.alice)
        let target = try XCTUnwrap(delivered.first)

        for (body, expected) in [("Really, read \(link)", ownPreview() as StoredLinkPreview?), ("Never mind", nil)] {
            let id = try await f.a.queueCorrection(account: f.alice, chatID: f.bob, messageID: outgoing.id, body: body)
            let mine = try await f.aStore.message(accountID: f.alice, messageID: outgoing.id)?
                .applying(try await f.aStore.events(accountID: f.alice, chatID: f.bob, messageID: outgoing.id))
            XCTAssertEqual(mine?.linkPreview, expected, body)
            let prepared = try await f.a.prepareAvailableUpdates(account: f.alice, transport: f.aTransport)
            XCTAssertTrue(prepared.messageIDs.contains(id), body)
            let correction = try await f.a.outgoingUpdateEnvelope(account: f.alice, updateID: id)
            _ = try await f.b.receive(account: f.bob, message: XMPPEncryptedMessage(id: id, from: f.alice, to: f.bob, originID: id, envelope: correction),
                                      transport: f.bTransport)
            let theirs = target.applying(try await f.bStore.events(accountID: f.bob, chatID: f.alice, messageID: target.id))
            XCTAssertEqual(theirs.body, body)
            XCTAssertEqual(theirs.linkPreview, expected.map(asSender), body)
        }
    }
}
