import Foundation
import Testing
import XMPPProtocol
@testable import MessagingCore

struct PushRegistrationJournalTests {
    @Test func interruptedIntentsPersistExactlyAndARepeatedRevocationKeepsItsRevision() throws {
        var journal = PushRegistrationJournal()
        let registration = try journal.stageFreshRegistration(deviceToken: "AABB")
        var restored = try JSONDecoder().decode(PushRegistrationJournal.self, from: JSONEncoder().encode(journal))
        #expect(restored == journal && restored.pending == registration)
        let revoke = try restored.stageRevocation()
        restored = try JSONDecoder().decode(PushRegistrationJournal.self, from: JSONEncoder().encode(restored))
        // Signing out again after an interrupted transmission resends the persisted intent, not a new revision.
        #expect(try restored.stageRevocation() == revoke)
        #expect(restored.revision == 2)
        #expect(restored.acknowledge(try XMPPPushRegistrationResult(revision: 2, action: .revoke), for: revoke))
        // An acknowledged revocation is finished: the next sign-out is a new intent.
        #expect(try restored.stageRevocation().revision == 3)
    }

    @Test func lateEnableAndRotationRepliesCannotEraseRevocation() throws {
        var journal = PushRegistrationJournal()
        let first = try journal.stageFreshRegistration(deviceToken: "aabb")
        let rotated = try journal.stageFreshRegistration(deviceToken: "ccdd")
        let revoke = try journal.stageRevocation()
        #expect(!journal.acknowledge(try XMPPPushRegistrationResult(revision: first.revision, action: .register), for: first))
        #expect(!journal.acknowledge(try XMPPPushRegistrationResult(revision: rotated.revision, action: .register), for: rotated))
        #expect(journal.pending == revoke)
        #expect(journal.acknowledge(try XMPPPushRegistrationResult(revision: revoke.revision, action: .revoke), for: revoke))
        #expect(journal.pending == nil && journal.acknowledgedRevision == 3)
    }

    @Test func conflictRecoveryPreservesLatestIntentAndRejectsOldReply() throws {
        var journal = PushRegistrationJournal()
        let original = try journal.stageFreshRegistration(deviceToken: "aabb")
        _ = try journal.stageRevocation()
        let updated = try journal.rebasePending(after: XMPPPushRegistrationResult(revision: 50, action: .register))
        let rebased = try #require(updated)
        #expect(rebased.revision == 51 && rebased.action == .revoke && rebased.deviceToken == nil)
        #expect(!journal.acknowledge(try XMPPPushRegistrationResult(revision: 1, action: .register), for: original))
        #expect(try journal.rebasePending(after: XMPPPushRegistrationResult(revision: 49, action: .register)) == rebased)
    }

    @Test func invalidStateAndCounterExhaustionFailWithoutMutation() throws {
        let corrupt = Data(#"{"revision":1,"acknowledgedRevision":2}"#.utf8)
        #expect(throws: XMPPNotificationError.self) { try JSONDecoder().decode(PushRegistrationJournal.self, from: corrupt) }
        var journal = PushRegistrationJournal()
        _ = try journal.stageRevocation()
        let saved = journal
        #expect(throws: XMPPNotificationError.self) { try journal.stageFreshRegistration(deviceToken: "not-hex") }
        #expect(journal == saved)
        #expect(throws: XMPPNotificationError.self) {
            try journal.rebasePending(after: XMPPPushRegistrationResult(revision: XMPPPushRegistrationOperation.maximumRevision, action: .register))
        }
        #expect(journal == saved)
    }
}

struct PushRegistrationJournalAbandonTests {
    @Test func abandoningARevocationTheGatewayCannotFindKeepsRevisionsMonotonic() throws {
        var journal = PushRegistrationJournal()
        let register = try journal.stageFreshRegistration(deviceToken: "aabb")
        #expect(journal.acknowledge(try XMPPPushRegistrationResult(revision: 1, action: .register), for: register))
        let revoke = try journal.stageRevocation()
        let abandoned = journal.abandonPending(revoke)
        #expect(abandoned && journal.pending == nil && journal.revision == 2)
        #expect(try journal.stageFreshRegistration(deviceToken: "aabb").revision == 3)
        // A stale operation cannot clear newer intent.
        let stale = journal.abandonPending(revoke)
        #expect(!stale && journal.pending != nil)
        let restored = try JSONDecoder().decode(PushRegistrationJournal.self, from: JSONEncoder().encode(journal))
        #expect(restored == journal)
    }
}
