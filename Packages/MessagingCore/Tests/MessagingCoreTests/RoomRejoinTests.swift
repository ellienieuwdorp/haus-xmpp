import Foundation
import Testing
import XMPPProtocol
@testable import MessagingCore

// Setup's rejoin pass over stand-in room operations: every room at once, each room's outcome its own, and a room a
// resume restored confirmed instead of joined.
@MainActor struct RoomRejoinTests {
    private final class Recorder: SessionEngineDelegate {
        var wantsTransport = true
        var nicknames: [String: String] = [:]
        var rejoining: [String] = [], rejoined: [String: Bool] = [:], failed: [String] = []
        func nickname(in room: String, account: String) -> String { nicknames[room] ?? "alice" }
        func roomRejoining(_ room: String, members: [String]) { rejoining.append(room) }
        func roomRejoined(_ room: String, joined: Bool) { rejoined[room] = joined }
        func roomRejoinFailed(_ room: String, error: any Error) { failed.append(room) }
    }

    // Counts what the stand-in operations were asked, and holds joins until `release`.
    private actor Rooms {
        private(set) var joins: [String: String] = [:], confirms: Set<String> = [], inFlight = 0, mostInFlight = 0
        private var held: [CheckedContinuation<Void, Never>] = [], holding: Bool
        init(holding: Bool) { self.holding = holding }
        func join(_ room: String, _ nickname: String) async {
            joins[room] = nickname
            inFlight += 1; mostInFlight = max(mostInFlight, inFlight)
            if holding { await withCheckedContinuation { held.append($0) } }
            inFlight -= 1
        }
        func confirm(_ room: String) { confirms.insert(room) }
        func release() { holding = false; held.forEach { $0.resume() }; held = [] }
    }

    private func engine(_ recorder: Recorder) throws -> SessionEngine {
        let suite = "RoomRejoinTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let engine = SessionEngine(profiles: ServerProfileMemory(defaults: defaults))
        engine.delegate = recorder
        return engine
    }

    private static func rooms(_ count: Int) -> [String: [String]] {
        Dictionary(uniqueKeysWithValues: (1...count).map { ("r\($0)@rooms.localhost", ["alice@localhost", "bob@localhost"]) })
    }

    // A pass in series would wait for each held join before starting the next and never see them all in flight.
    @Test func everyRoomJoinsAtOnceAndOneRoomsFailureEndsNoOther() async throws {
        let recorder = Recorder()
        let engine = try engine(recorder)
        let rooms = Rooms(holding: true)
        let operations = SessionEngine.RoomRejoins(confirm: { _ in true }, join: { room, nickname in
            await rooms.join(room, nickname)
            if room.hasPrefix("r2@") { throw XMPPGroupError.unsupportedRoom }
            return false
        })
        let pass = Task { try await engine.rejoin(Self.rooms(3), account: "alice@localhost", token: engine.generation, operations) }
        try await eventually("three joins in flight") { await rooms.inFlight == 3 }
        await rooms.release()
        let joined = try await bounded { try await pass.value }
        #expect(joined == ["r1@rooms.localhost", "r3@rooms.localhost"])
        #expect(Set(recorder.rejoining) == Set(Self.rooms(3).keys))
        #expect(recorder.failed == ["r2@rooms.localhost"])
        #expect(recorder.rejoined == ["r1@rooms.localhost": false, "r3@rooms.localhost": false])
        #expect(await rooms.confirms.isEmpty)
    }

    @Test func atMostEightRoomsJoinAtOnce() async throws {
        let recorder = Recorder()
        let engine = try engine(recorder)
        let rooms = Rooms(holding: true)
        let operations = SessionEngine.RoomRejoins(confirm: { _ in true }, join: { room, nickname in
            await rooms.join(room, nickname)
            return false
        })
        let pass = Task { try await engine.rejoin(Self.rooms(11), account: "alice@localhost", token: engine.generation, operations) }
        try await eventually("eight joins in flight") { await rooms.inFlight == SessionEngine.concurrentRejoins }
        await rooms.release()
        #expect(try await bounded { try await pass.value }.count == 11)
        #expect(await rooms.mostInFlight == SessionEngine.concurrentRejoins)
    }

    // The self-ping confirms a restored room under the nickname we would join with; a room that no longer counts us, or
    // a nickname changed since, joins as after a fresh bind.
    @Test func aRestoredRoomIsConfirmedWithoutAJoinAndJoinsWhenThatFails() async throws {
        let recorder = Recorder()
        recorder.nicknames = ["r3@rooms.localhost": "renamed"]
        let engine = try engine(recorder)
        let rooms = Rooms(holding: false)
        let operations = SessionEngine.RoomRejoins(
            restored: ["r1@rooms.localhost": "alice", "r2@rooms.localhost": "alice", "r3@rooms.localhost": "alice"],
            confirm: { room in
                await rooms.confirm(room)
                return room.hasPrefix("r1@")
            },
            join: { room, nickname in
                await rooms.join(room, nickname)
                return false
            })
        let joined = try await bounded { try await engine.rejoin(Self.rooms(4), account: "alice@localhost", token: engine.generation, operations) }
        #expect(joined == Set(Self.rooms(4).keys))
        #expect(await rooms.confirms == ["r1@rooms.localhost", "r2@rooms.localhost"])
        #expect(await rooms.joins == ["r2@rooms.localhost": "alice", "r3@rooms.localhost": "renamed", "r4@rooms.localhost": "alice"])
        #expect(recorder.rejoined["r1@rooms.localhost"] == true && recorder.rejoined["r2@rooms.localhost"] == false)
    }

    // Each room's outcome is reported only under the connection that asked for it.
    @Test func aPassWhoseConnectionEndedThrowsAndReportsNothingAfter() async throws {
        let recorder = Recorder()
        let engine = try engine(recorder)
        let operations = SessionEngine.RoomRejoins(confirm: { _ in true }, join: { @MainActor _, _ in
            _ = engine.resetConnection()
            return true
        })
        await #expect(throws: CancellationError.self) {
            try await engine.rejoin(Self.rooms(2), account: "alice@localhost", token: engine.generation, operations)
        }
        #expect(recorder.rejoined.isEmpty && recorder.failed.isEmpty)
        recorder.wantsTransport = false
        await #expect(throws: CancellationError.self) {
            try await engine.rejoin(Self.rooms(2), account: "alice@localhost", token: engine.generation, operations)
        }
    }
}
