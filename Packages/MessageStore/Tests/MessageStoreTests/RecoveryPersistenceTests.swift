import Foundation
import Testing
import Darwin
import CSQLite
@testable import MessageStore

private func recoveryURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: "messages.sqlite")
}

private func queue(_ store: MessageStore, account: String = "a", id: String = "m") async throws {
    try await store.upsertChat(accountID: account, chatID: "peer", title: "Peer")
    try await store.enqueueOutgoing(StoredMessage(id: id, accountID: account, chatID: "peer", senderID: account, body: "secret", isOutgoing: true))
}

@Test func openingConcurrentReaderNeverRecoversActiveTransportAndStaleOwnerCannotClaim() async throws {
    let url = try recoveryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let first = try MessageStore(url: url)
    try await queue(first)
    await #expect(throws: MessageStoreError.transportOwnershipRequired) { try await first.claimNextOutgoing(accountID: "a") }
    try await first.acquireTransportOwnership()
    let claim = try #require(await first.claimNextOutgoing(accountID: "a"))
    let reader = try MessageStore(url: url)
    #expect(try await reader.messages(accountID: "a", chatID: "peer").first?.transportState == .submitting)
    await #expect(throws: MessageStoreError.transportOwnedElsewhere) { try await reader.acquireTransportOwnership() }
    await #expect(throws: MessageStoreError.transportOwnershipRequired) { try await reader.recoverInterruptedSubmissions(accountID: "a") }
    try await first.releaseTransportOwnership()
    try await reader.acquireTransportOwnership()
    try await reader.retryOutgoing(accountID: "a", messageID: "m")
    let next = try #require(await reader.claimNextOutgoing(accountID: "a"))
    await #expect(throws: MessageStoreError.transportOwnershipRequired) { try await first.finishOutgoingSubmission(claim) }
    #expect(try await reader.messages(accountID: "a", chatID: "peer").first?.transportState == .submitting)
    #expect(try await !reader.finishOutgoingSubmission(claim))
    #expect(try await reader.finishOutgoingSubmission(next))
}

@Test func kernelOwnershipCoordinatesAnotherProcessAndReleasesAfterCrash() async throws {
    let url = try recoveryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try MessageStore(url: url)
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    child.arguments = ["-c", """
        import fcntl,sys,time
        handle=open(sys.argv[1], 'a')
        fcntl.flock(handle,fcntl.LOCK_EX|fcntl.LOCK_NB)
        sys.stdout.write('1');sys.stdout.flush()
        time.sleep(30)
        """, url.path + ".transport-lock"]
    let pipe = Pipe()
    child.standardOutput = pipe
    try child.run()
    defer { if child.isRunning { kill(child.processIdentifier, SIGKILL) }; child.waitUntilExit() }
    #expect(try pipe.fileHandleForReading.read(upToCount: 1) == Data("1".utf8))
    await #expect(throws: MessageStoreError.transportOwnedElsewhere) { try await store.acquireTransportOwnership() }
    kill(child.processIdentifier, SIGKILL)
    child.waitUntilExit()
    try await store.acquireTransportOwnership()
    // A new process also cannot acquire a lock already held by this process.
    let contender = Process()
    contender.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    contender.arguments = ["-c", """
        import fcntl,sys
        handle=open(sys.argv[1], 'a')
        try: fcntl.flock(handle,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError: sys.exit(23)
        sys.exit(0)
        """, url.path + ".transport-lock"]
    try contender.run()
    contender.waitUntilExit()
    #expect(contender.terminationStatus == 23)
}

