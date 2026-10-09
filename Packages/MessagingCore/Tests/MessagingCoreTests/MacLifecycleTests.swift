import Foundation
import Testing
@testable import MessagingCore

private typealias Windows = MacLifecycleDriver.Windows

private func signals(transport: Bool = true, window: Bool = true, reading: Bool = true, present: Bool = true) -> LifecycleSignals {
    LifecycleSignals(transportWanted: transport, windowVisible: window, readsOpenChat: reading, present: present)
}

/// The attention-dependent guards. On iOS each must decide exactly as the `foreground` flag did; on the Mac each
/// follows its own signal.
struct AttentionRulesTests {
    private let chat = "bob@example.org"

    @Test func thePhoneDecidesEveryGuardAsTheForegroundFlagDid() {
        let rules = AttentionRules.phone
        for foreground in [true, false] {
            let state = foreground ? LifecycleSignals.inFront : .away
            for open in [chat, nil] as [String?] {
                #expect(rules.bannerHiddenChat(state, openChatID: open) == open, "willPresent kept the open chat")
                #expect(rules.clearsNotifications(of: chat, state, openChatID: open) == (open == chat))
            }
            #expect(rules.showsDeliveryAlert(state) == foreground)
            #expect(rules.sendsChatStates(state) == foreground)
            for other in [LifecycleSignals.inFront, .away] {
                #expect(!rules.endsChatState(from: other, to: state), "iOS never ends a chat state on a lifecycle change")
                #expect(!rules.startsReading(from: other, to: state), "iOS marks messages as cells appear, not on activation")
            }
        }
    }

    @Test func theMacHidesBannersAndClearsNotificationsOnlyForTheChatBeingRead() {
        let rules = AttentionRules.desktop
        #expect(rules.bannerHiddenChat(.inFront, openChatID: chat) == chat)
        // The window behind another app, or the user idle: the open chat gets banners and keeps its notifications.
        for unread in [signals(reading: false), signals(reading: false, present: false), signals(window: false, reading: false)] {
            #expect(rules.bannerHiddenChat(unread, openChatID: chat) == nil)
            #expect(!rules.clearsNotifications(of: chat, unread, openChatID: chat))
        }
        #expect(rules.clearsNotifications(of: chat, .inFront, openChatID: chat))
        #expect(!rules.clearsNotifications(of: "carol@example.org", .inFront, openChatID: chat))
    }

    @Test func theMacShowsTheDeliveryAlertOnlyWithAWindowAndTypesOnlyWhileReading() {
        let rules = AttentionRules.desktop
        #expect(rules.showsDeliveryAlert(signals(reading: false, present: false)))
        #expect(!rules.showsDeliveryAlert(signals(window: false, reading: false)), "no window to show it in")
        #expect(rules.sendsChatStates(.inFront))
        #expect(!rules.sendsChatStates(signals(reading: false)))
        // Stopping reading ends a chat state the peer saw; starting again does not.
        #expect(rules.endsChatState(from: .inFront, to: signals(reading: false)))
        #expect(rules.endsChatState(from: .inFront, to: .away))
        #expect(!rules.endsChatState(from: signals(reading: false), to: .inFront))
        #expect(rules.startsReading(from: signals(reading: false), to: .inFront))
        #expect(!rules.startsReading(from: .inFront, to: .inFront))
    }
}

/// Runs the Mac driver as the glue does: one event at a time with the input clock read alongside.
private struct MacHarness {
    var driver = MacLifecycleDriver()
    var now = Date(timeIntervalSince1970: 1_790_000_000)
    var applied = LifecycleSignals.inFront
    var transitions: [LifecycleTransition] = []

    /// The updates for `change`, applying each `.change` the way `AppModel` does.
    mutating func step(_ change: MacLifecycleDriver.Change, idle seconds: TimeInterval = 1) -> [LifecycleUpdate] {
        let updates = driver.updates(for: .init(change, now: now, secondsSinceInput: seconds))
        transitions = []
        for update in updates {
            switch update {
            case .start(let signals): applied = signals
            case .change(let signals, let activated):
                transitions.append(.between(applied, signals, activated: activated))
                applied = signals
            case .interactionEnded: break
            }
        }
        #expect(driver.signals == applied)
        return updates
    }

