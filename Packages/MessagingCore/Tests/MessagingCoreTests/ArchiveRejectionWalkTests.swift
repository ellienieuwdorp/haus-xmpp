import Foundation
import Testing
import MessageStore
import OMEMO
@testable import XMPPProtocol
@testable import MessagingCore

// An oversized own-archive entry and a room entry nesting a wrapper are recorded rejections: each page commits, its
// checkpoint moves past them, and nothing becomes a message.
struct ArchiveRejectionWalkTests {
    private let account = "alice@localhost"
    private let room = "team@rooms.localhost"

    private actor Log {
        var events: [String] = []
        func record(_ value: String) { events.append(value) }
    }

    private func fixture(_ body: (MessageStore) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "archive-rejection-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try MessageStore(url: directory.appending(path: "messages.sqlite"))
        try await store.acquireTransportOwnership()
        do { try await body(store) }
        catch { try await store.close(); try? FileManager.default.removeItem(at: directory); throw error }
        try await store.close()
        try FileManager.default.removeItem(at: directory)
    }

    private static func rejected(_ id: String, _ reason: XMPPArchiveRejection, archive: String) -> XMPPArchivePage {
        var entry = XMPPArchiveMessage(archiveID: id, timestamp: Date(timeIntervalSince1970: 100), message: nil, encryptedMessage: nil)
        entry.rejectedContent = reason
        entry.rejectionArchive = archive
        return .init(messages: [entry], complete: true, firstID: id, lastID: id, handledTokens: [.init(session: UUID(), sequence: 1)])
    }

    private let emptyPage = XMPPArchivePage(messages: [], complete: true, firstID: nil, lastID: nil, handledTokens: [])

    @Test func rejectedEntriesAdvanceTheirCheckpoints() async throws {
        try await fixture { store async throws in
            let encryption = OMEMOService(store: store, protection: try StateProtection(key: Data(repeating: 7, count: 32)))
            let sync = ArchiveSynchronizer(store: store), client = XMPPClient(labCertificateAuthority: nil)
            let log = Log()
            let operations = ArchiveSyncOperations(knownRooms: { [room] }, refreshRoom: { _ in },
                fetchPage: { bound, selected in
                    guard bound == .before(nil) else { return emptyPage }
                    return selected == nil ? Self.rejected("big", .oversizedContent, archive: account)
                        : Self.rejected("nest", .unsupportedDirectContent, archive: room)
                },
                process: { try await sync.process(account: account, archived: $0, encryption: encryption, transport: client) },
                acknowledge: { _ in await log.record("ack") }, disconnect: { await log.record("disconnect") }, progress: { _ in })
            try await sync.synchronize(account: account, operations: operations)
            #expect(await log.events == ["ack", "ack"])
            #expect(try await store.archiveCheckpoint(accountID: account, archiveID: account)?.cursor == "big")
            #expect(try await store.archiveCheckpoint(accountID: account, archiveID: room)?.cursor == "nest")
            #expect(try await store.hasArchiveRejection(accountID: account, archiveID: account, messageID: "big"))
            #expect(try await store.hasArchiveRejection(accountID: account, archiveID: room, messageID: "nest"))
            #expect(try await store.chats(accountID: account).isEmpty)
            #expect(ArchiveSynchronizer.unreadableReason(for: .oversizedContent) == nil)
        }
    }
}
