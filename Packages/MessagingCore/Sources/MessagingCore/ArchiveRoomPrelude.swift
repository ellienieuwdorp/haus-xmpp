import MessageStore
import os
import XMPPProtocol

extension ArchiveSynchronizer {
    // `unchanged`: the newest entry is the checkpoint. `empty`: never walked, or the checkpoint's cursor is gone. Only
    // these skip the walk; anything else, a failed probe included, walks the room, which classifies the failure.
    enum RoomProbe: Sendable, Equatable {
        case unchanged
        case empty(ArchiveCheckpoint?)
        case unknown
    }

    struct RoomPrelude: Sendable {
        let refresh: Result<Void, any Error>
        let probe: RoomProbe
    }

    // Every room at once: its refresh, which a later join confirms with one read, and its probe. Probe results are never
    // processed and move no cursor, so acknowledging them owes nothing; a failed acknowledgement ends the walk.
    func prepareRooms(account: String, rooms: [String], operations: ArchiveSyncOperations) async throws -> [String: RoomPrelude] {
        guard operations.newestEntry != nil, !rooms.isEmpty else { return [:] }
        return try await withThrowingTaskGroup(of: (String, RoomPrelude).self) { group in
            for room in rooms {
                group.addTask {
                    async let refresh: Result<Void, any Error> = {
                        do { return .success(try await operations.refreshRoom(room)) } catch { return .failure(error) }
                    }()
                    let probe = try await probeRoom(account: account, room: room, operations: operations)
                    return (room, RoomPrelude(refresh: await refresh, probe: probe))
                }
            }
            var prepared: [String: RoomPrelude] = [:]
            for try await (room, prelude) in group { prepared[room] = prelude }
            return prepared
        }
    }

    private func probeRoom(account: String, room: String, operations: ArchiveSyncOperations) async throws -> RoomProbe {
        guard let newestEntry = operations.newestEntry else { return .unknown }
        let checkpoint = try await store.archiveCheckpoint(accountID: account, archiveID: room)
        let newest: XMPPArchiveNewest
        do { newest = try await newestEntry(room) } catch {
            if error is CancellationError { throw error }
            Self.log.notice("room probe failed, walking: \(Self.describe(error), privacy: .public)")
            return .unknown
        }
        if !newest.handledTokens.isEmpty { try await operations.acknowledge(newest.handledTokens) }
        guard let id = newest.id else { return .empty(checkpoint) }
        return checkpoint.map { $0.cursor == id } == true ? .unchanged : .unknown
    }

    // An empty archive records what the walk's empty newest page would: never walked, that the archive was empty;
    // under a checkpoint, what it finds once the cursor is refused and re-anchored, a possible gap (once per cursor).
    func walkIsProvenEmpty(account: String, room: String, probe: RoomProbe?) async throws -> Bool {
        switch probe {
        case .unchanged?:
            return true
        case .empty(nil)?:
            try await store.recordEmptyArchive(accountID: account, archiveID: room)
            return true
        case .empty(let checkpoint?)?:
            try await store.recordArchiveGap(accountID: account, archiveID: room, cursor: checkpoint.cursor, since: checkpoint.stamp)
            Self.log.notice("room archive empty under its checkpoint; recorded as a possible gap")
            return true
        case .unknown?, nil:
            return false
        }
    }
}