    /// Launched and brought to the front with the chat window key.
    static func reading() -> MacHarness {
        var harness = MacHarness()
        _ = harness.step(.launched(.none))
        _ = harness.step(.windows(.reading))
        return harness
    }
}

struct MacLifecycleDriverTests {
    @Test func aLaunchWithNoWindowConnectsUnseenAndBindsInactive() {
        var harness = MacHarness()
        let start = signals(window: false, reading: false)
        #expect(harness.step(.launched(.none)) == [.start(start)])
        #expect(start.streamBinding == StreamBinding(presence: .available, clientActive: false))
        // Nobody at the Mac (launched at login): the stream binds away as well.
        var unattended = MacHarness()
        #expect(unattended.step(.launched(.none), idle: 900) == [.start(signals(window: false, reading: false, present: false))])
    }

    @Test func theWindowComingToTheFrontIsAnActivation() {
        var harness = MacHarness()
        _ = harness.step(.launched(.none))
        #expect(harness.step(.windows(.reading)) == [.change(.inFront, activated: true)])
        #expect(harness.transitions == [LifecycleTransition(resumesTransport: true, clientActive: true)])
    }

    @Test func closingTheLastWindowKeepsTheTransportAndOnlyGoesInactive() {
        var harness = MacHarness.reading()
        #expect(harness.step(.windows(.none)) == [.change(signals(window: false, reading: false), activated: false)])
        #expect(harness.transitions == [LifecycleTransition(clientActive: false)])
    }

    @Test func anotherAppInFrontStopsReadingButKeepsCSIAndPresence() {
        var harness = MacHarness.reading()
        let behind = Windows(appActive: false, appVisible: true, chatWindowKey: false, chatWindowVisible: true)
        #expect(harness.step(.windows(behind)) == [.change(signals(reading: false), activated: false)])
        #expect(harness.transitions == [LifecycleTransition()], "focus changes all day: no CSI, presence or reconnect")
        // Switching back is an activation: reconnect now and refresh, as an iOS activation does.
        #expect(harness.step(.windows(.reading)) == [.change(.inFront, activated: true)])
        #expect(harness.transitions == [LifecycleTransition(resumesTransport: true, clientActive: true)])
    }

    @Test func aKeyWindowChangeInsideTheAppIsNotAnActivation() {
        var harness = MacHarness.reading()
        let settingsKey = Windows(appActive: true, appVisible: true, chatWindowKey: false, chatWindowVisible: true)
        #expect(harness.step(.windows(settingsKey)) == [.change(signals(reading: false), activated: false)])
        #expect(harness.step(.windows(.reading)) == [.change(.inFront, activated: false)])
        #expect(harness.transitions == [LifecycleTransition()])
    }

    @Test func minimisingOrHidingTheOnlyWindowGoesInactive() {
        var harness = MacHarness.reading()
        let minimised = Windows(appActive: true, appVisible: false, chatWindowKey: false, chatWindowVisible: false)
        #expect(harness.step(.windows(minimised)) == [.change(signals(window: false, reading: false), activated: false)])
        #expect(harness.transitions == [LifecycleTransition(clientActive: false)])
    }

    @Test func fiveMinutesWithoutInputGoesAwayWithTheTimeOfTheLastInput() {
        var harness = MacHarness.reading()
        #expect(harness.step(.idleChecked, idle: 299) == [], "under the threshold nothing changes")
        let away = harness.step(.idleChecked, idle: 300)
        #expect(away == [.interactionEnded(at: harness.now.addingTimeInterval(-300)), .change(signals(reading: false, present: false), activated: false)])
        #expect(harness.transitions == [LifecycleTransition(clientActive: true, presence: .away)], "the window stays visible: CSI stays active")
        #expect(harness.step(.idleChecked, idle: 600) == [], "still away: one presence change, not one per check")
        // Input again: back, reading again since the window is still the key one in front.
        #expect(harness.step(.idleChecked, idle: 2) == [.change(.inFront, activated: false)])
        #expect(harness.transitions == [LifecycleTransition(clientActive: true, presence: .available)])
    }

    @Test func idleWithNoWindowSendsAwayAndKeepsCSIInactive() {
        var harness = MacHarness()
        _ = harness.step(.launched(.none))
        _ = harness.step(.idleChecked, idle: 301)
        #expect(harness.transitions == [LifecycleTransition(clientActive: false, presence: .away)])
    }

