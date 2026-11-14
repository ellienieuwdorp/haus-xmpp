import Foundation
import MessageStore
import OMEMO
import XMPPProtocol
@testable import MessagingCore

// From the environment: HAUS_SYNC_BENCH (the work directory with fixture.json and the snapshots), HAUS_LAB_CA (PEM),
// HAUS_SYNC_BENCH_RTT (relay round trip in ms, default 100), HAUS_SYNC_BENCH_QUICK=1 (fresh, resume and send only) and
// HAUS_SYNC_BENCH_PROVISION (build the identities, trust, rooms, seeded archive and snapshots instead).
struct SyncBenchEnvironment {
    static let values = ProcessInfo.processInfo.environment
    static var enabled: Bool { values["HAUS_SYNC_BENCH"] != nil && values["HAUS_SYNC_BENCH_PROVISION"] == nil }
    static var provisioning: Bool { values["HAUS_SYNC_BENCH"] != nil && values["HAUS_SYNC_BENCH_PROVISION"] != nil }
    static var full: Bool { enabled && (values["HAUS_SYNC_BENCH_QUICK"] ?? "0") == "0" }

    let directory: URL
    let fixture: SyncBenchFixture
    let authority: Data
    let oneWayMilliseconds: Int

    init() throws {
        let path = try Self.require("HAUS_SYNC_BENCH")
        directory = URL(fileURLWithPath: path, isDirectory: true)
        fixture = try JSONDecoder().decode(SyncBenchFixture.self, from: Data(contentsOf: directory.appending(path: "fixture.json")))
        let pem = try String(contentsOfFile: try Self.require("HAUS_LAB_CA"), encoding: .utf8)
        guard let authority = Data(base64Encoded: pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()) else {
            throw SyncBenchFailure.configuration("HAUS_LAB_CA is not a PEM certificate")
        }
        self.authority = authority
        oneWayMilliseconds = (Self.values["HAUS_SYNC_BENCH_RTT"].flatMap(Int.init) ?? 100) / 2
    }

    private static func require(_ key: String) throws -> String {
        guard let value = values[key], !value.isEmpty else { throw SyncBenchFailure.configuration("\(key) is not set") }
        return value
    }

    func snapshot(_ name: String) -> URL { directory.appending(path: "snapshots/\(name)", directoryHint: .isDirectory) }
    var senderStore: URL { directory.appending(path: "sender", directoryHint: .isDirectory) }
    var peerStore: URL { directory.appending(path: "peer", directoryHint: .isDirectory) }
    var results: URL { directory.appending(path: "results", directoryHint: .isDirectory) }
}

enum SyncBenchFailure: Error, CustomStringConvertible {
    case configuration(String)
    case timedOut(String)
    var description: String {
        switch self {
        case .configuration(let detail): "syncbench configuration: \(detail)"
        case .timedOut(let what): "syncbench timed out waiting for \(what)"
        }
    }
}

// Disposable lab accounts and rooms; `app` is measured, `sender` sends, and `peer` seeds the archive and is the account
// the notification extension wakes for.
struct SyncBenchFixture: Codable {
    struct Account: Codable {
        let jid: String
        let password: String
        var localpart: String { String(jid.prefix { $0 != "@" }) }
        var domain: String { String(jid.split(separator: "@").last ?? "") }
    }
    let app: Account
    let sender: Account
    let peer: Account
    let rooms: [String]
    let resource: String
    // Synthetic wrapping key of these disposable stores.
    static let key = Data(repeating: 21, count: 32)
    static let catchUpMessages = 300
}

// The benchmark measures real time; every reading of the clock goes through here.
enum SyncBenchClock {
    // swiftlint:disable:next no_wall_clock_in_tests - a benchmark measures real time
    static func now() -> ContinuousClock.Instant { ContinuousClock.now }

    static func milliseconds(_ from: ContinuousClock.Instant, _ to: ContinuousClock.Instant?) -> Int? {
        to.map { Int(($0 - from) / .milliseconds(1)) }
    }

    static func pause(_ duration: Duration) async {
        // A cancelled pause only ends a wait early; the wait's own deadline still holds.
        // swiftlint:disable:next no_wall_clock_in_tests - a benchmark waits on a real server
        try? await Task.sleep(for: duration)
    }

    static func cpuMilliseconds() -> Int {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let micros = (Int(usage.ru_utime.tv_sec) + Int(usage.ru_stime.tv_sec)) * 1_000_000
            + Int(usage.ru_utime.tv_usec) + Int(usage.ru_stime.tv_usec)
        return micros / 1000
    }
}

// One scenario's numbers: milliseconds and round trips to each named point, and totals over the whole scenario.
struct SyncBenchResult: Codable {
    var scenario: String
    var wallMs: [String: Int] = [:]
    var roundTrips: [String: Int] = [:]
    var totals = SyncBenchProxy.Counts()
    var cpuMs = 0
    var phasesMs: [String: Int] = [:]
    var values: [String: Int] = [:]
    var passed: Bool?

    func write(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appending(path: "\(scenario).json"))
    }
}

// The store a scenario works on: a fresh copy of a snapshot, or the sender's own store in place.
struct SyncBenchStore {
    let url: URL
    let store: MessageStore
    let encryption: OMEMOService

    static func restore(_ snapshot: URL) throws -> SyncBenchStore {
        let directory = FileManager.default.temporaryDirectory.appending(path: "syncbench-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: snapshot, to: directory)
        return try open(directory)
    }

    static func open(_ directory: URL) throws -> SyncBenchStore {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "messages.sqlite")
        let store = try MessageStore(url: url)
        return SyncBenchStore(url: directory, store: store, encryption: OMEMOService(store: store, protection: try StateProtection(key: SyncBenchFixture.key)))
    }

    func close(removing: Bool) async throws {
        try await store.close()
        if removing { try FileManager.default.removeItem(at: url) }
    }
}
