import Foundation
import Testing
import MessageStore
import OMEMO
@testable import XMPPProtocol
@testable import MessagingCore

struct ArchiveSynchronizerTests {
    private let account = "alice@localhost"
    private let room = "test@rooms.localhost"
    private enum Failure: Error { case refused, undurable, acknowledgement }

    private func fixture(_ body: (MessageStore) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "archive-sync-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try MessageStore(url: directory.appending(path: "messages.sqlite"))
        try await store.acquireTransportOwnership()
        do { try await body(store) }
        catch { try await store.close(); try? FileManager.default.removeItem(at: directory); throw error }
        try await store.close()
        try FileManager.default.removeItem(at: directory)
    }

    private func page(_ id: String, sequence: UInt64 = 1, complete: Bool = true, firstID: String? = nil) -> XMPPArchivePage {
        .init(messages: [.init(archiveID: id, timestamp: Date(timeIntervalSince1970: 100), message: nil, encryptedMessage: nil)],
              complete: complete, firstID: firstID ?? id, lastID: id, handledTokens: [.init(session: UUID(), sequence: sequence)])
    }

    private func page(_ ids: [String], sequence: UInt64, complete: Bool) -> XMPPArchivePage {
        .init(messages: ids.map { .init(archiveID: $0, timestamp: Date(timeIntervalSince1970: 100), message: nil, encryptedMessage: nil) },
              complete: complete, firstID: ids.first, lastID: ids.last, handledTokens: [.init(session: UUID(), sequence: sequence)])
    }

    /// What a forward query past the newest entry returns.
    private let emptyPage = XMPPArchivePage(messages: [], complete: true, firstID: nil, lastID: nil, handledTokens: [])

