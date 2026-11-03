import Foundation

/// Four separate attention signals. On iOS all four follow the scene (on at `.active`, off at `.background`); a
/// desktop app stays connected while nobody looks at it, so there they diverge.
public struct LifecycleSignals: Sendable, Equatable {
    /// Hold the lease, connect, synchronize, send. Off quiesces the transport and releases the lease.
    public var transportWanted: Bool
    /// Drives XEP-0352 CSI: `<active/>` while visible, `<inactive/>` once no window is.
    public var windowVisible: Bool
    /// Gates displayed markers, XEP-0490 read state and banner suppression for the open chat.
    public var readsOpenChat: Bool
    /// Available presence, or away with XEP-0319 idle. Never derived from window focus: every presence change wakes
    /// the account's other devices.
    public var present: Bool

    public init(transportWanted: Bool, windowVisible: Bool, readsOpenChat: Bool, present: Bool) {
        self.transportWanted = transportWanted; self.windowVisible = windowVisible
        self.readsOpenChat = readsOpenChat; self.present = present
    }

    /// The state a process starts in.
    public static let inFront = LifecycleSignals(transportWanted: true, windowVisible: true, readsOpenChat: true, present: true)
    public static let away = LifecycleSignals(transportWanted: false, windowVisible: false, readsOpenChat: false, present: false)

    public func readingChat(openChatID: String?) -> String? { readsOpenChat ? openChatID : nil }

    public func reading(_ chatID: String, openChatID: String?) -> Bool { readingChat(openChatID: openChatID) == chatID }

    /// A stream that binds while the transport is going away binds with the defaults: the quiesce that closes it
    /// announces away itself.
    public var streamBinding: StreamBinding {
        guard transportWanted else { return StreamBinding(presence: .available, clientActive: true) }
        return StreamBinding(presence: present ? .available : .away, clientActive: windowVisible)
    }
}

/// The presence and XEP-0352 state a new stream announces when it binds.
public struct StreamBinding: Sendable, Equatable {
    public var presence: LifecycleTransition.Presence
    public var clientActive: Bool
    public init(presence: LifecycleTransition.Presence, clientActive: Bool) { self.presence = presence; self.clientActive = clientActive }
}

/// One step a lifecycle driver asks the app to take, in order.
public enum LifecycleUpdate: Sendable, Equatable {
    /// Sets the initial signals before any transport work; nothing runs.
    case start(LifecycleSignals)
    /// The time of the last interaction (nil means now). It becomes the last-seen time every away presence sends as
    /// XEP-0319 idle.
    case interactionEnded(at: Date?)
    /// Runs `LifecycleTransition.between`, also when the signals are unchanged. `activated` (the user brought the
    /// app forward) repeats the return-to-front work; a focus or occlusion change alone does not.
    case change(LifecycleSignals, activated: Bool)
}

/// Pure policy for a signal change.
public struct LifecycleTransition: Sendable, Equatable {
    public enum Presence: Sendable, Equatable { case available, away }

    /// Open deferred storage, re-read notification permission, reconnect without waiting for the back-off, refresh.
    public var resumesTransport = false
    /// Blocks new transport and crypto work at once, then (after `presence`) disconnects with a final `<a/>`, joins
    /// every reader, consumer, sender and UI crypto mutation, and only then releases the lease.
    public var quiescesTransport = false
    /// With a `presence`, `<active/>` goes before it and `<inactive/>` after; nil sends none.
    public var clientActive: Bool?
    /// Sent before anything else in the transition; nil sends none. Never set without `clientActive`.
    public var presence: Presence?

    public init(resumesTransport: Bool = false, quiescesTransport: Bool = false, clientActive: Bool? = nil, presence: Presence? = nil) {
        self.resumesTransport = resumesTransport; self.quiescesTransport = quiescesTransport
        self.clientActive = clientActive; self.presence = presence
    }

    public static func between(_ old: LifecycleSignals, _ new: LifecycleSignals, activated: Bool = false) -> LifecycleTransition {
        // The session may hibernate for days, so it must read as away and inactive before it goes.
        guard new.transportWanted else { return LifecycleTransition(quiescesTransport: true, clientActive: false, presence: .away) }
        var transition = LifecycleTransition()
        transition.resumesTransport = !old.transportWanted || activated
        if old.transportWanted, old.present != new.present {
            // A new stream announces both in its binding instead.
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

/// Turns one platform's lifecycle events into `LifecycleUpdate`s; nothing else changes the signals. Drivers are pure,
/// so the platform glue only forwards events.
public protocol LifecycleDriver {
    associatedtype Event
    var signals: LifecycleSignals { get }
    mutating func updates(for event: Event) -> [LifecycleUpdate]
}

/// iOS: the scene phase drives all four signals together: on at every `.active`, off only at `.background`, and the
/// last-seen time recorded whenever the scene leaves `.active`. A launch into the background starts away and turns
/// on at its first activation, whether or not a scene phase change was seen.
public struct SceneLifecycleDriver: LifecycleDriver {
    /// SwiftUI's `ScenePhase` without SwiftUI. Map an unknown future phase to `.inactive`: neither on nor off.
    public enum Phase: Sendable, Equatable { case active, inactive, background }

    public enum Event: Sendable, Equatable {
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

/// Which signal each attention-dependent feature follows. On iOS every one follows the transport (the scene); a
/// desktop app holds the transport with no window, so there each follows the signal that matches it.
public struct AttentionRules: Sendable, Equatable {
    public static let phone = AttentionRules(desktop: false)
    public static let desktop = AttentionRules(desktop: true)

    public let desktop: Bool

    /// The chat whose banners `willPresent` hides. A frontmost Mac app is not necessarily being read.
    public func bannerHiddenChat(_ signals: LifecycleSignals, openChatID: String?) -> String? {
        desktop ? signals.readingChat(openChatID: openChatID) : openChatID
    }

    public func clearsNotifications(of chatID: String, _ signals: LifecycleSignals, openChatID: String?) -> Bool {
        desktop ? signals.reading(chatID, openChatID: openChatID) : openChatID == chatID
    }

    public func showsDeliveryAlert(_ signals: LifecycleSignals) -> Bool {
        desktop ? signals.windowVisible : signals.transportWanted
    }

    public func sendsChatStates(_ signals: LifecycleSignals) -> Bool {
        desktop ? signals.transportWanted && signals.readsOpenChat : signals.transportWanted
    }

    /// On a Mac a draft left mid-sentence ends the chat state when the user stops reading, instead of going from
    /// composing to paused.
    public func endsChatState(from old: LifecycleSignals, to new: LifecycleSignals) -> Bool {
        desktop && sendsChatStates(old) && !sendsChatStates(new)
    }

    /// iOS catches up only in front and drops caught-up banners. A desktop app often catches up with nobody at it, so
    /// it holds them until the walk and the other devices' read state are in, then posts one banner per chat.
    public var holdsCatchUpBanners: Bool { desktop }

    /// On a Mac the newest visible message is then marked read and the chat's notifications removed. On iOS cells
    /// mark messages read as they appear.
    public func startsReading(from old: LifecycleSignals, to new: LifecycleSignals) -> Bool {
        desktop && !old.readsOpenChat && new.readsOpenChat
    }
}
