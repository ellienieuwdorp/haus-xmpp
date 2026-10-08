import Foundation

/// What the app process should do and what the user can see, as four separate signals
/// (docs/development/lifecycle-signals.md). On iOS all four follow the scene: on at `.active`, off at `.background`.
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
}

/// One step a lifecycle driver asks the app to take, in order.
public enum LifecycleUpdate: Sendable, Equatable {
    /// The signals the process starts with, before any transport work: set, and nothing runs.
    case start(LifecycleSignals)
    /// The user stopped interacting (iOS: the scene left `.active`). That moment becomes the last-seen time, sent as
    /// XEP-0319 idle by every away presence until the next one.
    case interactionEnded
    /// New signals. The app runs `LifecycleTransition.between(current, new)`, also when they equal the current
    /// ones: every iOS activation repeats the return-to-front work.
    case change(LifecycleSignals)
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
    /// XEP-0352 state for the live stream; nil sends none.
    public var clientActive: Bool?
    /// Presence for the live stream, sent before anything else in the transition; nil sends none.
    public var presence: Presence?

    public init(resumesTransport: Bool = false, quiescesTransport: Bool = false, clientActive: Bool? = nil, presence: Presence? = nil) {
        self.resumesTransport = resumesTransport; self.quiescesTransport = quiescesTransport
        self.clientActive = clientActive; self.presence = presence
    }

    public static func between(_ old: LifecycleSignals, _ new: LifecycleSignals) -> LifecycleTransition {
        // The session hibernates (up to days with push), so it must read as away before it goes, whatever `present`
        // says. Away presence carries CSI <inactive/> and the disconnect follows, so no separate CSI.
        guard new.transportWanted else { return LifecycleTransition(quiescesTransport: true, presence: .away) }
        var transition = LifecycleTransition()
        // The transport (re)starting, or a window showing, which on iOS is every activation.
        transition.resumesTransport = !old.transportWanted || new.windowVisible
        if new.windowVisible { transition.clientActive = true }
        else if old.transportWanted, old.windowVisible { transition.clientActive = false }
        // A stream that stays up announces the user coming and going. A new one announces itself when it binds.
        if old.transportWanted, old.present != new.present { transition.presence = new.present ? .available : .away }
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
            if previous == .active, phase != .active { updates.append(.interactionEnded) }
            if phase == .active { signals = .inFront; updates.append(.change(.inFront)) }
            else if phase == .background { signals = .away; updates.append(.change(.away)) }
        case .becameActive:
            guard !signals.transportWanted else { break }
            signals = .inFront
            updates.append(.change(.inFront))
        }
        return updates
    }
}
