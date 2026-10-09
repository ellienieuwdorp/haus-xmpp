#if DEBUG
import AppKit
import MessagingCore
import SwiftUI

/// Debug checks of the Mac lifecycle (docs/development/lifecycle-signals.md, "What the Mac does"). Debug builds only.
///
/// Every event `MacLifecycle` applies is logged with the four signals, what AppKit reported, the transition it runs and
/// the scene phase each window's content last reported. `-haus-lifecycle-steps "<step>; <step>; …"` then plays a
/// scenario once the launch hooks are done. Nothing here sleeps, locks or logs out the Mac: sleep, wake, the screen lock
/// and idleness are simulated by calling the same handlers the system's events call, and focus by `simulatedActive`
/// (an unobtrusive window is never key and always occluded). Closing, minimising and hiding are real.
///
/// Steps: `wait <seconds>`, `activate` / `deactivate` (simulated focus; the first one turns simulation on), `real`
/// (AppKit's own focus again), `hide`, `unhide`, `minimise`, `close`, `open`, `lock`, `unlock`, `idle <minutes>`,
/// `input`, `sleep` (a fake acknowledgement), `sleep-miss` (a UI crypto operation held past the sleep deadline first),
/// `wake`, `select <chat>`, `accept <jid>` (accepts that lab contact's undecided devices, as the Devices page would),
/// `draft <text>` (the open chat's composer changed), `report` (lease and session), `quit`.
@MainActor enum MacLifecycleDebug {
    /// The scene phase each window's content last reported, by window.
    static var scenePhases: [String: ScenePhase] = [:]
    private static var applied: LifecycleSignals?

    static func attach(to lifecycle: MacLifecycle) {
        lifecycle.onApply = { change, driver, updates in
            let signals = driver.signals
            var line = "lifecycle \(change): \(describe(signals)) | \(driver.windows), locked \(driver.screenLocked ? 1 : 0), idle \(driver.idle ? 1 : 0)"
            for update in updates {
                switch update {
                case .start: line += " | start"
                case .interactionEnded(let at): line += " | interactionEnded \(at.map { "\(Int(Date().timeIntervalSince($0))) s ago" } ?? "now")"
                case .change(let new, let activated):
                    if let old = applied { line += " | \(describe(LifecycleTransition.between(old, new, activated: activated)))" }
                    if activated { line += " (activated)" }
                }
            }
            if updates.isEmpty { line += " | no update" }
            applied = signals
            line += " | scenePhase " + phases
            MacDebugHooks.log(line)
        }
    }

    static var phases: String {
        scenePhases.isEmpty ? "none" : scenePhases.keys.sorted().map { "\($0)=\(name(scenePhases[$0]!))" }.joined(separator: " ")
    }

