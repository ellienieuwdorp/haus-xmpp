import Foundation

/// What the app process should do and what the user can see, as four separate signals. On iOS all four follow the
/// scene: on at `.active`, off at `.background`.
/// A desktop needs them apart, because the app stays connected while nobody looks at it.
public struct LifecycleSignals: Sendable, Equatable {
    /// This process should own the transport: hold the lease, connect, synchronize, send. Off quiesces the transport
    /// and releases the lease.
    public var transportWanted: Bool
    /// Some window of the app is visible: XEP-0352 CSI `<active/>`; `<inactive/>` once none is.
    public var windowVisible: Bool
    /// The user can read the open chat: displayed markers, XEP-0490 read state and banner suppression for that chat
    /// only. See `reading(_:openChatID:)`.
    public var readsOpenChat: Bool
    /// The user is at the device: plain available presence; away with XEP-0319 idle otherwise. Never derived from
    /// window focus, which changes all day on a desktop, and every presence change wakes the account's other phones.
    public var present: Bool

    public init(transportWanted: Bool, windowVisible: Bool, readsOpenChat: Bool, present: Bool) {
        self.transportWanted = transportWanted; self.windowVisible = windowVisible
        self.readsOpenChat = readsOpenChat; self.present = present
    }

    /// The app in front (iOS `.active`, and the state a process starts in).
    public static let inFront = LifecycleSignals(transportWanted: true, windowVisible: true, readsOpenChat: true, present: true)
    /// The app away (iOS `.background`, or launched into it).
    public static let away = LifecycleSignals(transportWanted: false, windowVisible: false, readsOpenChat: false, present: false)

    /// The chat the user is reading: the open one, while it can be read; nil otherwise.
    public func readingChat(openChatID: String?) -> String? { readsOpenChat ? openChatID : nil }

    /// Whether `chatID` is the chat the user is reading.
    public func reading(_ chatID: String, openChatID: String?) -> Bool { readingChat(openChatID: openChatID) == chatID }

    /// What a new stream binds with: away presence when the user is not present, CSI `<inactive/>` when no window is
    /// visible (a Mac launched at login with no window). A stream binding while the transport is going away is closed
    /// by the quiesce, which announces away itself, so it binds with the defaults, as iOS always has.
    public var streamBinding: StreamBinding {
        guard transportWanted else { return StreamBinding(presence: .available, clientActive: true) }
        return StreamBinding(presence: present ? .available : .away, clientActive: windowVisible)
    }
}

/// The presence and XEP-0352 state a new stream announces when it binds (`LifecycleSignals.streamBinding`).
public struct StreamBinding: Sendable, Equatable {
    public var presence: LifecycleTransition.Presence
    public var clientActive: Bool
    public init(presence: LifecycleTransition.Presence, clientActive: Bool) { self.presence = presence; self.clientActive = clientActive }
}

/// One step a lifecycle driver asks the app to take, in order.
public enum LifecycleUpdate: Sendable, Equatable {
    /// The signals the process starts with, before any transport work: set, and nothing runs.
    case start(LifecycleSignals)
    /// The user stopped interacting (iOS: the scene left `.active`, at nil, which means now; the Mac: the time of the
    /// last input when the user went idle, locked the screen, switched user, or the Mac went to sleep or the app quit).
    /// That moment becomes the last-seen time, sent as XEP-0319 idle by every away presence until the next one.
    case interactionEnded(at: Date?)
    /// New signals. The app runs `LifecycleTransition.between(current, new, activated:)`, also when they equal the
    /// current ones. `activated`: the user brought the app forward (iOS: the scene reached `.active`), which repeats
    /// the return-to-front work; a focus or occlusion change alone does not.
    case change(LifecycleSignals, activated: Bool)
}

/// What the app does when the signals change. Pure policy; `AppModel.applyLifecycle` carries it out.
public struct LifecycleTransition: Sendable, Equatable {
    public enum Presence: Sendable, Equatable { case available, away }

    /// Return-to-front work: open storage left for later, re-read notification permission, reconnect now instead of
    /// after the back-off, then refresh.
    public var resumesTransport = false
    /// Blocks new transport and crypto work at once, then (after `presence`) disconnects with a final `<a/>`, joins
    /// every reader, consumer, sender and UI crypto mutation, and only then releases the lease.
    public var quiescesTransport = false
    /// XEP-0352 state for the live stream; nil sends none. With a `presence` it is written together with it
    /// (`<active/>` before, `<inactive/>` after); alone, it is written on its own.
    public var clientActive: Bool?
    /// Presence for the live stream, sent before anything else in the transition; nil sends none. Never without a
    /// `clientActive`.
    public var presence: Presence?

    public init(resumesTransport: Bool = false, quiescesTransport: Bool = false, clientActive: Bool? = nil, presence: Presence? = nil) {
        self.resumesTransport = resumesTransport; self.quiescesTransport = quiescesTransport
        self.clientActive = clientActive; self.presence = presence
    }

