import OMEMO
import XCTest
import XMPPProtocol
@testable import HausXMPP

@MainActor
final class ConnectionSetupTests: XCTestCase {
    /// Parks callers until the test opens it.
    private actor Gate {
        private var isOpen = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiting.append($0) }
        }
        func open() {
            isOpen = true
            waiting.forEach { $0.resume() }
            waiting = []
        }
    }

    /// Events and marks in the order they happened.
    private actor Recorder {
        enum Entry: Equatable { case event(ConnectionSetup.Event), mark(String) }
        private(set) var entries: [Entry] = []
        func record(_ event: ConnectionSetup.Event) { entries.append(.event(event)) }
        func mark(_ label: String) { entries.append(.mark(label)) }
        var events: [ConnectionSetup.Event] { entries.compactMap { if case .event(let event) = $0 { event } else { nil } } }
        var marks: [String] { entries.compactMap { if case .mark(let label) = $0 { label } else { nil } } }
        func index(_ entry: Entry) -> Int? { entries.firstIndex(of: entry) }
        func contains(_ event: ConnectionSetup.Event) -> Bool { entries.contains(.event(event)) }
        func hasMarks(_ labels: String...) -> Bool { labels.allSatisfy { marks.contains($0) } }
    }

    private static let start = ConnectionSetup.Event.catchingUp(CatchUpProgress(archive: nil, pages: 0, messages: 0))
    private static let keys = ConnectionSetup.Event.step("publishing this phone’s keys")

    /// Everything succeeds at once unless a test replaces it; each call leaves a mark.
    private func operations(_ recorder: Recorder, features: Set<String> = [ConnectionSetup.carbonsFeature, ConnectionSetup.archiveFeature]) -> ConnectionSetup.Operations {
        ConnectionSetup.Operations(
            features: { await recorder.mark("features"); return features },
            enableCarbons: { await recorder.mark("carbons") },
            discoverUploads: { await recorder.mark("uploads") },
            initializeEncryption: { await recorder.mark("initialize") },
            rejoinGroups: { await recorder.mark("rejoin") },
            catchUp: { _ in await recorder.mark("walk-start"); await recorder.mark("walk-end") },
            retryPending: { await recorder.mark("retry") })
    }

    private func run(_ operations: ConnectionSetup.Operations, recorder: Recorder, identityExists: Bool = true) async {
        await ConnectionSetup(identityExists: identityExists).run(operations: operations) { await recorder.record($0) }
    }

    func testReadyIsPublishedWhileCatchUpStillRuns() async throws {
        let recorder = Recorder(), walk = Gate()
        var operations = operations(recorder)
        operations.catchUp = { _ in
            await recorder.mark("walk-start")
            await walk.wait()
            await recorder.mark("walk-end")
        }
        let task = Task { await run(operations, recorder: recorder) }
        // The walk is parked until after this loop, so reaching `.ready` is the proof.
        while await !recorder.contains(.ready) { await Task.yield() }
        await walk.open()
        await task.value

        let events = await recorder.events
        XCTAssertEqual(Set(events.map { "\($0)" }).count, events.count, "no event is published twice")
        XCTAssertEqual(Array(events.prefix(2)), [.step("server features"), .step("carbons")])
        XCTAssertEqual(events.last, .catchingUp(nil))
        let ready = try XCTUnwrap(events.firstIndex(of: .ready))
        let finished = try XCTUnwrap(events.firstIndex(of: .catchingUp(nil)))
        let carbons = try XCTUnwrap(events.firstIndex(of: .step("carbons")))
        XCTAssertLessThan(ready, finished)
        XCTAssertLessThan(carbons, try XCTUnwrap(events.firstIndex(of: Self.start)))
        XCTAssertLessThan(carbons, try XCTUnwrap(events.firstIndex(of: Self.keys)))
        XCTAssertEqual(Set(events.map { "\($0)" }), Set([ConnectionSetup.Event.step("server features"), .step("carbons"), Self.keys, Self.start, .ready, .catchingUp(nil)].map { "\($0)" }))
        let finalMarks = await recorder.marks
        XCTAssertEqual(finalMarks.last, "retry")
    }

    func testCatchUpStartsAfterCarbonsAndConcurrentlyWithInitialize() async {
        let recorder = Recorder(), walkEntered = Gate()
        var operations = operations(recorder)
        operations.initializeEncryption = {
            // Deadlocks unless the walk runs while initialize is suspended.
            await walkEntered.wait()
            await recorder.mark("initialize")
        }
        operations.catchUp = { _ in
            await recorder.mark("walk-start")
            await walkEntered.open()
        }
        await run(operations, recorder: recorder)
        let marks = await recorder.marks
        let carbons = marks.firstIndex(of: "carbons"), walk = marks.firstIndex(of: "walk-start")
        XCTAssertNotNil(carbons)
        XCTAssertNotNil(walk)
        if let carbons, let walk { XCTAssertLessThan(carbons, walk) }
        XCTAssertLessThan(marks.firstIndex(of: "walk-start") ?? .max, marks.firstIndex(of: "initialize") ?? -1)
        let ready = await recorder.contains(.ready)
        XCTAssertTrue(ready)
    }

    func testInitializeFailureFailsClosedAndJoinsTheWalk() async {
        let recorder = Recorder()
        var operations = operations(recorder)
        operations.initializeEncryption = { throw OMEMOError.identityChanged }
        operations.catchUp = { _ in
            await recorder.mark("walk-start")
            while !Task.isCancelled { await Task.yield() }
            await recorder.mark("walk-cancelled")
            throw CancellationError()
        }
        await run(operations, recorder: recorder)
        await recorder.mark("returned")
        let events = await recorder.events
        XCTAssertTrue(events.contains(.failed(step: "publishing this phone’s keys", detail: OMEMOError.identityChanged.errorDescription!)))
        XCTAssertFalse(events.contains(.ready))
        XCTAssertEqual(events.filter { if case .failed = $0 { true } else { false } }.count, 1)
        XCTAssertFalse(events.contains(.catchingUp(nil)))
        let marks = await recorder.marks
        XCTAssertLessThan(marks.firstIndex(of: "walk-cancelled") ?? .max, marks.firstIndex(of: "returned") ?? -1)
        XCTAssertFalse(marks.contains("retry"))
        XCTAssertFalse(marks.contains("rejoin"))
    }

    func testCancellationJoinsEveryChildBeforeReturning() async {
        let recorder = Recorder()
        var operations = operations(recorder)
        operations.rejoinGroups = {
            await recorder.mark("rejoin-start")
            while !Task.isCancelled { await Task.yield() }
            await recorder.mark("rejoin-cancelled")
            throw CancellationError()
        }
        operations.catchUp = { _ in
            await recorder.mark("walk-start")
            while !Task.isCancelled { await Task.yield() }
            await recorder.mark("walk-cancelled")
            // The walk surfaces the torn-down connection rather than a cancellation error.
            throw XMPPClientError.connectionClosed
        }
        let task = Task { await run(operations, recorder: recorder) }
        while await !recorder.hasMarks("rejoin-start", "walk-start") { await Task.yield() }
        task.cancel()
        await task.value
        await recorder.mark("joined")
        let marks = await recorder.marks
        let joined = marks.firstIndex(of: "joined") ?? -1
        XCTAssertLessThan(marks.firstIndex(of: "rejoin-cancelled") ?? .max, joined)
        XCTAssertLessThan(marks.firstIndex(of: "walk-cancelled") ?? .max, joined)
        let events = await recorder.events
        XCTAssertFalse(events.contains { if case .failed = $0 { true } else { false } })
        XCTAssertFalse(events.contains(.catchingUp(nil)))
        XCTAssertFalse(marks.contains("retry"))
    }

    func testNoArchiveFeatureMeansNoCatchUpEventsButStillReady() async {
        let recorder = Recorder()
        await run(operations(recorder, features: [ConnectionSetup.carbonsFeature]), recorder: recorder)
        let events = await recorder.events
        XCTAssertTrue(events.contains(.ready))
        XCTAssertFalse(events.contains { if case .catchingUp = $0 { true } else { false } })
        let marks = await recorder.marks
        XCTAssertTrue(marks.contains("retry"))
        XCTAssertFalse(marks.contains("walk-start"))
    }

    /// Prosody advertises carbons only on the server domain and MAM only on the account: setup must see both.
    func testFeaturesSplitAcrossDomainAndAccountEnableCarbonsAndTheWalk() async {
        let recorder = Recorder()
        var operations = operations(recorder)
        operations.features = {
            await recorder.mark("features")
            return try await ConnectionSetup.discoverFeatures(server: { [ConnectionSetup.carbonsFeature, "urn:xmpp:ping"] },
                                                              account: { [ConnectionSetup.archiveFeature] })
        }
        await run(operations, recorder: recorder)
        let marks = await recorder.marks
        XCTAssertTrue(marks.contains("carbons"))
        XCTAssertTrue(marks.contains("walk-start"))
        let events = await recorder.events
        XCTAssertTrue(events.contains(.step("carbons")))
        XCTAssertEqual(events.last, .catchingUp(nil))
    }

    func testAccountFeatureQueryFailingFailsTheFeaturesStepButServerQueryFailingOnlyDropsCarbons() async throws {
        let failing = Recorder()
        var failingOperations = operations(failing)
        failingOperations.features = {
            try await ConnectionSetup.discoverFeatures(server: { [ConnectionSetup.carbonsFeature] },
                                                       account: { throw XMPPIQError.stanza(condition: "service-unavailable") })
        }
        await run(failingOperations, recorder: failing)
        let failingEvents = await failing.events
        XCTAssertEqual(failingEvents.last, .failed(step: "server features", detail: "service-unavailable"))
        XCTAssertFalse(failingEvents.contains(.ready))
        let failingMarks = await failing.marks
        XCTAssertFalse(failingMarks.contains("carbons"))

        let tolerant = Recorder()
        var tolerantOperations = operations(tolerant)
        tolerantOperations.features = {
            try await ConnectionSetup.discoverFeatures(server: { throw XMPPIQError.stanza(condition: "service-unavailable") },
                                                       account: { [ConnectionSetup.archiveFeature] })
        }
        await run(tolerantOperations, recorder: tolerant)
        let tolerantEvents = await tolerant.events
        XCTAssertTrue(tolerantEvents.contains(.ready))
        XCTAssertEqual(tolerantEvents.last, .catchingUp(nil))
        let marks = await tolerant.marks
        XCTAssertFalse(marks.contains("carbons"))
        XCTAssertTrue(marks.contains("walk-start"))
    }

    func testInlineIdentityPathSkipsInitialize() async {
        let recorder = Recorder()
        await run(operations(recorder), recorder: recorder, identityExists: false)
        let marks = await recorder.marks
        XCTAssertFalse(marks.contains("initialize"))
        let events = await recorder.events
        XCTAssertTrue(events.contains(.ready))
        XCTAssertFalse(events.contains(Self.keys))
    }

    func testWalkFailureAfterReadyReportsArchiveStep() async throws {
        let recorder = Recorder(), ready = Gate()
        var operations = operations(recorder)
        operations.rejoinGroups = { await ready.open() }
        operations.catchUp = { _ in
            await ready.wait()
            throw XMPPIQError.malformedResponse
        }
        await run(operations, recorder: recorder)
        let events = await recorder.events
        let readyIndex = try XCTUnwrap(events.firstIndex(of: .ready))
        let failed = try XCTUnwrap(events.firstIndex(of: .failed(step: "archive catch-up", detail: "malformedResponse")))
        XCTAssertLessThan(readyIndex, failed)
        XCTAssertFalse(events.contains(.catchingUp(nil)))
        let marks = await recorder.marks
        XCTAssertFalse(marks.contains("retry"))
    }

    func testFeatureFailureReportsTheLastPublishedStepAndJoinsUploadDiscovery() async {
        let recorder = Recorder()
        var operations = operations(recorder)
        operations.enableCarbons = { throw XMPPIQError.stanza(condition: "service-unavailable") }
        operations.discoverUploads = {
            try? await Task.sleep(for: .milliseconds(50))
            await recorder.mark("uploads")
        }
        await run(operations, recorder: recorder)
        await recorder.mark("returned")
        let events = await recorder.events
        XCTAssertEqual(events.last, .failed(step: "carbons", detail: "service-unavailable"))
        XCTAssertFalse(events.contains(.ready))
        let marks = await recorder.marks
        XCTAssertLessThan(marks.firstIndex(of: "uploads") ?? .max, marks.firstIndex(of: "returned") ?? -1)
    }

    /// A flag set off the main actor and read by a test that is holding the main actor.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        var value: Bool { lock.withLock { raised } }
        func raise() { lock.withLock { raised = true } }
    }

    /// What reached the owner, and whether the owner had already cancelled the setup at that point.
    @MainActor private final class Owner {
        var cancelled = false
        private(set) var events: [ConnectionSetup.Event] = []
        private(set) var deliveredAfterCancel: [ConnectionSetup.Event] = []
        func apply(_ event: ConnectionSetup.Event) {
            events.append(event)
            if cancelled { deliveredAfterCancel.append(event) }
        }
    }

    /// `.disconnected` cancels the setup on the main actor without changing the generation. An event the setup
    /// produced just before (here `.ready`, right after `initialize` returned) and that is still queued for the
    /// main actor must then be dropped, or it would overwrite the offline state and stop the reconnect.
    func testAnEventQueuedWhenTheOwnerCancelsIsNotDelivered() async {
        let recorder = Recorder(), owner = Owner()
        let mainHeld = Flag(), initialized = Flag()
        var operations = operations(recorder)
        operations.initializeEncryption = {
            while !mainHeld.value { try await Task.sleep(for: .milliseconds(1)) }
            initialized.raise()
        }
        operations.catchUp = { _ in try await Task.sleep(for: .seconds(60)) }
        let task = Task { await ConnectionSetup(identityExists: true).run(operations: operations) { owner.apply($0) } }
        while !owner.events.contains(Self.keys) { await Task.yield() }
        // Hold the main actor until `initialize` returned and the identity child had time to queue `.ready`
        // behind this job, then cancel from the main actor as the `.disconnected` handler does.
        mainHeld.raise()
        while !initialized.value {}
        let held = ContinuousClock.now + .milliseconds(50)
        while ContinuousClock.now < held {}
        task.cancel()
        owner.cancelled = true
        await task.value

        XCTAssertEqual(owner.deliveredAfterCancel, [])
        XCTAssertFalse(owner.events.contains(.ready))
        XCTAssertFalse(owner.events.contains(.catchingUp(nil)))
        XCTAssertFalse(owner.events.contains { if case .failed = $0 { true } else { false } })
    }
}