@Test func durableStreamAckIsAtomicMonotonicAccountScopedAndFencesStaleSnapshots() async throws {
    let url = try recoveryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try MessageStore(url: url)
    try await store.acquireTransportOwnership()
    try await queue(store)
    try await queue(store, account: "b")
    let attempt = try #require(await store.claimNextOutgoing(accountID: "a"))
    let exactStanza = Data("<message><encrypted>exact persisted ciphertext</encrypted></message>".utf8)
    #expect(try await store.saveStreamManagement(accountID: "a", expectedRevision: nil, data: exactStanza) == 1)
    await #expect(throws: MessageStoreError.invalidTransition) {
        try await store.saveStreamManagement(accountID: "a", expectedRevision: 0, data: Data([9]), acknowledgedMessageIDs: ["m"])
    }
    #expect(try await store.messages(accountID: "a", chatID: "peer").first?.transportState == .submitting)
    #expect(try await store.streamManagementState(accountID: "a")?.data == exactStanza)
    #expect(try await store.saveStreamManagement(accountID: "a", expectedRevision: 1, data: Data([2]), acknowledgedMessageIDs: ["m", "unknown"]) == 2)
    #expect(try await !store.finishOutgoingSubmission(attempt)) // acknowledgement beat socket callback
    #expect(try await !store.releaseUnsentSubmission(attempt))
    try await store.recoverInterruptedSubmissions(accountID: "a")
    await #expect(throws: MessageStoreError.invalidTransition) { try await store.retryOutgoing(accountID: "a", messageID: "m") }
    #expect(try await store.messages(accountID: "a", chatID: "peer").first?.transportState == .serverAccepted)
    #expect(try await store.messages(accountID: "b", chatID: "peer").first?.transportState == .queued)
    let reader = try MessageStore(url: url)
    #expect(try await reader.streamManagementState(accountID: "a")?.revision == 2)
    #expect(try await reader.messages(accountID: "a", chatID: "peer").first?.transportState == .serverAccepted)
}

@Test func archiveProgressCannotRegressAcrossOwnersOrAccounts() async throws {
    let url = try recoveryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let first = try MessageStore(url: url)
    try await first.acquireTransportOwnership()
    #expect(try await first.saveArchiveCheckpoint(accountID: "a", archiveID: "a", expectedRevision: nil, cursor: "page-one") == 1)
    #expect(try await first.saveArchiveCheckpoint(accountID: "a", archiveID: "a", expectedRevision: 1, cursor: "page-two") == 2)
    await #expect(throws: MessageStoreError.invalidTransition) {
        try await first.saveArchiveCheckpoint(accountID: "a", archiveID: "a", expectedRevision: 1, cursor: "stale-page")
    }
    try await first.releaseTransportOwnership()
    let next = try MessageStore(url: url)
    try await next.acquireTransportOwnership()
    #expect(try await next.archiveCheckpoint(accountID: "a", archiveID: "a")?.cursor == "page-two")
    #expect(try await next.archiveCheckpoint(accountID: "b", archiveID: "a") == nil)
    #expect(try await next.archiveCheckpoint(accountID: "a", archiveID: "room") == nil)
    await #expect(throws: MessageStoreError.transportOwnershipRequired) {
        try await first.saveArchiveCheckpoint(accountID: "a", archiveID: "a", expectedRevision: 2, cursor: "stale-owner")
    }
    #expect(try await next.saveArchiveCheckpoint(accountID: "a", archiveID: "a", expectedRevision: 2, cursor: "page-three") == 3)
}

@Test func controlAndCryptoStateCommitTogetherAndOpenCannotResetClaim() async throws {
    let url = try recoveryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try MessageStore(url: url)
    try await store.acquireTransportOwnership()
    let control = EncryptionControl(id: "key-transport", recipient: "peer", wire: Data([1, 2, 3]))
    try await store.saveEncryptionState(accountID: "a", expectedRevision: nil, data: Data([1]), control: control)
    await #expect(throws: MessageStoreError.self) {
        try await store.saveEncryptionState(accountID: "a", expectedRevision: 1, data: Data([2]), control: control)
    }
    #expect(try await store.encryptionState(accountID: "a")?.revision == 1)
    #expect(try await store.claimEncryptionControl(accountID: "a")?.wire == control.wire)
    let reader = try MessageStore(url: url)
    #expect(try await store.claimEncryptionControl(accountID: "a") == nil)
    #expect(try await reader.encryptionState(accountID: "a")?.data == Data([1]))
    try await store.finishEncryptionControl(accountID: "a", id: control.id)
    #expect(try await store.claimEncryptionControl(accountID: "a") == nil)
}

