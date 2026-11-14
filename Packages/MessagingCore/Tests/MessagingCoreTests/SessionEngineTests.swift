import Foundation
import MessageStore
import OMEMO
import Testing
import XMPPProtocol
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

    @Test func theEndOfTheWalkAsksForAnOutboxPass() async throws {
        let recorder = Recorder()
        let engine = try engine(recorder)
        let url = FileManager.default.temporaryDirectory.appending(path: "walk-end-\(UUID()).sqlite")
        let store = try MessageStore(url: url)
        let encryption = OMEMOService(store: store, protection: try StateProtection(key: Data(repeating: 7, count: 32)))
        let connection = SessionEngine.Connection(account: "alice@localhost", client: XMPPClient(), encryption: encryption, store: store,
                                                  token: engine.generation)
        engine.catchingUp(CatchUpProgress(archive: nil, pages: 1, messages: 1), connection)
        #expect(!engine.outboxRequested)
        engine.catchingUp(nil, connection)
        // Without the lease the request waits for the next ready connection, as any other does.
        #expect(engine.outboxRequested)
        try await store.close()
        try? FileManager.default.removeItem(at: url)
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
        _ = await stopped.value
        #expect(engine.quiescing, "refused until the foreground")
        #expect(engine.backgroundPhase == .background)
        #expect(recorder.resets == 1)
        #expect(!engine.resumeForeground(), "no stream was kept")
        #expect(!engine.quiescing)
    }
}