    static func name(_ phase: ScenePhase) -> String {
        switch phase {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }

    private static func describe(_ signals: LifecycleSignals) -> String {
        "transport \(signals.transportWanted ? 1 : 0) window \(signals.windowVisible ? 1 : 0) reading \(signals.readsOpenChat ? 1 : 0) present \(signals.present ? 1 : 0)"
    }

    private static func describe(_ transition: LifecycleTransition) -> String {
        var parts: [String] = []
        if transition.quiescesTransport { parts.append("quiesce") }
        if transition.resumesTransport { parts.append("resume") }
        if let presence = transition.presence { parts.append("presence \(presence == .available ? "available" : "away")") }
        if let active = transition.clientActive { parts.append("csi \(active ? "active" : "inactive")") }
        return parts.isEmpty ? "no transport, presence or CSI work" : parts.joined(separator: ", ")
    }

    // MARK: Steps

    static func run(_ script: String, lifecycle: MacLifecycle, model: AppModel, window: MacWindowState) async {
        let steps = script.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for step in steps {
            let words = step.split(separator: " ", maxSplits: 1).map(String.init)
            let argument = words.count > 1 ? words[1] : ""
            if words[0] != "wait" { MacDebugHooks.log("step \(step)") }
            switch words[0] {
            case "wait": try? await Task.sleep(for: .seconds(Double(argument) ?? 1))
            case "activate": lifecycle.simulatedActive = true
            case "deactivate": lifecycle.simulatedActive = false
            case "real": lifecycle.simulatedActive = nil
            case "hide":
                // A real hide deactivates the app, and `unhide` (without activation) does not bring it back.
                if lifecycle.simulatedActive != nil { lifecycle.simulatedActive = false }
                NSApp.hide(nil)
            case "unhide": NSApp.unhideWithoutActivation()
            case "minimise": mainWindow?.miniaturize(nil)
            case "close": mainWindow?.performClose(nil)
            case "open": window.openWindow?(id: MacAppDelegate.mainWindowID)
            case "lock": lifecycle.screenLocked(true)
            case "unlock": lifecycle.screenLocked(false)
            case "idle": lifecycle.simulatedLastInput = Date().addingTimeInterval(-(Double(argument) ?? 6) * 60)
            case "input": lifecycle.simulatedLastInput = nil
            case "sleep": lifecycle.willSleep { MacDebugHooks.log("step sleep: fake acknowledgement, sleep may proceed") }
            case "sleep-miss":
                // A UI crypto operation the quiesce must wait for, held past the deadline.
                model.debugHoldEncryptionOperation(for: MacLifecycle.sleepDeadline + .seconds(3))
                lifecycle.willSleep { MacDebugHooks.log("step sleep-miss: fake acknowledgement, sleep may proceed") }
            case "wake": lifecycle.didWake()
            case "select": window.selection = argument
            case "accept": await accept(argument, model: model)
            case "draft": if let chat = window.selection { model.draftChanged(argument, in: chat) }
            case "report": MacDebugHooks.log("report: \(await model.debugLeaseReport()), scenePhase \(phases)")
            case "quit": MacDebugHooks.quit()
            default: MacDebugHooks.log("step \(step): unknown")
            }
        }
    }

    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(MacAppDelegate.mainWindowID) == true }
    }

    /// What the Devices page's Accept does, for a lab contact only: a lab run cannot click it.
    private static func accept(_ jid: String, model: AppModel) async {
        guard model.isLabAccount, jid.hasSuffix("@localhost") else {
            MacDebugHooks.log("accept: only for a lab account and a lab contact")
            return
        }
        await model.loadEncryptionDetails(for: jid)
        let devices = model.encryptionOverview(for: jid)?.devices.filter { $0.jid == jid && $0.trust == .undecided } ?? []
        for device in devices { await model.setDeviceTrust(device, trust: .accepted, chatID: jid) }
        MacDebugHooks.log("accept: \(devices.count) device(s) of \(jid)")
    }
}

/// Logs the scene phase a window's content sees, for `MacLifecycleDebug`.
struct MacScenePhaseLog: ViewModifier {
    let window: String
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.onChange(of: scenePhase, initial: true) { _, phase in
            MacLifecycleDebug.scenePhases[window] = phase
            MacDebugHooks.log("scenePhase \(window) \(MacLifecycleDebug.name(phase)) | all \(MacLifecycleDebug.phases)")
        }
        .onDisappear {
            MacLifecycleDebug.scenePhases[window] = nil
            MacDebugHooks.log("scenePhase \(window) content gone")
        }
    }
}

/// `-haus-log-notifications`: the model posts its notifications here instead of the notification centre, so a lab run
/// shows what would be posted without asking for permission (which would put a system prompt on screen). Logs the
/// thread and kind only, never a title or body.
enum MacDebugNotificationLog {
    static let poster: (any NotificationPosting)? =
        ProcessInfo.processInfo.arguments.contains("-haus-log-notifications") ? LoggingPoster() : nil

    struct LoggingPoster: NotificationPosting {
        func add(_ request: PlannedNotification) async throws {
            write("notification posted: thread \(request.threadIdentifier) category \(request.categoryIdentifier)")
        }
        func deliveredNotifications() async -> [DeliveredNotification] { [] }
        func removeDelivered(identifiers: [String]) async {
            if !identifiers.isEmpty { write("notification removed: \(identifiers.count)") }
        }
    }

    /// As `MacDebugHooks.log`, from outside the main actor.
    private static func write(_ text: String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "HH:mm:ss.SSS"
        FileHandle.standardOutput.write(Data("HAUS \(formatter.string(from: Date())) \(text)\n".utf8))
    }
}
#endif