    @Test func walksOwnArchiveBeforeRoomsAndSeparatesPagedCheckpoints() async throws {
        try await fixture { store async throws in
            _ = try await store.saveArchiveCheckpoint(accountID: account, archiveID: room, expectedRevision: nil, cursor: "older-room")
            let trace = Trace()
            let operations = ArchiveSyncOperations(
                knownRooms: { [room] },
                refreshRoom: { try await trace.refresh($0) },
                fetchPage: { bound, selectedRoom in
                    await trace.record("fetch:\(selectedRoom ?? account):\(describe(bound))")
                    if selectedRoom == nil { return bound == .before(nil) ? page("own", sequence: 1) : emptyPage }
                    #expect(selectedRoom == room)
                    if bound == .after("older-room") { return page("room-first", sequence: 2, complete: false) }
                    #expect(bound == .after("room-first"))
                    return page("room-last", sequence: 3)
                },
                process: { await trace.record("durable:\($0.archiveID)") },
                acknowledge: { tokens async throws in
                    let sequence = try #require(tokens.first).sequence
                    let expected = sequence == 1 ? "own" : sequence == 2 ? "room-first" : "room-last"
                    let archive = sequence == 1 ? account : room
                    #expect(try await store.archiveCheckpoint(accountID: account, archiveID: archive)?.cursor == expected)
                    await trace.record("ack:" + tokens.map { String($0.sequence) }.joined(separator: ","))
                }, disconnect: { await trace.record("disconnect") }, progress: { _ in })
            try await ArchiveSynchronizer(store: store).synchronize(account: account, operations: operations)
            // A fresh direct archive starts newest-first; the room with a checkpoint stays forward-only.
            #expect(await trace.events == ["fetch:\(account):before(nil)", "durable:own", "ack:1", "fetch:\(account):after(own)", "refresh:\(room)",
                "fetch:\(room):after(older-room)", "durable:room-first", "ack:2", "fetch:\(room):after(room-first)", "durable:room-last", "ack:3"])
            #expect(try await store.archiveCheckpoint(accountID: account, archiveID: account)?.cursor == "own")
        }
    }

    @Test func undurableRoomMessageDisconnectsWithoutCheckpointOrAcknowledgement() async throws {
        try await fixture { store async throws in
            let trace = Trace()
            let operations = ArchiveSyncOperations(knownRooms: { [room] }, refreshRoom: { _ in },
                fetchPage: { _, selectedRoom in selectedRoom == nil ? emptyPage : page("failed-room") },
                process: { _ in throw Failure.undurable },
                acknowledge: { _ in await trace.record("ack") }, disconnect: { await trace.record("disconnect") }, progress: { _ in })
            await #expect(throws: Failure.self) { try await ArchiveSynchronizer(store: store).synchronize(account: account, operations: operations) }
            #expect(await trace.events == ["disconnect"])
            #expect(try await store.archiveCheckpoint(accountID: account, archiveID: room) == nil)
        }
    }

    @Test func revokedRoomDoesNotBlockDirectArchiveOrAdvanceRoomCheckpoint() async throws {
        try await fixture { store async throws in
            let trace = Trace()
            let operations = ArchiveSyncOperations(knownRooms: { [room] }, refreshRoom: { _ in throw XMPPGroupError.incompleteMembership },
                fetchPage: { bound, selected in
                    #expect(selected == nil); await trace.record("fetch-direct")
                    return bound == .before(nil) ? page("direct") : emptyPage
                },
                process: { _ in }, acknowledge: { _ in await trace.record("ack") }, disconnect: { await trace.record("disconnect") }, progress: { _ in })
            try await ArchiveSynchronizer(store: store).synchronize(account: account, operations: operations)
            #expect(await trace.events == ["fetch-direct", "ack", "fetch-direct"])
            #expect(try await store.archiveCheckpoint(accountID: account, archiveID: account)?.cursor == "direct")
            #expect(try await store.archiveCheckpoint(accountID: account, archiveID: room) == nil)
        }
    }

    @Test func malformedRoomResponseDisconnectsAfterTheDirectArchiveAndBeforeItsOwnCursor() async throws {
        try await fixture { store async throws in
            let trace = Trace()
            let operations = ArchiveSyncOperations(knownRooms: { [room] }, refreshRoom: { _ in throw XMPPIQError.malformedResponse },
                fetchPage: { bound, _ in await trace.record("fetch"); return bound == .before(nil) ? page("unexpected") : emptyPage },
                process: { _ in }, acknowledge: { _ in await trace.record("ack") }, disconnect: { await trace.record("disconnect") }, progress: { _ in })
            await #expect(throws: XMPPIQError.self) { try await ArchiveSynchronizer(store: store).synchronize(account: account, operations: operations) }
            #expect(await trace.events == ["fetch", "ack", "fetch", "disconnect"])
            #expect(try await store.archiveCheckpoint(accountID: account, archiveID: account)?.cursor == "unexpected")
            #expect(try await store.archiveCheckpoint(accountID: account, archiveID: room) == nil)
        }
    }

    @Test func progressReportsEachCommittedPage() async throws {
        try await fixture { store async throws in
            let recorded = ProgressLog()
            let operations = ArchiveSyncOperations(knownRooms: { [room] }, refreshRoom: { _ in },
                fetchPage: { bound, selectedRoom in
                    if selectedRoom == nil { return bound == .before(nil) ? page("direct-1", sequence: 1, complete: false) : page("direct-2", sequence: 2) }
                    return bound == .before(nil) ? page("room-1", sequence: 3) : emptyPage
                },
                process: { _ in }, acknowledge: { _ in }, disconnect: {}, progress: { await recorded.append($0) })
            try await ArchiveSynchronizer(store: store).synchronize(account: account, operations: operations)
            // Each archive's newest page, then its forward page (the room's is empty).
            #expect(await recorded.values == [.init(archive: nil, pages: 1, messages: 1), .init(archive: nil, pages: 2, messages: 2),
                                              .init(archive: room, pages: 1, messages: 1), .init(archive: room, pages: 2, messages: 1)])
        }
    }

    @Test func rejectedDirectContentWritesRejectionAndPlaceholder() async throws {
        try await fixture { store async throws in
            let sync = ArchiveSynchronizer(store: store)
            let bob = "bob@localhost", stamp = Date(timeIntervalSince1970: 1_788_256_800)
            var malformed = XMPPArchiveMessage(archiveID: "m4", timestamp: stamp, message: nil, encryptedMessage: nil)
            malformed.rejectedContent = .malformedEncryptedContent
            malformed.rejectedPeer = bob
            await #expect(throws: XMPPIQError.self) { _ = try await sync.persistRejectedContent(account: account, archived: malformed) }
            #expect(try await store.messages(accountID: account, chatID: bob).isEmpty)
            malformed.rejectionArchive = account
            #expect(try await sync.persistRejectedContent(account: account, archived: malformed))
            let rows = try await store.messages(accountID: account, chatID: bob)
            #expect(rows.count == 1)
            let row = try #require(rows.first)
            #expect(row.sentAt == stamp && row.unreadableReason == .malformedContent && row.senderID == bob && !row.isOutgoing)
            #expect(row.body.isEmpty && row.encryptionProfile == "unreadable" && row.wireID == nil)
            #expect(try await store.hasArchiveRejection(accountID: account, archiveID: account, messageID: "m4"))
            // A repeated page is idempotent.
            #expect(try await sync.persistRejectedContent(account: account, archived: malformed))
            #expect(try await store.messages(accountID: account, chatID: bob).count == 1)

            var notice = XMPPArchiveMessage(archiveID: "n1", timestamp: stamp, message: nil, encryptedMessage: nil)
            notice.rejectedContent = .foreignSender
            notice.rejectionArchive = account
            #expect(try await sync.persistRejectedContent(account: account, archived: notice))
            #expect(try await store.hasArchiveRejection(accountID: account, archiveID: account, messageID: "n1"))
            #expect(try await store.chats(accountID: account).map(\.id) == [bob])

            var own = XMPPArchiveMessage(archiveID: "o1", timestamp: stamp.addingTimeInterval(1), message: nil, encryptedMessage: nil)
            own.rejectedContent = .unsupportedDirectContent
            own.rejectionArchive = account
            own.rejectedPeer = bob
            own.rejectedOutgoing = true
            #expect(try await sync.persistRejectedContent(account: account, archived: own))
            let outgoing = try #require(try await store.messages(accountID: account, chatID: bob).last)
            #expect(outgoing.isOutgoing && outgoing.senderID == account && outgoing.unreadableReason == .unsupportedEncryption)
            #expect(ArchiveSynchronizer.unreadableReason(for: .foreignSender) == nil)
            #expect(ArchiveSynchronizer.unreadableReason(for: .unverifiableEncryptedGroup) == nil)
        }
    }

    @Test func excludedArchiveEntryKeepsTheArchiveTimestampAndIsIdempotent() async throws {
        try await fixture { store async throws in
            let encryption = OMEMOService(store: store, protection: try StateProtection(key: Data(repeating: 7, count: 32)))
            try await encryption.initialize(account: account, transport: NullTransport(account: account))
            let stamp = Date(timeIntervalSince1970: 1_788_256_800)
            let envelope = XMPPOMEMOEnvelope(profile: .legacy, senderDeviceID: 4242, keys: [], iv: Data(repeating: 1, count: 12), payload: Data([1, 2, 3]))
            let encrypted = XMPPEncryptedMessage(id: "x1", from: "bob@localhost/x", to: account, originID: nil, envelope: envelope, provenance: .receivedCarbon)
            let archived = XMPPArchiveMessage(archiveID: "a1", timestamp: stamp, message: nil, encryptedMessage: encrypted)
            let sync = ArchiveSynchronizer(store: store)
            let client = XMPPClient(labCertificateAuthority: nil)
            try await sync.process(account: account, archived: archived, encryption: encryption, transport: client)
            let rows = try await store.messages(accountID: account, chatID: "bob@localhost")
            #expect(rows.count == 1)
            #expect(rows.first?.sentAt == stamp && rows.first?.unreadableReason == .notForThisDevice && rows.first?.isOutgoing == false)
            try await sync.process(account: account, archived: archived, encryption: encryption, transport: client)
            #expect(try await store.messages(accountID: account, chatID: "bob@localhost").count == 1)
            #expect(try await store.pendingEncryptedIncoming(accountID: account).isEmpty)
        }
    }

    /// An entry this device cannot decrypt yet has been processed once its ciphertext is retained, so its page may
    /// advance. One with no durable outcome fails the page.
    @Test func undecryptedArchiveEntryPassesOnlyWhenItsCiphertextIsRetained() async throws {
        try await fixture { store async throws in
            let encryption = OMEMOService(store: store, protection: try StateProtection(key: Data(repeating: 7, count: 32)))
            try await encryption.initialize(account: account, transport: NullTransport(account: account))
            let (direct, group) = try await unknownSenderEnvelopes(account: account, encryption: encryption)
            let stamp = Date(timeIntervalSince1970: 1_788_256_800), bob = "bob@localhost"
            var roomEntry = XMPPArchiveMessage(archiveID: "a2", timestamp: stamp, message: nil, encryptedMessage: nil)
            roomEntry.encryptedGroupMessage = try XMPPEncryptedGroupMessage(id: "k2", room: room, occupant: room + "/bob", sender: bob, envelope: group, provenance: .roomArchive)
            let directEntry = XMPPArchiveMessage(archiveID: "a1", timestamp: stamp, message: nil,
                encryptedMessage: XMPPEncryptedMessage(id: "k1", from: bob + "/x", to: account, originID: nil, envelope: direct, provenance: .receivedCarbon))
            let sync = ArchiveSynchronizer(store: store)
            let client = XMPPClient(labCertificateAuthority: nil)
            for entry in [directEntry, roomEntry] {
                try await sync.process(account: account, archived: entry, encryption: encryption, transport: client)
            }
            #expect(try await store.pendingEncryptedIncoming(accountID: account).count == 2)
            // Addressed to another account: nothing is retained for it.
            let misaddressed = XMPPArchiveMessage(archiveID: "a3", timestamp: stamp, message: nil,
                encryptedMessage: XMPPEncryptedMessage(id: "k3", from: bob + "/x", to: "mallory@localhost", originID: nil, envelope: direct, provenance: .receivedCarbon))
            await #expect(throws: OMEMOError.self) {
                try await sync.process(account: account, archived: misaddressed, encryption: encryption, transport: client)
            }
        }
    }

    @Test func failedAckKeepsAlreadyDurableCheckpointAndDisconnects() async throws {
        try await fixture { store async throws in
            let trace = Trace()
            let operations = ArchiveSyncOperations(knownRooms: { [] }, refreshRoom: { _ in },
                fetchPage: { _, _ in page("durable") }, process: { _ in await trace.record("durable") },
                acknowledge: { _ in throw Failure.acknowledgement }, disconnect: { await trace.record("disconnect") }, progress: { _ in })
            await #expect(throws: Failure.self) { try await ArchiveSynchronizer(store: store).synchronize(account: account, operations: operations) }
            #expect(await trace.events == ["durable", "disconnect"])
            #expect(try await store.archiveCheckpoint(accountID: account, archiveID: account)?.cursor == "durable")
        }
    }

    @Test func pageTokensAreAcknowledgedInOneBatchAfterTheCursor() async throws {
        try await fixture { store async throws in
            let trace = Trace()
            let session = UUID()
            let operations = ArchiveSyncOperations(knownRooms: { [] }, refreshRoom: { _ in },
                fetchPage: { bound, _ in
                    guard bound == .before(nil) else { return emptyPage }
                    return .init(messages: ["a", "b", "c"].map { .init(archiveID: $0, timestamp: Date(timeIntervalSince1970: 100), message: nil, encryptedMessage: nil) },
                                 complete: true, firstID: "a", lastID: "c", handledTokens: (1...3).map { XMPPInboundToken(session: session, sequence: $0) })
                },
                process: { await trace.record("durable:\($0.archiveID)") },
                acknowledge: { tokens async throws in
                    #expect(try await store.archiveCheckpoint(accountID: account, archiveID: account)?.cursor == "c")
                    await trace.record("ack:" + tokens.map { String($0.sequence) }.joined(separator: ","))
                }, disconnect: { await trace.record("disconnect") }, progress: { _ in })
            try await ArchiveSynchronizer(store: store).synchronize(account: account, operations: operations)
            #expect(await trace.events == ["durable:a", "durable:b", "durable:c", "ack:1,2,3"])
        }
    }

    // MARK: Newest-first first sync

    @Test func firstSyncFetchesTheNewestPageThenWalksForwardAndRecordsBothCursors() async throws {
        try await fixture { store async throws in
            let trace = Trace()
            let operations = ArchiveSyncOperations(knownRooms: { [] }, refreshRoom: { _ in },
                fetchPage: { bound, _ in
                    await trace.record("fetch:\(describe(bound))")
                    if bound == .before(nil) { return page(["a1", "a2", "a3"], sequence: 1, complete: false) }
                    #expect(bound == .after("a3"))
                    return emptyPage
                },
                process: { await trace.record("durable:\($0.archiveID)") },
                acknowledge: { tokens async throws in
                    // Durable before acknowledgement: both cursors exist when the page's tokens are released.
                    #expect(try await store.archiveCheckpoint(accountID: account, archiveID: account)?.cursor == "a3")
                    #expect(try await store.archiveBackfillCursor(accountID: account, archiveID: account)?.oldestID == "a1")
                    await trace.record("ack:" + tokens.map { String($0.sequence) }.joined(separator: ","))
                }, disconnect: { await trace.record("disconnect") }, progress: { _ in })
            try await ArchiveSynchronizer(store: store).synchronize(account: account, operations: operations)
            #expect(await trace.events == ["fetch:before(nil)", "durable:a1", "durable:a2", "durable:a3", "ack:1", "fetch:after(a3)"])
            #expect(try await store.archiveCheckpoint(accountID: account, archiveID: account)?.cursor == "a3")
            let backfill = try #require(try await store.archiveBackfillCursor(accountID: account, archiveID: account))
            #expect(backfill.oldestID == "a1" && !backfill.complete)
        }
    }

    @Test func firstSyncOfAnEmptyArchiveRecordsNoCursors() async throws {
        try await fixture { store async throws in
            let trace = Trace()
            let operations = ArchiveSyncOperations(knownRooms: { [] }, refreshRoom: { _ in },
                fetchPage: { bound, _ in await trace.record("fetch:\(describe(bound))"); return emptyPage },
                process: { _ in await trace.record("durable") }, acknowledge: { _ in await trace.record("ack") },
                disconnect: { await trace.record("disconnect") }, progress: { _ in })
            try await ArchiveSynchronizer(store: store).synchronize(account: account, operations: operations)
            #expect(await trace.events == ["fetch:before(nil)"])
            #expect(try await store.archiveCheckpoint(accountID: account, archiveID: account) == nil)
            #expect(try await store.archiveBackfillCursor(accountID: account, archiveID: account) == nil)
        }
    }

    @Test func firstSyncOfAShortArchiveMarksBackfillComplete() async throws {
        try await fixture { store async throws in
            let trace = Trace()
            let operations = ArchiveSyncOperations(knownRooms: { [] }, refreshRoom: { _ in },
                fetchPage: { bound, _ in
                    await trace.record("fetch:\(describe(bound))")
                    return bound == .before(nil) ? page(["s1", "s2"], sequence: 1, complete: true) : emptyPage
                },
                process: { _ in }, acknowledge: { _ in }, disconnect: { await trace.record("disconnect") }, progress: { _ in })
            try await ArchiveSynchronizer(store: store).synchronize(account: account, operations: operations)
            // A backward `complete` does not end the walk: the forward query still runs.
            #expect(await trace.events == ["fetch:before(nil)", "fetch:after(s2)"])
            #expect(try await store.archiveCheckpoint(accountID: account, archiveID: account)?.cursor == "s2")
            #expect(try await store.archiveBackfillCursor(accountID: account, archiveID: account) == ArchiveBackfillCursor(revision: 1, oldestID: "s1", complete: true))
        }
    }

    @Test func existingCheckpointNeverQueriesBackwards() async throws {
        try await fixture { store async throws in
            _ = try await store.saveArchiveCheckpoint(accountID: account, archiveID: account, expectedRevision: nil, cursor: "c1")
            _ = try await store.saveArchiveCheckpoint(accountID: account, archiveID: room, expectedRevision: nil, cursor: "r1")
            let bounds = BoundLog()
            let operations = ArchiveSyncOperations(knownRooms: { [room] }, refreshRoom: { _ in },
                fetchPage: { bound, selectedRoom in
                    await bounds.append(bound)
                    if bound == .after("c1") { return page("c2", sequence: 1, complete: false) }
                    if bound == .after("r1") { return page("r2", sequence: 2, complete: true) }
                    return emptyPage
                },
                process: { _ in }, acknowledge: { _ in }, disconnect: {}, progress: { _ in })
            try await ArchiveSynchronizer(store: store).synchronize(account: account, operations: operations)
            #expect(await bounds.values == [.after("c1"), .after("c2"), .after("r1")])
            // A pre-v16 archive gets no backfill row, so backfill treats it as walked from its start.
            #expect(try await store.archiveBackfillCursor(accountID: account, archiveID: account) == nil)
            #expect(try await store.archiveBackfillCursor(accountID: account, archiveID: room) == nil)
        }
    }

    // MARK: A cursor the server no longer holds

    /// Prosody answers an RSM id it no longer holds (archive expiry, one week by default) with item-not-found.
    @Test func anExpiredCursorReanchorsByTimeOnTheSameConnection() async throws {
        for archive in [account, room] {
            try await fixture { store async throws in
                let stamp = Date(timeIntervalSince1970: 1_000)
                _ = try await store.saveArchiveCheckpoint(accountID: account, archiveID: archive, expectedRevision: nil, cursor: "lost", stamp: stamp)
                let trace = Trace()
                let operations = ArchiveSyncOperations(knownRooms: { archive == room ? [room] : [] }, refreshRoom: { _ in },
                    fetchPage: { bound, selected in
                        guard (selected ?? account) == archive else { return emptyPage }
                        await trace.record("fetch:\(describe(bound))")
                        switch bound {
                        case .after("lost"): throw XMPPIQError.stanza(condition: "item-not-found")
                        case .since: return page(["kept", "n1"], sequence: 1, complete: false)
                        default: return page("n2", sequence: 2)
                        }
                    },
                    process: { await trace.record("durable:\($0.archiveID)") }, acknowledge: { _ in },
                    disconnect: { await trace.record("disconnect") }, progress: { _ in })
                let outcome = try await ArchiveSynchronizer(store: store).synchronize(account: account, operations: operations)
                #expect(outcome.isComplete)
                // Two seconds before the lost entry, then forward as usual; no disconnect.
                #expect(await trace.events == ["fetch:after(lost)", "fetch:since(998)", "durable:kept", "durable:n1", "fetch:after(n1)", "durable:n2"])
                #expect(try await store.archiveCheckpoint(accountID: account, archiveID: archive) ==
                        ArchiveCheckpoint(revision: 3, cursor: "n2", stamp: Date(timeIntervalSince1970: 100)))
                #expect(try await store.archiveGaps(accountID: account).map { [$0.archiveID, $0.since.map { "\(Int($0.timeIntervalSince1970))" }] } == [[archive, "1000"]])
                // History behind the lost cursor keeps its own (here absent) backfill cursor.
                #expect(try await store.archiveBackfillCursor(accountID: account, archiveID: archive) == nil)
            }
        }
    }

    /// A checkpoint saved before stamps existed restarts at the newest page, and its backfill cursor moves there so
    /// backfill walks back through whatever the server still holds between the lost cursor and that page.
    @Test func anExpiredCursorWithoutAStampRestartsAtTheNewestPage() async throws {
        try await fixture { store async throws in
            _ = try await store.saveArchiveCheckpoint(accountID: account, archiveID: account, expectedRevision: nil, cursor: "lost")
            _ = try await store.saveArchiveBackfillCursor(accountID: account, archiveID: account, expectedRevision: nil, oldestID: "first", complete: true)
            let trace = Trace()
            let operations = ArchiveSyncOperations(knownRooms: { [] }, refreshRoom: { _ in },
                fetchPage: { bound, _ in
                    await trace.record("fetch:\(describe(bound))")
                    switch bound {
                    case .after("lost"): throw XMPPIQError.stanza(condition: "item-not-found")
                    case .before(nil): return page(["m5", "m6"], sequence: 1, complete: false)
                    default: return emptyPage
                    }
                },
                process: { _ in }, acknowledge: { _ in }, disconnect: { await trace.record("disconnect") }, progress: { _ in })
            #expect(try await ArchiveSynchronizer(store: store).synchronize(account: account, operations: operations).isComplete)
            #expect(await trace.events == ["fetch:after(lost)", "fetch:before(nil)", "fetch:after(m6)"])
            #expect(try await store.archiveCheckpoint(accountID: account, archiveID: account) ==
                    ArchiveCheckpoint(revision: 2, cursor: "m6", stamp: Date(timeIntervalSince1970: 100)))
            #expect(try await store.archiveBackfillCursor(accountID: account, archiveID: account) == ArchiveBackfillCursor(revision: 2, oldestID: "m5", complete: false))
            #expect(try await ArchiveSynchronizer(store: store).hasPendingBackfill(account: account, archive: nil))
            #expect(try await store.archiveGaps(accountID: account).map(\.since) == [nil])
        }
    }

    /// A refused, repeated-unknown or unanswered query carries no page and no tokens: the archive stays behind its
    /// checkpoint for the next connection, the connection and the other archives carry on.
    @Test func archiveQueriesWithoutAPageEndOnlyTheirArchive() async throws {
        let failures: [any Error] = [XMPPIQError.stanza(condition: "service-unavailable"), XMPPIQError.stanza(condition: "item-not-found"),
                                     XMPPClientError.timedOut]
        for failure in failures {
            try await fixture { store async throws in
                let other = "other@rooms.localhost", silent = "silent@rooms.localhost"
                for archive in [account, room, other] {
                    _ = try await store.saveArchiveCheckpoint(accountID: account, archiveID: archive, expectedRevision: nil, cursor: "c-" + archive, stamp: Date(timeIntervalSince1970: 50))
                }
                let trace = Trace()
                let operations = ArchiveSyncOperations(knownRooms: { [room, silent, other] },
                    refreshRoom: { if $0 == silent { throw XMPPClientError.timedOut } },
                    fetchPage: { bound, selected in
                        await trace.record("fetch:\(selected ?? account):\(describe(bound))")
                        guard selected == other else { throw failure }
                        return page("o1", sequence: 1)
                    },
                    process: { _ in }, acknowledge: { _ in }, disconnect: { await trace.record("disconnect") }, progress: { _ in })
                let outcome = try await ArchiveSynchronizer(store: store).synchronize(account: account, operations: operations)
                #expect(outcome == ArchiveSyncOutcome(ownArchiveComplete: false, unfinishedRooms: [room, silent]))
                // item-not-found re-anchors once by time, and a second refusal ends the archive rather than looping.
                let retried = (failure as? XMPPIQError) == .stanza(condition: "item-not-found")
                #expect(await trace.events == ["fetch:\(account):after(c-\(account))"] + (retried ? ["fetch:\(account):since(48)"] : [])
                        + ["fetch:\(room):after(c-\(room))"] + (retried ? ["fetch:\(room):since(48)"] : []) + ["fetch:\(other):after(c-\(other))"])
                #expect(try await store.archiveCheckpoint(accountID: account, archiveID: account)?.cursor == "c-" + account)
                #expect(try await store.archiveCheckpoint(accountID: account, archiveID: room)?.cursor == "c-" + room)
                #expect(try await store.archiveCheckpoint(accountID: account, archiveID: other)?.cursor == "o1")
            }
        }
    }

    /// A lost connection fails the pending query with `timedOut`, like the query's own deadline. With the connection
    /// gone, the walk must not report a finished catch-up for the app to build on.
    @Test func aTimeoutFromALostConnectionEndsTheWholeWalk() async throws {
        try await fixture { store async throws in
            _ = try await store.saveArchiveCheckpoint(accountID: account, archiveID: account, expectedRevision: nil, cursor: "c1", stamp: Date(timeIntervalSince1970: 50))
            let trace = Trace()
            let operations = ArchiveSyncOperations(knownRooms: { [room] }, refreshRoom: { _ in },
                fetchPage: { _, selected in
                    await trace.record("fetch:\(selected ?? account)")
                    throw XMPPClientError.timedOut
                },
                process: { _ in }, acknowledge: { _ in }, disconnect: { await trace.record("disconnect") }, progress: { _ in },
                isOnline: { false })
            await #expect(throws: XMPPClientError.timedOut) { try await ArchiveSynchronizer(store: store).synchronize(account: account, operations: operations) }
            #expect(await trace.events == ["fetch:\(account)", "disconnect"])
            #expect(try await store.archiveCheckpoint(accountID: account, archiveID: account)?.cursor == "c1")
        }
    }

    @Test func aRefusedFirstPageCommitDisconnectsWithoutAcknowledging() async throws {
        try await fixture { store async throws in
            // The checkpoint already exists for this archive (a concurrent first sync won): the newest-page write is refused
            // (`saveNewestArchivePage` owns what it leaves behind), so the page's tokens stay unhandled and the stream ends.
            let trace = Trace()
            let operations = ArchiveSyncOperations(knownRooms: { [] }, refreshRoom: { _ in },
                fetchPage: { bound, _ in
                    if bound == .before(nil) {
                        _ = try await store.saveArchiveCheckpoint(accountID: account, archiveID: account, expectedRevision: nil, cursor: "c1")
                        return page(["n1", "n2"], sequence: 1, complete: false)
                    }
                    return emptyPage
                },
                process: { _ in }, acknowledge: { _ in await trace.record("ack") }, disconnect: { await trace.record("disconnect") }, progress: { _ in })
            await #expect(throws: MessageStoreError.invalidTransition) {
                try await ArchiveSynchronizer(store: store).synchronize(account: account, operations: operations)
            }
            #expect(await trace.events == ["disconnect"])
        }
    }
}

func describe(_ bound: XMPPArchiveBound) -> String {
    switch bound {
    case .after(let id): "after(\(id ?? "nil"))"
    case .before(let id): "before(\(id ?? "nil"))"
    case .since(let date): "since(\(Int(date.timeIntervalSince1970)))"
    }
}

actor BoundLog {
    var values: [XMPPArchiveBound] = []
    func append(_ value: XMPPArchiveBound) { values.append(value) }
}

private actor ProgressLog {
    var values: [ArchiveSyncProgress] = []
    func append(_ value: ArchiveSyncProgress) { values.append(value) }
}

private actor Trace {
    var events: [String] = []
    func record(_ value: String) { events.append(value) }
    func refresh(_ room: String) throws { events.append("refresh:" + room) }
}
