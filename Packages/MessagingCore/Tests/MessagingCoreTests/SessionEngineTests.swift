import Foundation
import Testing
@testable import MessagingCore

@MainActor struct SessionEngineTests {
    private final class Recorder: SessionEngineDelegate {
        var resets = 0
        var wantsTransport = true
        func sessionEngineDidReset() { resets += 1 }
    }

    private func engine(_ recorder: Recorder) throws -> SessionEngine {
        let suite = "SessionEngineTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let engine = SessionEngine(profiles: ServerProfileMemory(defaults: defaults))
        engine.delegate = recorder
        return engine
    }

    @Test func aResetInvalidatesTheGenerationAndClearsWhatTheConnectionShowed() throws {
        let recorder = Recorder()
        let engine = try engine(recorder)
        engine.isReady = true
        engine.archiveWalkFinished = true
        let token = engine.generation
        #expect(engine.resetConnection() == nil)
        #expect(engine.generation != token)
        #expect(!engine.isReady && !engine.archiveWalkFinished)
        #expect(recorder.resets == 1)
    }

    @Test func aBackgroundRequestStartsNoOutboxPassAndKeepsTheRequest() throws {
        let recorder = Recorder()
        let engine = try engine(recorder)
        engine.hasTransportOwnership = true
        engine.isReady = true
        recorder.wantsTransport = false
        engine.backgroundRequested()
        engine.startOutbox()
        #expect(engine.quiescing)
        #expect(engine.drainTask == nil)
        #expect(engine.outboxRequested && !engine.outboxIdle)
    }

    @Test func enteringTheBackgroundWaitsForOutsideCryptoWorkBeforeItReturns() async throws {
        let recorder = Recorder()
        let engine = try engine(recorder)
        engine.activeOperations = 1
        let stopped = Task { await engine.enterBackground() }
        for _ in 0..<20 { await Task.yield() }
        #expect(engine.quiescing, "still joining the operation")
        engine.activeOperations = 0
        await stopped.value
        #expect(!engine.quiescing)
        #expect(recorder.resets == 1)
    }
}