    @Test func lockingTheScreenStopsReadingAndGoesAwayAndInactive() {
        var harness = MacHarness.reading()
        let locked = harness.step(.screenLocked(true), idle: 4)
        #expect(locked == [.interactionEnded(at: harness.now.addingTimeInterval(-4)), .change(signals(window: false, reading: false, present: false), activated: false)])
        #expect(harness.transitions == [LifecycleTransition(clientActive: false, presence: .away)])
        #expect(!harness.applied.reading("bob@example.org", openChatID: "bob@example.org"))
        #expect(harness.step(.screenLocked(false)) == [.change(.inFront, activated: false)])
        #expect(harness.transitions == [LifecycleTransition(clientActive: true, presence: .available)])
    }

    @Test func willSleepQuiescesAfterRecordingTheLastInputAndWakeResumes() {
        var harness = MacHarness.reading()
        let sleep = harness.step(.willSleep, idle: 20)
        #expect(sleep == [.interactionEnded(at: harness.now.addingTimeInterval(-20)), .change(.away, activated: false)])
        #expect(harness.transitions == [LifecycleTransition(quiescesTransport: true, clientActive: false, presence: .away)])
        // Asleep the app is not active any more; waking with the window still in front reconnects and refreshes.
        #expect(harness.step(.didWake) == [.change(.inFront, activated: false)])
        #expect(harness.transitions == [LifecycleTransition(resumesTransport: true, clientActive: true)])
    }

    @Test func sleepingWhileAwayRecordsNoNewLastSeen() {
        var harness = MacHarness.reading()
        _ = harness.step(.idleChecked, idle: 400)
        #expect(harness.step(.willSleep, idle: 410) == [.change(.away, activated: false)])
    }

    @Test func wakingWithNoWindowAndNobodyThereReconnectsAway() {
        var harness = MacHarness()
        _ = harness.step(.launched(.none))
        _ = harness.step(.willSleep)
        #expect(harness.step(.didWake, idle: 3_600) == [.change(signals(window: false, reading: false, present: false), activated: false)])
        #expect(harness.transitions == [LifecycleTransition(resumesTransport: true)])
        #expect(harness.applied.streamBinding == StreamBinding(presence: .away, clientActive: false))
    }

    @Test func quittingQuiescesAndNothingAfterItTurnsTheTransportBackOn() {
        var harness = MacHarness.reading()
        _ = harness.step(.willTerminate)
        #expect(harness.transitions == [LifecycleTransition(quiescesTransport: true, clientActive: false, presence: .away)])
        #expect(harness.step(.windows(.reading)) == [], "an activation while quitting changes nothing")
        #expect(harness.step(.didWake) == [])
        #expect(!harness.applied.transportWanted)
    }

    @Test func aFastUserSwitchAwayQuiescesAndBackResumes() {
        var harness = MacHarness.reading()
        _ = harness.step(.sessionActive(false))
        #expect(harness.transitions == [LifecycleTransition(quiescesTransport: true, clientActive: false, presence: .away)])
        _ = harness.step(.sessionActive(true))
        #expect(harness.transitions == [LifecycleTransition(resumesTransport: true, clientActive: true)])
    }

    @Test func comingBackFromIdleByActivatingTheAppIsBothReturnAndActivation() {
        var harness = MacHarness()
        _ = harness.step(.launched(.none))
        _ = harness.step(.idleChecked, idle: 900)
        #expect(harness.step(.windows(.reading), idle: 0) == [.change(.inFront, activated: true)])
        #expect(harness.transitions == [LifecycleTransition(resumesTransport: true, clientActive: true, presence: .available)])
    }

    @Test func theIdleTimerFiresAtTheThresholdWhilePresentAndPollsWhileAway() {
        var harness = MacHarness.reading()
        #expect(harness.driver.secondsUntilIdleCheck(secondsSinceInput: 100) == 200)
        #expect(harness.driver.secondsUntilIdleCheck(secondsSinceInput: 299.6) == 1)
        _ = harness.step(.idleChecked, idle: 300)
        #expect(harness.driver.secondsUntilIdleCheck(secondsSinceInput: 300) == MacLifecycleDriver.awayPollInterval)
    }
}
