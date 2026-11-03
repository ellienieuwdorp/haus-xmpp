import AppKit
import CoreGraphics
import IOKit.pwr_mgt
import MessagingCore

// The app delegate owns it, so it observes once per process. The transport stays while the app runs (closing the last
// window changes CSI only); sleep and quit quiesce first, bounded, and a sleep past the deadline keeps the lease rather
// than releasing it by force. Automatic termination is off while the transport is wanted.
@MainActor final class MacLifecycle {
    // Well under the 30 s the system allows before sleeping anyway.
    static let sleepDeadline: Duration = .seconds(5)
    // Termination without the quiesce is safe (the kernel releases the lease and the next claim recovers interrupted
    // sends); only the final `<a/>` is missing.
    static let quitDeadline: Duration = .seconds(5)

    private let model: AppModel
    private(set) var driver = MacLifecycleDriver()
    private var observers: [(NotificationCenter, any NSObjectProtocol)] = []
    private var power: MacSystemPower?
    private var idleCheck: Task<Void, Never>?
    private var automaticTerminationDisabled = false
    private var quitting = false

    #if DEBUG
    // Off-screen Debug windows never report key or visible, so `MacLifecycleDebug` models focus here; closing,
    // minimising and hiding stay real.
    var simulatedActive: Bool? { didSet { windowsChanged() } }
    // Lets `idle 0` mean input just now while the Mac's user is away; nil reads the real clock.
    var simulatedLastInput: Date? { didSet { apply(.idleChecked) } }
    var onApply: ((String, MacLifecycleDriver, [LifecycleUpdate]) -> Void)?
    #endif

    init(model: AppModel) {
        self.model = model
    }

    // Before the model prepares.
    func install() {
        apply(.launched(currentWindows()))
        let app = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSApplication.didHideNotification, NSApplication.didUnhideNotification,
                     NSApplication.didChangeOcclusionStateNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification] {
            observe(app, name) { $0.windowsChanged() }
        }
        // A closing window is still listed and visible while this is posted.
        observe(app, NSWindow.willCloseNotification) { lifecycle in Task { @MainActor in lifecycle.windowsChanged() } }
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.screenLocked(true) }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.screenLocked(false) }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.apply(.sessionActive(false)) }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.apply(.sessionActive(true)) }
        let power = MacSystemPower()
        power.onWillSleep = { [weak self] acknowledge in self?.willSleep(acknowledge: acknowledge) }
        power.onDidWake = { [weak self] in self?.didWake() }
        if power.start() {
            self.power = power
            log("power: registered for sleep and wake")
        } else {
            // NSWorkspace's notification is not waited for, so sleep may begin mid-quiesce, keeping the lease as a
            // missed deadline does.
            log("power: IORegisterForSystemPower failed; using NSWorkspace sleep notifications")
            observe(workspace, NSWorkspace.willSleepNotification) { $0.willSleep(acknowledge: {}) }
            observe(workspace, NSWorkspace.didWakeNotification) { $0.didWake() }
        }
    }

    func windowsChanged() {
        let windows = currentWindows()
        guard windows != driver.windows else { return }
        apply(.windows(windows))
    }

    func screenLocked(_ locked: Bool) { apply(.screenLocked(locked)) }

    // Acknowledges once the quiesce ends or at `deadline`; the quiesce is never cut short, so past the deadline the
    // process freezes holding the lease and finishes after wake.
    func willSleep(deadline: Duration = sleepDeadline, acknowledge: @escaping @MainActor () -> Void) {
        let started = ContinuousClock.now
        apply(.willSleep)
        Task {
            let quiesced = await settled(within: deadline)
            log("sleep acknowledged after \(Self.milliseconds(since: started)) ms: \(quiesced ? "quiesced" : "deadline passed, quiesce still running")")
            acknowledge()
            #if DEBUG
            log("at acknowledgement: \(await model.debugLeaseReport())")
            if !quiesced {
                await model.lifecycleSettled()
                log("quiesce ended after \(Self.milliseconds(since: started)) ms: \(await model.debugLeaseReport())")
            }
            #endif
        }
    }

    func didWake() { apply(.didWake) }

    func shouldTerminate() -> NSApplication.TerminateReply {
        guard !quitting else { return .terminateLater }
        quitting = true
        let started = ContinuousClock.now
        apply(.willTerminate)
        Task {
            let quiesced = await settled(within: Self.quitDeadline)
            log("quit after \(Self.milliseconds(since: started)) ms: \(quiesced ? "quiesced" : "deadline passed")")
            #if DEBUG
            log("at quit: \(await model.debugLeaseReport())")
            #endif
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func apply(_ change: MacLifecycleDriver.Change) {
        let updates = driver.updates(for: .init(change, now: Date(), secondsSinceInput: secondsSinceInput()))
        model.applyLifecycle(updates)
        let wanted = driver.signals.transportWanted
        if wanted != automaticTerminationDisabled {
            if wanted { ProcessInfo.processInfo.disableAutomaticTermination("Connected to the account") }
            else { ProcessInfo.processInfo.enableAutomaticTermination("Connected to the account") }
            automaticTerminationDisabled = wanted
        }
        scheduleIdleCheck()
        #if DEBUG
        onApply?(Self.name(change), driver, updates)
        #endif
    }

    private func scheduleIdleCheck() {
        idleCheck?.cancel()
        let delay = driver.secondsUntilIdleCheck(secondsSinceInput: secondsSinceInput())
        idleCheck = Task { [weak self] in
            guard (try? await Task.sleep(for: .seconds(delay), tolerance: .seconds(1))) != nil, let self else { return }
            self.apply(.idleChecked)
        }
    }

    // Reading the input clock needs no permission.
    private func secondsSinceInput() -> TimeInterval {
        var seconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        #if DEBUG
        if let simulatedLastInput { seconds = Date().timeIntervalSince(simulatedLastInput) }
        #endif
        return seconds
    }

    private var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(MacAppDelegate.mainWindowID) == true }
    }

    private func currentWindows() -> MacLifecycleDriver.Windows {
        let main = mainWindow
        #if DEBUG
        if let simulatedActive {
            // As if the windows were on screen: shown unless closed, minimised or hidden with the app.
            let shown = !NSApp.isHidden && (main.map { $0.isVisible && !$0.isMiniaturized } ?? false)
            let active = simulatedActive && !NSApp.isHidden
            return .init(appActive: active, appVisible: shown, chatWindowKey: active && shown, chatWindowVisible: shown)
        }
        #endif
        let chatVisible = main.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
        return .init(appActive: NSApp.isActive, appVisible: NSApp.occlusionState.contains(.visible),
                     chatWindowKey: main?.isKeyWindow ?? false, chatWindowVisible: chatVisible)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor (MacLifecycle) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { handler(self) } }
        }
        observers.append((center, token))
    }

    // The transitions go on either way.
    private func settled(within limit: Duration) async -> Bool {
        let once = Once()
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                await self.model.lifecycleSettled()
                if once.claim() { continuation.resume(returning: true) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: limit)
                if once.claim() { continuation.resume(returning: false) }
            }
        }
    }

    // `claimed` is read and set only under `lock`.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool { lock.withLock { defer { claimed = true }; return !claimed } }
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        Int((ContinuousClock.now - start) / .milliseconds(1))
    }

    private static func name(_ change: MacLifecycleDriver.Change) -> String {
        switch change {
        case .launched: "launched"
        case .windows: "windows"
        case .screenLocked(let locked): locked ? "screen locked" : "screen unlocked"
        case .sessionActive(let active): active ? "session active" : "session resigned"
        case .willSleep: "will sleep"
        case .didWake: "did wake"
        case .willTerminate: "will terminate"
        case .idleChecked: "idle check"
        }
    }

    private func log(_ text: String) {
        #if DEBUG
        MacDebugHooks.log("lifecycle " + text)
        #endif
    }
}

