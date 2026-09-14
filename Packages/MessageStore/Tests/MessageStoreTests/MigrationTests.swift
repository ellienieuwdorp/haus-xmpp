import Foundation
import Darwin
import Testing
@testable import MessageStore

struct MigrationTests {
    @Test func migrationClosesSQLiteAndHoldsLockAcrossRename() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "migration-\(UUID())")
        let source = root.appending(path: "old"), destination = root.appending(path: "new")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let db = source.appending(path: "messages.sqlite")
        let store = try MessageStore(url: db)
        try await store.acquireTransportOwnership()
        try await store.saveEncryptionState(accountID: "synthetic", expectedRevision: nil, data: Data([7, 8, 9]))
        try await store.closeForMigration {
            // Closing the final SQLite connection checkpoints committed data. Some Apple
            // SQLite builds retain WAL files, so verify a main-file-only copy instead.
            try FileManager.default.copyItem(at: db, to: root.appending(path: "checkpoint.sqlite"))
            try FileManager.default.moveItem(at: source, to: destination)
            let descriptor = Darwin.open(destination.appending(path: "messages.sqlite.transport-lock").path, O_RDWR | O_NOFOLLOW)
            #expect(descriptor >= 0)
            defer { Darwin.close(descriptor) }
            #expect(flock(descriptor, LOCK_EX | LOCK_NB) == -1)
            #expect(errno == EWOULDBLOCK)
        }
        await #expect(throws: MessageStoreError.closed) { try await store.encryptionState(accountID: "synthetic") }
        let checkpoint = try MessageStore(url: root.appending(path: "checkpoint.sqlite"))
        #expect(try await checkpoint.encryptionState(accountID: "synthetic")?.data == Data([7, 8, 9]))
        try await checkpoint.close()
        let moved = try MessageStore(url: destination.appending(path: "messages.sqlite"))
        try await moved.acquireTransportOwnership()
        #expect(try await moved.encryptionState(accountID: "synthetic")?.data == Data([7, 8, 9]))
        try await moved.close()
        try await store.close()
        try FileManager.default.removeItem(at: root)
    }

    @Test func failedMoveLeavesClosedSourceRecoverableAndUnlocked() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "migration-failure-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let db = directory.appending(path: "messages.sqlite")
        let store = try MessageStore(url: db)
        try await store.acquireTransportOwnership()
        await #expect(throws: MessageStoreError.invalidValue) {
            try await store.closeForMigration { throw MessageStoreError.invalidValue }
        }
        let reopened = try MessageStore(url: db)
        try await reopened.acquireTransportOwnership()
        try await reopened.close()
        try await store.close()
        try FileManager.default.removeItem(at: directory)
    }
}
