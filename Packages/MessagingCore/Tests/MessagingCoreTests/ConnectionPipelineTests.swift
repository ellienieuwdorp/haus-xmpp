import Foundation
import Testing
import XMPPProtocol
@testable import MessagingCore

// Carbons go out beside discovery. The overlap is proven by a step that waits for the other, so running them one after
// the other hangs and fails after `TestClock.failsafe`.
@MainActor struct ConnectionPipelineTests {
    private actor Latch {
        private var open = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            guard !open else { return }
            await withCheckedContinuation { waiting.append($0) }
        }
        func release() {
            open = true
            waiting.forEach { $0.resume() }
            waiting = []
        }
    }

    private actor Log {
        private(set) var marks: [String] = []
        private(set) var events: [ConnectionSetup.Event] = []
        func mark(_ label: String) { marks.append(label) }
        func record(_ event: ConnectionSetup.Event) { events.append(event) }
    }

    nonisolated private static let both: Set<String> = [ConnectionSetup.carbonsFeature, ConnectionSetup.archiveFeature]

    private func operations(_ log: Log, features: Set<String> = both) -> ConnectionSetup.Operations {
        ConnectionSetup.Operations(
            features: { await log.mark("features"); return features },
            enableCarbons: { await log.mark("carbons") },
            discoverUploads: {},
            initializeEncryption: { await log.mark("initialize") },
            rejoinGroups: { await log.mark("rejoin") },
            catchUp: { _ in await log.mark("walk") },
            retryPending: { await log.mark("retry") })
    }

    private func run(_ operations: ConnectionSetup.Operations, _ log: Log, memory: ConnectionSetup.Memory = .init()) async throws {
        try await bounded {
            await ConnectionSetup(identityExists: true, memory: memory).run(operations: operations) { await log.record($0) }
        }
    }

    @Test func carbonsAreAskedBesideDiscovery() async throws {
        let log = Log(), asked = Latch()
        var operations = operations(log)
        operations.enableCarbons = { await log.mark("carbons"); await asked.release() }
        operations.features = { await asked.wait(); await log.mark("features"); return Self.both }
        try await run(operations, log)
        let marks = await log.marks, events = await log.events
        #expect(marks.prefix(2) == ["carbons", "features"])
        #expect(Array(events.prefix(2)) == [.step(ConnectionSetup.featuresStep), .step(ConnectionSetup.carbonsStep)])
        #expect(events.last == .settled)
    }

    // Unlisted, the request was a guess.
    @Test func aRefusedCarbonsRequestFailsSetupOnlyWhenTheServerListsThem() async throws {
        for listed in [false, true] {
            let log = Log()
            var operations = operations(log, features: listed ? Self.both : [ConnectionSetup.archiveFeature])
            operations.enableCarbons = { throw XMPPIQError.stanza(condition: "service-unavailable") }
            try await run(operations, log)
            let events = await log.events
            if listed {
                #expect(events.last == .failed(step: ConnectionSetup.carbonsStep, detail: "service-unavailable"))
                #expect(!events.contains(.ready))
            } else {
                #expect(events.last == .settled)
                #expect(!events.contains(.step(ConnectionSetup.carbonsStep)))
            }
        }
    }

    // Features remembered without carbons: nothing is guessed, and carbons follow only a discovery that lists them.
    @Test func rememberedFeaturesWithoutCarbonsAskOnlyAfterDiscoveryListsThem() async throws {
        let remembered = ConnectionSetup.Memory(features: [ConnectionSetup.archiveFeature])
        for discovered in [Self.both, [ConnectionSetup.archiveFeature]] {
            let log = Log()
            try await run(operations(log, features: discovered), log, memory: remembered)
            let marks = await log.marks
            if discovered.contains(ConnectionSetup.carbonsFeature) {
                #expect(marks.prefix(2) == ["features", "carbons"])
            } else {
                #expect(!marks.contains("carbons"))
            }
            #expect(await log.events.last == .settled)
        }
    }
}