    public static func between(_ old: LifecycleSignals, _ new: LifecycleSignals, activated: Bool = false) -> LifecycleTransition {
        // The session hibernates (up to days with push), so it must read as away and inactive before it goes,
        // whatever `present` and `windowVisible` say. The disconnect follows.
        guard new.transportWanted else { return LifecycleTransition(quiescesTransport: true, clientActive: false, presence: .away) }
        var transition = LifecycleTransition()
        // The transport (re)starting, or the user bringing the app forward, which on iOS is every activation.
        transition.resumesTransport = !old.transportWanted || activated
        if old.transportWanted, old.present != new.present {
            // A stream that stays up announces the user coming and going, and restates the window's CSI state with
            // it. A new stream announces both when it binds (`LifecycleSignals.streamBinding`).
            transition.presence = new.present ? .available : .away
            transition.clientActive = new.windowVisible
        } else if new.windowVisible {
            if activated || !old.transportWanted || !old.windowVisible { transition.clientActive = true }
        } else if old.transportWanted, old.windowVisible {
            transition.clientActive = false
        }
        return transition
    }
}

/// Turns one platform's lifecycle events into `LifecycleUpdate`s. The app applies them in order and nothing else
/// changes the signals. Drivers are pure, so their sequences are unit-tested; the platform glue only forwards events.
public protocol LifecycleDriver {
    associatedtype Event
    /// What the app last applied from this driver.
    var signals: LifecycleSignals { get }
    mutating func updates(for event: Event) -> [LifecycleUpdate]
}

/// iOS: the app-level scene phase drives all four signals together, exactly as the single `foreground` flag did.
/// On at `.active` (every time, also from `.inactive`), off only at `.background`, and the last-seen time recorded
/// whenever the scene leaves `.active`. A launch into the background (a notification action) starts away and turns
/// on at its first activation, whether or not a scene phase change was seen.
public struct SceneLifecycleDriver: LifecycleDriver {
    /// SwiftUI's `ScenePhase`, without SwiftUI. An unknown future phase maps to `.inactive`: neither on nor off.
    public enum Phase: Sendable, Equatable { case active, inactive, background }

    public enum Event: Sendable, Equatable {
        /// `prepare()` read `UIApplication.applicationState`.
        case launched(inBackground: Bool)
        case phaseChanged(from: Phase, to: Phase)
        /// `UIApplication.didBecomeActiveNotification`, observed only after a launch into the background.
        case becameActive
    }

    public private(set) var signals = LifecycleSignals.inFront

    public init() {}

    public mutating func updates(for event: Event) -> [LifecycleUpdate] {
        var updates: [LifecycleUpdate] = []
        switch event {
        case .launched(let inBackground):
            guard inBackground else { break }
            signals = .away
            updates.append(.start(.away))
        case .phaseChanged(let previous, let phase):
            if previous == .active, phase != .active { updates.append(.interactionEnded(at: nil)) }
            if phase == .active { signals = .inFront; updates.append(.change(.inFront, activated: true)) }
            else if phase == .background { signals = .away; updates.append(.change(.away, activated: false)) }
        case .becameActive:
            guard !signals.transportWanted else { break }
            signals = .inFront
            updates.append(.change(.inFront, activated: true))
        }
        return updates
    }
}

/// Where each attention-dependent feature looks. On iOS every one keeps following the transport (the scene), as the
/// single `foreground` flag did; a desktop app holds the transport with no window, so there each one follows the
/// signal that matches it.
public struct AttentionRules: Sendable, Equatable {
    /// iOS: unchanged from before the signals were split.
    public static let phone = AttentionRules(desktop: false)
    /// The Mac.
    public static let desktop = AttentionRules(desktop: true)

    public let desktop: Bool

    /// The chat whose banners `willPresent` hides. iOS asks only while the app is in front, so the open chat; on a
    /// Mac the frontmost app is not necessarily read, so the chat being read.
    public func bannerHiddenChat(_ signals: LifecycleSignals, openChatID: String?) -> String? {
        desktop ? signals.readingChat(openChatID: openChatID) : openChatID
    }

    /// Whether `chatID`'s delivered notifications and waiting reaction alerts go now because it is on screen. iOS:
    /// whenever it is the open chat (the transport, which these need, means the app is in front). Mac: only while it
    /// is read.
    public func clearsNotifications(of chatID: String, _ signals: LifecycleSignals, openChatID: String?) -> Bool {
        desktop ? signals.reading(chatID, openChatID: openChatID) : openChatID == chatID
    }

    /// Whether the "message wasn't delivered" alert shows. iOS: while the transport is wanted (in front). Mac: while a
    /// window is visible to show it in.
    public func showsDeliveryAlert(_ signals: LifecycleSignals) -> Bool {
        desktop ? signals.windowVisible : signals.transportWanted
    }

    /// Whether typing chat states may go to the open chat. iOS: while the transport is wanted. Mac: while the user is
    /// reading it.
    public func sendsChatStates(_ signals: LifecycleSignals) -> Bool {
        desktop ? signals.transportWanted && signals.readsOpenChat : signals.transportWanted
    }

    /// Whether a typing state the peer saw ends now: on a Mac when the user stops reading, so a draft left
    /// mid-sentence ends the chat state instead of going from composing to paused. iOS leaves it, as before.
    public func endsChatState(from old: LifecycleSignals, to new: LifecycleSignals) -> Bool {
        desktop && sendsChatStates(old) && !sendsChatStates(new)
    }

    /// Whether the user just started reading the open chat: on a Mac the newest visible message is then marked read
    /// and the chat's notifications go (critique G3). On iOS cells mark messages as they appear and nothing else runs.
    public func startsReading(from old: LifecycleSignals, to new: LifecycleSignals) -> Bool {
        desktop && !old.readsOpenChat && new.readsOpenChat
    }
}
