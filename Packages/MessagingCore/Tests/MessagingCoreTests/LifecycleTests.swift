import Testing
@testable import MessagingCore

private typealias Phase = SceneLifecycleDriver.Phase

/// What `HausXMPPApp` and `AppModel` did before the signals were split: the scene-phase closure verbatim, then what
/// `setForeground(true)` and `setForeground(false)` ran.
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

    /// On: return-to-front work and CSI active on the client. Off: away presence while connected, then the quiesce.
    static func effects(_ active: Bool) -> LifecycleTransition {
        active ? LifecycleTransition(resumesTransport: true, clientActive: true)
            : LifecycleTransition(quiescesTransport: true, presence: .away)
    }
}

/// Runs a driver the way `AppModel.applyLifecycle` does and reports each step in the legacy vocabulary.
private struct Harness {
    var driver = SceneLifecycleDriver()
    var applied = LifecycleSignals.inFront
    /// The legacy `foreground` flag, starting true as it did.
    var foreground = true

    mutating func step(_ event: SceneLifecycleDriver.Event) -> [Legacy] {
        if case let .phaseChanged(previous, phase) = event { applyLegacy(Legacy.calls(previous, phase)) }
        var calls: [Legacy] = []
        for update in driver.updates(for: event) {
            switch update {
            case .start(let signals): applied = signals
            case .interactionEnded: calls.append(.leftForeground)
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

    /// Every signal equals the flag the old code read, so each re-routed guard decides as before.
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
        // prepare() set foreground = false without a transition: no quiesce, no presence.
        #expect(harness.driver.updates(for: .launched(inBackground: true)) == [.start(.away)])
        #expect(harness.driver.signals == .away)
        harness.applied = .away
        harness.foreground = false
        #expect(harness.step(.becameActive) == [.setForeground(true)])
        // The scene phase change that follows runs the return work again, as it did.
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

/// Each signal's own effect, with the others held still. iOS never separates them; a desktop driver will.
struct LifecycleTransitionTests {
    private func signals(transport: Bool = true, window: Bool = true, reading: Bool = true, present: Bool = true) -> LifecycleSignals {
        LifecycleSignals(transportWanted: transport, windowVisible: window, readsOpenChat: reading, present: present)
    }

    @Test func transportOffQuiescesAfterAwayPresenceWhateverTheUserDoes() {
        let off = LifecycleTransition(quiescesTransport: true, presence: .away)
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

    @Test func presenceFollowsTheUserWhileTheStreamStays() {
        let idle = signals(window: false, reading: false, present: false)
        let hidden = signals(window: false, reading: false)
        #expect(LifecycleTransition.between(hidden, idle) == LifecycleTransition(presence: .away))
        // Available presence carries CSI active on the wire, so a hidden window restates inactive after it.
        #expect(LifecycleTransition.between(idle, hidden) == LifecycleTransition(clientActive: false, presence: .available))
        // Idle with the window visible: away presence carries CSI inactive, so CSI active is restated.
        #expect(LifecycleTransition.between(.inFront, signals(present: false)) == LifecycleTransition(clientActive: true, presence: .away))
        #expect(LifecycleTransition.between(signals(present: false), .inFront) == LifecycleTransition(presence: .available))
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
