import Foundation

/// The Mac: the transport stays for as long as the app runs and the Mac is awake, closing a window never drops it, and
/// attention comes from the app, its windows, the screen lock and the time since the last input. Pure: the AppKit,
/// IOKit and Quartz glue (`Mac/MacLifecycle.swift`) only reads those facts and forwards them with the input clock, so
/// every mapping below is unit-tested on its own.
///
/// - `transportWanted`: the app runs, the Mac is not going to sleep, the app is not quitting, and the user's login
///   session is the active one (not switched away from). Whether an account is signed in is the model's own
///   condition (`wantsConnection`); signing in needs the transport wanted.
/// - `windowVisible`: some window of the app is visible (`NSApplication.occlusionState`) and the screen is unlocked.
/// - `present`: input within `idleThreshold`, the screen unlocked, and the transport wanted.
/// - `readsOpenChat`: present, a window visible, the app active, and the chat's window key and visible.
/// - `activated`: the app became active (`didBecomeActive`). Key-window changes inside the app are not activations.
/// - `interactionEnded` carries the time of the last input whenever `present` turns off.
public struct MacLifecycleDriver: LifecycleDriver {
    /// No input for this long makes the user away.
    public static let idleThreshold: TimeInterval = 300
    /// How often the glue reads the input clock while the user is away, to notice them coming back.
    public static let awayPollInterval: TimeInterval = 10

    /// What the app and its windows look like, as AppKit reports them.
    public struct Windows: Sendable, Equatable, CustomStringConvertible {
        /// `NSApplication.isActive`.
        public var appActive: Bool
        /// `NSApplication.occlusionState` contains `.visible`.
        public var appVisible: Bool
        /// The main (chat) window is the key window.
        public var chatWindowKey: Bool
        /// The main window's own occlusion state contains `.visible` and it is not minimised.
        public var chatWindowVisible: Bool

        public init(appActive: Bool, appVisible: Bool, chatWindowKey: Bool, chatWindowVisible: Bool) {
            self.appActive = appActive; self.appVisible = appVisible
            self.chatWindowKey = chatWindowKey; self.chatWindowVisible = chatWindowVisible
        }

        /// No window on screen and the app in the background: a launch at login, or every window closed.
        public static let none = Windows(appActive: false, appVisible: false, chatWindowKey: false, chatWindowVisible: false)
        /// The chat window in front and key.
        public static let reading = Windows(appActive: true, appVisible: true, chatWindowKey: true, chatWindowVisible: true)

        public var description: String {
            "active \(appActive ? 1 : 0) visible \(appVisible ? 1 : 0) chatKey \(chatWindowKey ? 1 : 0) chatVisible \(chatWindowVisible ? 1 : 0)"
        }
    }

    public enum Change: Sendable, Equatable {
        /// When the glue is installed, before the model prepares: the signals the process starts with.
        case launched(Windows)
        /// Activation, occlusion, key window, minimise, hide or close changed what `Windows` reports.
        case windows(Windows)
        /// `com.apple.screenIsLocked` (true) / `com.apple.screenIsUnlocked` (false).
        case screenLocked(Bool)
        /// `NSWorkspace.sessionDidResignActiveNotification` (false: a fast user switch away) / `sessionDidBecomeActive`.
        case sessionActive(Bool)
        /// `kIOMessageSystemWillSleep`: the glue holds the acknowledgement until the quiesce ends, bounded.
        case willSleep
        /// `kIOMessageSystemHasPoweredOn`.
        case didWake
        /// `applicationShouldTerminate`: the glue replies once the quiesce ends, bounded.
        case willTerminate
        /// The glue's idle timer fired (`secondsUntilIdleCheck`).
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
    /// No input for `idleThreshold`, as of the last event.
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
        // Recorded before the change, so the away presence it sends (or the quiesce's) carries the last input.
        if old.present, !new.present { updates.append(.interactionEnded(at: lastInput)) }
        let activated = !wasActive && windows.appActive && new.transportWanted
        if new != old || activated { updates.append(.change(new, activated: activated)) }
        return updates
    }

    /// When the glue should read the input clock next: when the user would turn idle, while present, and every
    /// `awayPollInterval` while away, so a return is noticed within it. Away is debounced to `idleThreshold` without
    /// any input, and a burst of input changes presence at most once per check.
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
