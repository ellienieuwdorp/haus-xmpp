import Foundation
import CSQLite
import Darwin
import Testing
@testable import MessageStore

// A parked store has closed SQLite, so it holds no fcntl lock on the database or its sidecars; the next call reopens
// the same file at the same schema, and only while the process allows it.
@Suite(.serialized) struct ParkingTests {
    private let account = "alice@example.org"

    private func temporaryStore() throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "parking-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appending(path: "messages.sqlite"))
    }

    // Every descriptor of this process on a file in `directory` except the transport lock's, which stays open and
    // unlocked by design. POSIX record locks belong to the process, so a file it has no descriptor on holds none.
    private func sqliteDescriptors(in directory: URL) -> Set<String> {
        guard let resolved = realpath(directory.path, nil) else { return [] }
        let prefix = String(cString: resolved) + "/"
        free(resolved)
        var found: Set<String> = []
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        for descriptor in 0..<getdtablesize() where fcntl(descriptor, F_GETPATH, &path) != -1 {
            let name = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if name.hasPrefix(prefix), !name.hasSuffix(".transport-lock") { found.insert(String(name.dropFirst(prefix.count))) }
        }
        return found
    }

    // flock conflicts between open file descriptions of one process too, so a fresh one sees the store's lease.
    private func transportLockIsFree(_ url: URL) -> Bool {
        let descriptor = open(url.path + ".transport-lock", O_RDWR | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return false }
        flock(descriptor, LOCK_UN)
        return true
    }

    private func seeded(_ url: URL) async throws -> MessageStore {
        let store = try MessageStore(url: url)
        try await store.upsertChat(accountID: account, chatID: "bob@example.org", title: "Bob")
        _ = try await store.chats(accountID: account)
        return store
    }

    @Test func aParkedStoreKeepsNoDescriptorOnTheDatabaseOrItsSidecars() async throws {
        let (directory, url) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await seeded(url)
        try await store.acquireTransportOwnership()
        try await store.releaseTransportOwnership()
        let open = sqliteDescriptors(in: directory)
        #expect(open.isSuperset(of: ["messages.sqlite", "messages.sqlite-shm"]), "the probe sees an idle WAL connection: \(open)")

        try await store.park()
        #expect(sqliteDescriptors(in: directory).isEmpty)
        #expect(transportLockIsFree(url))
        try await store.park()

        #expect(try await store.chats(accountID: account).map(\.id) == ["bob@example.org"], "the next call reopens the same file")
        #expect(sqliteDescriptors(in: directory).contains("messages.sqlite"))
        try await store.acquireTransportOwnership()
        #expect(!transportLockIsFree(url), "the lease locks the inode it always locked")
        try await store.close()
        #expect(sqliteDescriptors(in: directory).isEmpty)
    }

    @Test func parkingRefusesWhileTheLeaseIsHeld() async throws {
        let (directory, url) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await seeded(url)
        try await store.acquireTransportOwnership()
        await #expect(throws: MessageStoreError.parkingRefused) { try await store.park() }
        #expect(await store.holdsTransportOwnership)
        #expect(try await store.chats(accountID: account).count == 1)
        try await store.releaseTransportOwnership()
        try await store.park()
        #expect(sqliteDescriptors(in: directory).isEmpty)
        try await store.close()
    }

    @Test func reopeningRefusesAReplacedFileAndAnOlderSchema() async throws {
        let (directory, url) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await seeded(url)
        try await store.park()
        let copy = directory.appending(path: "copy.sqlite")
        try FileManager.default.copyItem(at: url, to: copy)
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        try FileManager.default.moveItem(at: copy, to: url)
        await #expect(throws: MessageStoreError.replaced) { try await store.chats(accountID: account) }
        await #expect(throws: MessageStoreError.replaced) { try await store.acquireTransportOwnership() }
        #expect(sqliteDescriptors(in: directory).isEmpty)
        try await store.close()

        let older = try await seeded(url)
        try await older.park()
        #expect(sqliteExecute(url: url, sql: "PRAGMA user_version=\(MessageStore.currentSchemaVersion - 1)"))
        await #expect(throws: MessageStoreError.upgradeRequired(MessageStore.currentSchemaVersion - 1)) {
            try await older.chats(accountID: account)
        }
        #expect(sqliteDescriptors(in: directory).isEmpty, "a refused reopen closes what it opened")
        #expect(sqliteRows(url: url, sql: "PRAGMA user_version") == [["\(MessageStore.currentSchemaVersion - 1)"]], "and migrates nothing")
        try await older.close()
    }

    @Test func openingAndReopeningRefuseWhileTheGateIsClosed() async throws {
        let (directory, url) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await seeded(url)
        try await store.park()
        await MessageStore.$reopeningOverride.withValue(false) {
            await #expect(throws: MessageStoreError.suspended) { try await store.chats(accountID: account) }
            await #expect(throws: MessageStoreError.suspended) { try await store.acquireTransportOwnership() }
            #expect(throws: MessageStoreError.suspended) { try MessageStore(url: url) }
            #expect(sqliteDescriptors(in: directory).isEmpty, "neither a reopen nor a new store opened SQLite")
            #expect(transportLockIsFree(url))
        }
        #expect(try await store.chats(accountID: account).count == 1)
        try await store.close()
        await #expect(throws: MessageStoreError.closed) { try await store.chats(accountID: account) }
    }

    @Test func closingAParkedStoreLeavesItClosed() async throws {
        let (directory, url) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await seeded(url)
        try await store.park()
        try await store.close()
        await #expect(throws: MessageStoreError.closed) { try await store.chats(accountID: account) }
        try await store.park()
        #expect(sqliteDescriptors(in: directory).isEmpty)
    }
}
