import Testing
@testable import MessagingCore

private typealias Phase = SceneLifecycleDriver.Phase

// Reference model the scene driver must reproduce: one `foreground` flag set by the scene phase, and the effects of
// `setForeground(true)` and `setForeground(false)`.
private enum Legacy: Equatable {
    case leftForeground
    case setForeground(Bool)

    static func calls(_ previous: Phase, _ phase: Phase) -> [Legacy] {
        var calls: [Legacy] = []
        if previous == .active, phase != .active { calls.append(.leftForeground) }
        if phase == .active { calls.append(.setForeground(true)) }
        else if phase == .background { calls.append(.setForeground(false)) }
        return calls
    }

    // Off sends away presence with CSI inactive (same bytes: ClientStateWireTests), then quiesces.
    static func effects(_ active: Bool) -> LifecycleTransition {
        active ? LifecycleTransition(resumesTransport: true, clientActive: true)
            : LifecycleTransition(quiescesTransport: true, clientActive: false, presence: .away)
    }
}

// Applies a driver's updates as the app does and reports each step in the reference model's terms.
private struct Harness {
    var driver = SceneLifecycleDriver()
    var applied = LifecycleSignals.inFront
    var foreground = true

    mutating func step(_ event: SceneLifecycleDriver.Event) -> [Legacy] {
        if case let .phaseChanged(previous, phase) = event { applyLegacy(Legacy.calls(previous, phase)) }
        var calls: [Legacy] = []
        for update in driver.updates(for: event) {
            switch update {
            case .start(let signals): applied = signals
            case .interactionEnded(let at):
                #expect(at == nil, "iOS records the moment the scene leaves .active, as before")
                calls.append(.leftForeground)
            case .change(let signals, let activated):
                let transition = LifecycleTransition.between(applied, signals, activated: activated)
                applied = signals
                let active = !transition.quiescesTransport
                #expect(transition == Legacy.effects(active), "the transition runs exactly what setForeground(\(active)) ran")
                calls.append(.setForeground(active))
            }
        }
        #expect(driver.signals == applied)
        return calls
    }

    mutating func applyLegacy(_ calls: [Legacy]) {
        for case let .setForeground(active) in calls { foreground = active }
    }

    // Every signal equals the reference flag, so each guard that reads a signal decides as the flag would.
    func signalsMatchForeground() -> Bool {
        [applied.transportWanted, applied.windowVisible, applied.readsOpenChat, applied.present].allSatisfy { $0 == foreground }
    }
}

struct SceneLifecycleDriverTests {
    @Test func activeInactiveBackgroundActiveRepeatsTodaysSequence() {
        var harness = Harness()
        #expect(harness.step(.phaseChanged(from: .active, to: .inactive)) == [.leftForeground])
        #expect(harness.signalsMatchForeground(), "inactive keeps the transport and the reading chat")
        #expect(harness.step(.phaseChanged(from: .inactive, to: .background)) == [.setForeground(false)])
        #expect(harness.signalsMatchForeground())
        #expect(harness.step(.phaseChanged(from: .background, to: .inactive)) == [])
        #expect(harness.signalsMatchForeground(), "coming back through inactive is still away")
        #expect(harness.step(.phaseChanged(from: .inactive, to: .active)) == [.setForeground(true)])
        #expect(harness.signalsMatchForeground())
    }

    @Test func activeInactiveActiveRepeatsTheReturnWork() {
        var harness = Harness()
        #expect(harness.step(.phaseChanged(from: .active, to: .inactive)) == [.leftForeground])
        // Control Centre or the app switcher: the transport stays, and activation runs the return work again.
        #expect(harness.step(.phaseChanged(from: .inactive, to: .active)) == [.setForeground(true)])
        #expect(harness.signalsMatchForeground())
    }

    @Test func everyPhasePairMatchesTheOldClosure() {
        let phases: [Phase] = [.active, .inactive, .background]
        for start in phases {
            for previous in phases {
                for phase in phases {
                    var harness = Harness()
                    // Reach `previous` the way the scene would, then compare the step under test.
                    _ = harness.step(.phaseChanged(from: start, to: previous))
                    #expect(harness.step(.phaseChanged(from: previous, to: phase)) == Legacy.calls(previous, phase),
                            "\(start) → \(previous) → \(phase)")
                    #expect(harness.signalsMatchForeground(), "\(start) → \(previous) → \(phase)")
                }
            }
        }
    }

    @Test func aBackgroundLaunchStartsAwayAndTurnsOnAtItsFirstActivation() {
        var harness = Harness()
        // No quiesce and no presence for a background launch.
        #expect(harness.driver.updates(for: .launched(inBackground: true)) == [.start(.away)])
        #expect(harness.driver.signals == .away)
        harness.applied = .away
        harness.foreground = false
        #expect(harness.step(.becameActive) == [.setForeground(true)])
        // The scene phase change that follows runs the return work again.
        #expect(harness.step(.phaseChanged(from: .inactive, to: .active)) == [.setForeground(true)])
        #expect(harness.step(.becameActive) == [], "the observer only ran when foreground was false")
    }

    @Test func aBackgroundLaunchSeenActiveByTheSceneFirstDoesNotRepeat() {
        var driver = SceneLifecycleDriver()
        _ = driver.updates(for: .launched(inBackground: true))
        #expect(driver.updates(for: .phaseChanged(from: .background, to: .active)) == [.change(.inFront, activated: true)])
        #expect(driver.updates(for: .becameActive) == [])
    }

    @Test func aLaunchInFrontChangesNothing() {
        var driver = SceneLifecycleDriver()
        #expect(driver.updates(for: .launched(inBackground: false)) == [])
        #expect(driver.signals == .inFront)
    }
}

