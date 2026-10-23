#if DEBUG
import AppKit
import MessagingCore
import OMEMO
import SwiftUI

/// Debug checks of the Mac lifecycle (`MacLifecycle`, `MacLifecycleDriver`). Debug builds only.
///
/// Every event `MacLifecycle` applies is logged with the four signals, what AppKit reported, the transition it runs and
/// the scene phase each window's content last reported. `-haus-lifecycle-steps "<step>; <step>; …"` then plays a
/// scenario once the launch hooks are done. Nothing here sleeps, locks or logs out the Mac: sleep, wake, the screen lock
/// and idleness are simulated by calling the same handlers the system's events call, and focus by `simulatedActive`
/// (an unobtrusive window is never key and always occluded). Closing, minimising and hiding are real.
///
/// Steps: `wait <seconds>`, `activate` / `deactivate` (simulated focus; the first one turns simulation on), `real`
/// (AppKit's own focus again), `hide`, `unhide`, `minimise`, `close`, `open`, `lock`, `unlock`, `idle <minutes>` (the last
/// input that long ago, in place of the real input clock; `idle 0` is input just now), `input` (the real clock again),
/// `sleep` (a fake acknowledgement), `sleep-miss` (a UI crypto operation held past the sleep deadline first),
/// `wake`, `select <chat>`, `accept <jid>|<room>` (accepts that lab or staging contact's undecided devices, as the
/// Devices page would, or a joined lab room's members' undecided devices, as Group details would), `draft <text>` (the
/// open chat's composer changed), `report` (lease and session), `store <chat>` (a lab account's retained ciphertext, the
/// room's devices and the chat's stored messages, without content), `notify <step>` (notification actions and settings,
/// `MacNotificationDebug`), `drop-socket` (the live stream stops reading and writing without an error, as on a dead
/// network path: the app notices only through its liveness probes, so a push the server then sends reaches the
/// extension, whose liveness ring makes the app probe and reconnect), `hold-acks <seconds>` (the live stream leaves the
/// server's acknowledgement requests unanswered that long, default 35, then answers once and goes on: the server pushes
/// for a healthy session, and the app's probe is answered without a reconnect), `sign-out` (as Settings' Sign Out, which
/// turns push off at the gateway and the server, so a staging run ends clean), `quit`.
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
            case "open":
                window.showMainWindow()
                // An unobtrusive window posts no key or occlusion change when it comes back, so tell the driver.
                try? await Task.sleep(for: .milliseconds(200))
                lifecycle.windowsChanged()
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
            case "store" where model.isLabAccount:
                MacDebugHooks.log("store \(argument): \(await model.debugRetentionReport(argument)); \(await model.debugMessageReport(argument))")
            case "draft": if let chat = window.selection { model.draftChanged(argument, in: chat) }
            case "report": MacDebugHooks.log("report: \(await model.debugLeaseReport()), scenePhase \(phases)")
            case "notify": await MacNotificationDebug.run(argument, model: model, window: window)
            case "drop-socket": MacDebugHooks.log("step drop-socket: \(await model.debugSilenceTransport() ? "stream silenced" : "no stream online")")
            case "hold-acks":
                let seconds = Double(argument) ?? 35
                let held = await model.debugHoldAcknowledgements(for: .seconds(seconds))
                MacDebugHooks.log("step hold-acks: \(held ? "acknowledgements held \(Int(seconds)) s" : "no stream online")")
            case "sign-out":
                await model.signOut()
                MacDebugHooks.log("step sign-out: \(model.accountID.isEmpty ? "signed out" : "still signed in")")
            case "quit": MacDebugHooks.quit()
            default: MacDebugHooks.log("step \(step): unknown")
            }
        }
    }

    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(MacAppDelegate.mainWindowID) == true }
    }

    /// What the Devices page's Accept does, for a contact on a lab or staging server only: a lab run cannot click it.
    /// For a joined lab room, what Group details' Accept does for each undecided device of another member: a room is
    /// OMEMO 2 only, while a contact's own page lists the version their 1:1 chat uses, which may be the other record of
    /// the same device ID.
    private static func accept(_ address: String, model: AppModel) async {
        let parts = address.split(separator: "@")
        let isLabContact = parts.count == 2 && AppModel.labDomains.contains(String(parts[1]))
        guard model.isLabAccount, isLabContact || model.isGroup(address) && address.hasSuffix("@rooms.localhost") else {
            MacDebugHooks.log("accept: only for a lab account and a lab contact or room")
            return
        }
        let devices: [EncryptionDevice]
        if model.isGroup(address) {
            await model.loadGroupDetails(room: address)
            devices = model.groupChats[address]?.devices.filter {
                $0.jid != model.accountID && $0.jid.hasSuffix("@localhost") && $0.active && $0.trust == .undecided
            } ?? []
        } else {
            await model.loadEncryptionDetails(for: address)
            devices = model.encryptionOverview(for: address)?.devices.filter { $0.jid == address && $0.trust == .undecided } ?? []
        }
        for device in devices { await model.setDeviceTrust(device, trust: .accepted, chatID: address) }
        MacDebugHooks.log("accept: \(devices.count) device(s) of \(address)" + devices.map { " \($0.deviceID) \($0.profile.label)" }.joined(separator: ","))
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
#endif
