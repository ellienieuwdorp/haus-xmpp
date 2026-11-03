import Foundation
import os
import XMPPProtocol

// Durations and counts only, never addresses or content. Steps report from their own tasks, reloads and notification
// work from the main actor.
final class SyncPhaseTimings: Sendable {
    enum Phase: String {
        case features, carbons, uploads, keys, rejoin, walk, retry, reload, notify
    }

    private let totals = OSAllocatedUnfairLock(initialState: (durations: [Phase: Duration](), counts: [Phase: Int]()))

    func add(_ phase: Phase, since start: ContinuousClock.Instant) {
        let elapsed = ContinuousClock.now - start
        totals.withLock { $0.durations[phase, default: .zero] += elapsed; $0.counts[phase, default: 0] += 1 }
    }

    func measure<T>(_ phase: Phase, _ body: () async throws -> T) async rethrows -> T {
        let start = ContinuousClock.now
        defer { add(phase, since: start) }
        return try await body()
    }

    func summary(_ phases: [Phase]) -> String {
        let t = totals.withLock { $0 }
        var fields = phases.compactMap { phase in t.durations[phase].map { "\(phase.rawValue)_ms=\(Self.ms($0))" } }
        if phases.contains(.reload) { fields.append("reloads=\(t.counts[.reload] ?? 0)") }
        return fields.joined(separator: " ")
    }

    static func ms(_ duration: Duration) -> Int { Int(duration / .milliseconds(1)) }

    struct ConnectPhases {
        private var connecting, authenticating, binding: ContinuousClock.Instant?

        mutating func mark(_ state: XMPPConnectionState) {
            switch state {
            case .connecting: self = ConnectPhases(); connecting = .now
            case .authenticating: authenticating = .now
            case .binding: binding = .now
            case .online, .disconnected: break
            }
        }

        func summary(online: ContinuousClock.Instant) -> String {
            guard let connecting, let authenticating else { return "" }
            var text = " connect_ms=\(SyncPhaseTimings.ms(authenticating - connecting)) auth_ms=\(SyncPhaseTimings.ms((binding ?? online) - authenticating))"
            if let binding { text += " bind_ms=\(SyncPhaseTimings.ms(online - binding))" }
            return text
        }
    }
}

extension ConnectionSetup.Operations {
    func timed(by timings: SyncPhaseTimings) -> Self {
        var timed = self
        let base = self
        timed.features = { try await timings.measure(.features) { try await base.features() } }
        timed.enableCarbons = { try await timings.measure(.carbons) { try await base.enableCarbons() } }
        timed.discoverUploads = { await timings.measure(.uploads) { await base.discoverUploads() } }
        timed.initializeEncryption = { try await timings.measure(.keys) { try await base.initializeEncryption() } }
        timed.rejoinGroups = { try await timings.measure(.rejoin) { try await base.rejoinGroups() } }
        timed.catchUp = { progress in try await timings.measure(.walk) { try await base.catchUp(progress) } }
        timed.retryPending = { await timings.measure(.retry) { await base.retryPending() } }
        return timed
    }
}