// Each signal's own effect, with the others held still.
struct LifecycleTransitionTests {
    private func signals(transport: Bool = true, window: Bool = true, reading: Bool = true, present: Bool = true) -> LifecycleSignals {
        LifecycleSignals(transportWanted: transport, windowVisible: window, readsOpenChat: reading, present: present)
    }

    @Test func transportOffQuiescesAfterAwayPresenceWhateverTheUserDoes() {
        let off = LifecycleTransition(quiescesTransport: true, clientActive: false, presence: .away)
        #expect(LifecycleTransition.between(.inFront, .away) == off)
        // Quit or sleep with the window open and the user at the machine: the hibernating session still reads away.
        #expect(LifecycleTransition.between(.inFront, signals(transport: false)) == off)
        #expect(LifecycleTransition.between(.away, .away) == off)
    }

    @Test func transportOnResumesAndLetsTheNewStreamAnnounceItself() {
        #expect(LifecycleTransition.between(.away, .inFront) == LifecycleTransition(resumesTransport: true, clientActive: true))
        // Launched at login with no window: connect, but no CSI to send yet and no presence change on a stream
        // that does not exist.
        #expect(LifecycleTransition.between(.away, signals(window: false, reading: false, present: false))
                == LifecycleTransition(resumesTransport: true))
    }

    @Test func activationRepeatsTheReturnWorkAndNothingElseDoes() {
        let back = LifecycleTransition(resumesTransport: true, clientActive: true)
        #expect(LifecycleTransition.between(.inFront, .inFront, activated: true) == back)
        #expect(LifecycleTransition.between(.inFront, .inFront) == LifecycleTransition())
    }

    @Test func windowVisibilityDrivesCSIOnly() {
        let hidden = signals(window: false, reading: false)
        #expect(LifecycleTransition.between(.inFront, hidden) == LifecycleTransition(clientActive: false))
        // Uncovered (occlusion) without the app becoming active: CSI only.
        #expect(LifecycleTransition.between(hidden, signals(reading: false)) == LifecycleTransition(clientActive: true))
        #expect(LifecycleTransition.between(hidden, .inFront, activated: true) == LifecycleTransition(resumesTransport: true, clientActive: true))
        #expect(LifecycleTransition.between(hidden, hidden) == LifecycleTransition(), "nothing to repeat while hidden")
    }

    @Test func readingChangesNoTransportOrPresence() {
        let elsewhere = signals(reading: false)
        // Focus moving to another app or window and back: no CSI, no presence, no reconnect or refresh.
        #expect(LifecycleTransition.between(.inFront, elsewhere) == LifecycleTransition())
        #expect(LifecycleTransition.between(elsewhere, .inFront) == LifecycleTransition())
    }

    @Test func presenceFollowsTheUserWhileTheStreamStaysAndCarriesTheWindowsCSI() {
        let idle = signals(window: false, reading: false, present: false)
        let hidden = signals(window: false, reading: false)
        #expect(LifecycleTransition.between(hidden, idle) == LifecycleTransition(clientActive: false, presence: .away))
        #expect(LifecycleTransition.between(idle, hidden) == LifecycleTransition(clientActive: false, presence: .available))
        // Idle with the window visible: away presence, and CSI stays active.
        #expect(LifecycleTransition.between(.inFront, signals(present: false)) == LifecycleTransition(clientActive: true, presence: .away))
        #expect(LifecycleTransition.between(signals(present: false), .inFront) == LifecycleTransition(clientActive: true, presence: .available))
        // The window hides as the user goes idle (the screen locks): one presence, with CSI inactive.
        #expect(LifecycleTransition.between(.inFront, idle) == LifecycleTransition(clientActive: false, presence: .away))
    }

    @Test func aNewStreamBindsWithTheCurrentSignals() {
        #expect(LifecycleSignals.inFront.streamBinding == StreamBinding(presence: .available, clientActive: true))
        // A Mac launched with no window while the user is at it, and one nobody is at.
        #expect(signals(window: false, reading: false).streamBinding == StreamBinding(presence: .available, clientActive: false))
        #expect(signals(window: false, reading: false, present: false).streamBinding == StreamBinding(presence: .away, clientActive: false))
        #expect(signals(reading: false, present: false).streamBinding == StreamBinding(presence: .away, clientActive: true))
        // The quiesce closes the stream and announces away itself.
        #expect(LifecycleSignals.away.streamBinding == StreamBinding(presence: .available, clientActive: true))
    }

    @Test func onlyTheOpenChatIsReadAndOnlyWhileReadable() {
        #expect(LifecycleSignals.inFront.readingChat(openChatID: "bob@example.org") == "bob@example.org")
        #expect(LifecycleSignals.inFront.readingChat(openChatID: nil) == nil)
        #expect(LifecycleSignals.inFront.reading("bob@example.org", openChatID: "bob@example.org"))
        #expect(!LifecycleSignals.inFront.reading("carol@example.org", openChatID: "bob@example.org"))
        let unread = signals(reading: false)
        #expect(unread.readingChat(openChatID: "bob@example.org") == nil)
        #expect(!unread.reading("bob@example.org", openChatID: "bob@example.org"))
        #expect(!LifecycleSignals.away.reading("bob@example.org", openChatID: "bob@example.org"))
    }
}