@Test func migrationV4PreservesCiphertextTrustHistoryAndActiveClaim() async throws {
    let url = try recoveryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try MessageStore(url: url)
    try await store.acquireTransportOwnership()
    try await queue(store)
    try await store.setPinned(accountID: "a", chatID: "peer", pinned: true)
    try await store.setStarred(accountID: "a", messageID: "m", starred: true)
    let trustAndIdentity = Data("opaque identity, trust, ratchets".utf8)
    try await store.saveEncryptionState(accountID: "a", expectedRevision: nil, data: trustAndIdentity)
    try await store.sealQueuedOutgoing(accountID: "a", messageID: "m", profile: "modern", expectedRevision: 1,
                                       state: trustAndIdentity, wire: Data([7, 8, 9]))
    let attempt = try #require(await store.claimNextOutgoing(accountID: "a"))
    // Reconstruct the previous outbox CHECK and remove the two new v5-only tables.
    var db: OpaquePointer?
    #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
    let sql = """
        BEGIN IMMEDIATE;
        ALTER TABLE outbox RENAME TO outbox_new;
        CREATE TABLE outbox(sequence INTEGER PRIMARY KEY AUTOINCREMENT,account_id TEXT NOT NULL,message_id TEXT NOT NULL,
        state TEXT NOT NULL CHECK(state IN ('queued','submitting','unconfirmed','failed')),attempt_id TEXT,
        UNIQUE(account_id,message_id),FOREIGN KEY(account_id,message_id) REFERENCES messages(account_id,id));
        INSERT INTO outbox SELECT * FROM outbox_new;
        DROP TABLE outbox_new;
        CREATE INDEX outbox_queue ON outbox(account_id,state,sequence);
        DROP TABLE stream_management;
        DROP TABLE archive_checkpoints;
        DROP TABLE reaction_updates;
        DROP TABLE reaction_events;
        DROP INDEX authenticated_message_wire;
        DROP INDEX message_wire;
        ALTER TABLE messages DROP COLUMN wire_id;
        ALTER TABLE messages DROP COLUMN wire_id_authenticated;
        PRAGMA user_version=4;
        COMMIT;
        """
    #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)
    let migrated = try MessageStore(url: url)
    let chat = try #require(await migrated.chats(accountID: "a").first)
    #expect(chat.isPinned && chat.lastMessage?.isStarred == true)
    #expect(chat.lastMessage?.transportState == .submitting)
    #expect(chat.lastMessage?.wireID == nil && chat.lastMessage?.wireIDAuthenticated == false)
    #expect(try await migrated.encryptedOutgoing(accountID: "a", messageID: "m") == Data([7, 8, 9]))
    #expect(try await migrated.encryptionState(accountID: "a")?.data == trustAndIdentity)
    #expect(try await store.finishOutgoingSubmission(attempt))
}

