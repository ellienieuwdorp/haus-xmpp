import Foundation

/// The Mac: the transport stays while the app runs, the Mac is awake and the login session is active; closing a
/// window never drops it. Attention comes from the app, its windows, the screen lock and the time since the last
/// input. Only app activation counts as `activated`, not key-window changes inside the app.
public struct MacLifecycleDriver: LifecycleDriver {
    public static let idleThreshold: TimeInterval = 300
    /// How often the glue reads the input clock while the user is away, to notice them coming back.
    public static let awayPollInterval: TimeInterval = 10

    public struct Windows: Sendable, Equatable, CustomStringConvertible {
        /// `NSApplication.isActive`.
        public var appActive: Bool
        /// `NSApplication.occlusionState` contains `.visible`.
        public var appVisible: Bool
        public var chatWindowKey: Bool
        /// Its own occlusion state contains `.visible` and it is not minimised.
        public var chatWindowVisible: Bool

        public init(appActive: Bool, appVisible: Bool, chatWindowKey: Bool, chatWindowVisible: Bool) {
            self.appActive = appActive; self.appVisible = appVisible
            self.chatWindowKey = chatWindowKey; self.chatWindowVisible = chatWindowVisible
        }

        /// A launch at login, or every window closed.
        public static let none = Windows(appActive: false, appVisible: false, chatWindowKey: false, chatWindowVisible: false)
        public static let reading = Windows(appActive: true, appVisible: true, chatWindowKey: true, chatWindowVisible: true)

        public var description: String {
            "active \(appActive ? 1 : 0) visible \(appVisible ? 1 : 0) chatKey \(chatWindowKey ? 1 : 0) chatVisible \(chatWindowVisible ? 1 : 0)"
        }
    }

    public enum Change: Sendable, Equatable {
        /// Sent before the model prepares.
        case launched(Windows)
        case windows(Windows)
        /// `com.apple.screenIsLocked` (true) / `com.apple.screenIsUnlocked` (false).
        case screenLocked(Bool)
        /// `NSWorkspace.sessionDidResignActiveNotification` (false, a fast user switch) / `sessionDidBecomeActive`.
        case sessionActive(Bool)
        /// `kIOMessageSystemWillSleep`: the glue holds the acknowledgement until the quiesce ends, bounded.
        case willSleep
        /// `kIOMessageSystemHasPoweredOn`.
        case didWake
        /// `applicationShouldTerminate`: the glue replies once the quiesce ends, bounded.
        case willTerminate
        case idleChecked
    }

    public struct Event: Sendable, Equatable {
        public var change: Change
        public var now: Date
        /// `CGEventSourceSecondsSinceLastEventType` for any input, read with the event.
        public var secondsSinceInput: TimeInterval

        public init(_ change: Change, now: Date, secondsSinceInput: TimeInterval) {
            self.change = change; self.now = now; self.secondsSinceInput = secondsSinceInput
        }
    }

    public private(set) var signals = LifecycleSignals.inFront
    public private(set) var windows = Windows.none
    public private(set) var screenLocked = false
    public private(set) var sessionActive = true
    public private(set) var sleeping = false
    public private(set) var terminating = false
    public private(set) var idle = false

    public init() {}

    public mutating func updates(for event: Event) -> [LifecycleUpdate] {
        idle = event.secondsSinceInput >= Self.idleThreshold
        let lastInput = event.now.addingTimeInterval(-max(0, event.secondsSinceInput))
        let wasActive = windows.appActive
        switch event.change {
        case .launched(let windows), .windows(let windows): self.windows = windows
        case .screenLocked(let locked): screenLocked = locked
        case .sessionActive(let active): sessionActive = active
        case .willSleep: sleeping = true
        case .didWake: sleeping = false
        case .willTerminate: terminating = true
        case .idleChecked: break
        }
        let old = signals
        let new = currentSignals
        signals = new
        if case .launched = event.change { return [.start(new)] }
        var updates: [LifecycleUpdate] = []
        // Before the change, so the away presence it causes carries the last input.
        if old.present, !new.present { updates.append(.interactionEnded(at: lastInput)) }
        let activated = !wasActive && windows.appActive && new.transportWanted
        if new != old || activated { updates.append(.change(new, activated: activated)) }
        return updates
    }

    /// A burst of input changes presence at most once per check.
    public func secondsUntilIdleCheck(secondsSinceInput: TimeInterval) -> TimeInterval {
        signals.present ? max(1, Self.idleThreshold - secondsSinceInput) : Self.awayPollInterval
    }

    private var currentSignals: LifecycleSignals {
        let transport = !sleeping && !terminating && sessionActive
        let present = transport && !screenLocked && !idle
        let visible = transport && windows.appVisible && !screenLocked
        let reading = present && visible && windows.appActive && windows.chatWindowKey && windows.chatWindowVisible
        return LifecycleSignals(transportWanted: transport, windowVisible: visible, readsOpenChat: reading, present: present)
    }
}