// Sleep announced here waits (up to 30 s) for an acknowledgement, unlike `NSWorkspace.willSleepNotification`, so the
// quiesce can finish. Main thread only: created there, with its run-loop source on the main run loop.
final class MacSystemPower: @unchecked Sendable {
    // iokit_common_msg(message) is (sys_iokit | sub_iokit_common | message); the macros do not reach Swift.
    private static let canSystemSleep: UInt32 = 0xE000_0270
    private static let systemWillSleep: UInt32 = 0xE000_0280
    private static let systemHasPoweredOn: UInt32 = 0xE000_0300

    var onWillSleep: (@MainActor (@escaping @MainActor () -> Void) -> Void)?
    var onDidWake: (@MainActor () -> Void)?
    private var rootPort: io_connect_t = 0
    private var notifier: io_object_t = 0
    private var port: IONotificationPortRef?

    func start() -> Bool {
        let context = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(context, &port, { context, _, message, argument in
            guard let context else { return }
            let power = Unmanaged<MacSystemPower>.fromOpaque(context).takeUnretainedValue()
            power.received(message, argument: argument)
        }, &notifier)
        guard rootPort != 0, let port else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)
        return true
    }

    private func received(_ message: UInt32, argument: UnsafeMutableRawPointer?) {
        let notification = Int(bitPattern: argument)
        let root = rootPort
        MainActor.assumeIsolated {
            switch message {
            // Idle sleep asks first; a messaging app never vetoes it.
            case Self.canSystemSleep: IOAllowPowerChange(root, notification)
            case Self.systemWillSleep:
                guard let onWillSleep else { IOAllowPowerChange(root, notification); return }
                onWillSleep { IOAllowPowerChange(root, notification) }
            case Self.systemHasPoweredOn: onDidWake?()
            default: break
            }
        }
    }
}