@Test func archivedOwnCiphertextReconcilesOnlyExactAccountScopedPayloadAndFencesRetries() async throws {
    let url = try recoveryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try MessageStore(url: url)
    try await store.acquireTransportOwnership()
    let wire = Data([7, 8, 9])
    for account in ["a", "b"] {
        try await queue(store, account: account)
        try await store.saveEncryptionState(accountID: account, expectedRevision: nil, data: Data([1]))
        try await store.sealQueuedOutgoing(accountID: account, messageID: "m", profile: "modern", expectedRevision: 1, state: Data([2]), wire: account == "a" ? wire : Data([4, 5, 6]))
    }
    let original = try #require(await store.claimNextOutgoing(accountID: "a"))
    try await store.finishOutgoingSubmission(original)
    try await store.retryOutgoing(accountID: "a", messageID: "m")
    #expect(try await !store.reconcileArchivedOutgoing(accountID: "a", messageID: "m", expectedEncryptedWire: Data([0])))
    #expect(try await !store.reconcileArchivedOutgoing(accountID: "b", messageID: "m", expectedEncryptedWire: wire))
    #expect(try await !store.reconcileArchivedOutgoing(accountID: "a", messageID: "missing", expectedEncryptedWire: wire))
    #expect(try await store.message(accountID: "a", messageID: "m")?.transportState == .queued)
    #expect(try await store.reconcileArchivedOutgoing(accountID: "a", messageID: "m", expectedEncryptedWire: wire))
    #expect(try await store.claimNextOutgoing(accountID: "a") == nil)
    #expect(try await !store.finishOutgoingSubmission(original))
    #expect(try await !store.releaseUnsentSubmission(original))
    #expect(try await store.message(accountID: "a", messageID: "m")?.transportState == .serverAccepted)
    #expect(try await store.message(accountID: "b", messageID: "m")?.transportState == .queued)
    // Duplicate archive pages are idempotent and cannot regress acknowledgement.
    #expect(try await store.reconcileArchivedOutgoing(accountID: "a", messageID: "m", expectedEncryptedWire: wire))
    await #expect(throws: MessageStoreError.invalidTransition) { try await store.retryOutgoing(accountID: "a", messageID: "m") }
}

@Test func explicitCloseIsIdempotentRejectsFurtherAccessAndReleasesTransportBeforeUnlink() async throws {
    let url = try recoveryURL()
    let store = try MessageStore(url: url)
    try await store.acquireTransportOwnership()
    try await queue(store)
    _ = try await store.claimNextOutgoing(accountID: "a")
    try await store.close()
    try await store.close()
    await #expect(throws: MessageStoreError.closed) { try await store.chats(accountID: "a") }
    await #expect(throws: MessageStoreError.closed) { try await store.upsertChat(accountID: "a", chatID: "new", title: "New") }
    await #expect(throws: MessageStoreError.closed) { try await store.acquireTransportOwnership() }
    let reopened = try MessageStore(url: url)
    try await reopened.acquireTransportOwnership()
    #expect(try await reopened.message(accountID: "a", messageID: "m")?.transportState == .unconfirmed)
    try await reopened.close()
    // Both connections are closed before the unlink; retained actor references are harmless.
    try FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

@Test func pendingArchiveContextCorrectionUsesExactCASAndCannotResurrectConsumedCiphertext() async throws {
    let url = try recoveryURL()
    let store = try MessageStore(url: url)
    try await store.saveEncryptionState(accountID: "a", expectedRevision: nil, data: Data([1]))
    try await store.retainEncryptedIncoming(accountID: "a", sender: "peer", digest: "d", wire: Data([1]))
    #expect(try await !store.replacePendingEncryptedIncomingContext(accountID: "b", sender: "peer", digest: "d", expectedWire: Data([1]), wire: Data([2])))
    #expect(try await !store.replacePendingEncryptedIncomingContext(accountID: "a", sender: "other", digest: "d", expectedWire: Data([1]), wire: Data([2])))
    #expect(try await store.replacePendingEncryptedIncomingContext(accountID: "a", sender: "peer", digest: "d", expectedWire: Data([1]), wire: Data([2])))
    #expect(try await !store.replacePendingEncryptedIncomingContext(accountID: "a", sender: "peer", digest: "d", expectedWire: Data([1]), wire: Data([3])))
    #expect(try await store.pendingEncryptedIncoming(accountID: "a").first?.wire == Data([2]))
    try await store.commitEncryptedIncoming(accountID: "a", sender: "peer", digest: "d", expectedRevision: 1, state: Data([2]), message: nil)
    #expect(try await !store.replacePendingEncryptedIncomingContext(accountID: "a", sender: "peer", digest: "d", expectedWire: Data([2]), wire: Data([3])))
    #expect(try await store.pendingEncryptedIncoming(accountID: "a").isEmpty)
    try await store.close()
    try FileManager.default.removeItem(at: url.deletingLastPathComponent())
}
