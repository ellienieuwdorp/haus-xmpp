#if DEBUG
import AppKit
import OMEMO
import SwiftUI

/// The device trust tour steps (`-haus-tour`; see `MacDebugHooks`). Debug builds only.
///
/// - `chat <address>`: opens a chat with that address (a lab contact), creating it as New Chat would.
/// - `join <room>`: joins that group (a lab room the account is a member of) and opens it.
/// - `devices`: logs the open chat's devices with their trust, and what the review banner and the account review see.
/// - `messages [<count>]`: logs the open chat's newest messages (default 4): direction, encryption, state and text.
///   For lab runs with synthetic messages only.
/// - The rest press a button as VoiceOver would (`MacKeyboardDebug.pressElement`), so they run the button's own action:
///   `device <id>` a device row in the inspector, `review` the banner's Review…,
///   `trust|verify|dont-trust|compare|remove <id>` that device's button in the newest open sheet (the review sheet, the
///   account's review or a fingerprint sheet), `confirm <button>` a confirmation dialog's button, `close-sheet` the
///   newest sheet's Done or Close.
/// - `own-review`: opens the account's device review, as the sidebar card's Review does (the sidebar's rows are not in
///   the accessibility tree of a window that was never on screen, so the button cannot be pressed).
@MainActor enum MacDeviceReviewTour {
    static func step(_ name: String, _ argument: String, model: AppModel, window: MacWindowState, mainWindow: NSWindow?) async {
        let buttons: [String: [String]] = [
            "device": ["encryptionDevice.", "waitingDevice.", "groupDevice."],
            "trust": ["deviceFingerprint.accept.", "deviceReview.trust.", "ownDevice.trust."],
            "verify": ["deviceFingerprint.verify."],
            "dont-trust": ["deviceFingerprint.block.", "deviceReview.reject.", "ownDevice.reject."],
            "compare": ["deviceReview.compare.", "ownDevice.compare."],
            "remove": ["deviceFingerprint.remove.", "ownDevice.remove."],
        ]
        if let prefixes = buttons[name] {
            guard let mainWindow else { return MacDebugHooks.log("tour \(name): no main window") }
            await MacKeyboardDebug.pressElement(matching: prefixes.map { $0 + argument }, in: mainWindow)
            return
        }
        switch name {
        case "own-review":
            window.reviewingOwnDevices = true
        case "review", "confirm", "close-sheet":
            guard let mainWindow else { return MacDebugHooks.log("tour \(name): no main window") }
            let texts = ["review": ["deviceReview.open"], "close-sheet": ["Done", "Close"]][name] ?? [argument]
            await MacKeyboardDebug.pressElement(matching: texts, in: mainWindow)
        case "chat":
            guard let chat = await model.createChat(argument) else { return MacDebugHooks.log("tour chat: refused (\(model.error ?? "no reason"))") }
            window.selection = chat
            for _ in 0..<100 where model.messagesLoadedFor != chat { try? await Task.sleep(for: .milliseconds(100)) }
            MacDebugHooks.log("tour chat: \(chat) open, \(model.messages.count) message(s)")
        case "join":
            guard let room = await model.joinGroup(room: argument, nickname: "mac") else { return MacDebugHooks.log("tour join: refused (\(model.error ?? "no reason"))") }
            window.selection = room
            for _ in 0..<100 where model.groupChats[room]?.devicesLoaded != true { try? await Task.sleep(for: .milliseconds(100)) }
            MacDebugHooks.log("tour join: \(room) open, joined \(model.groupChats[room]?.joined == true)")
        case "devices":
            logDevices(model: model, window: window)
        case "messages":
            for message in model.messages.suffix(Int(argument) ?? 4) {
                MacDebugHooks.log("message \(message.id): \(message.isOutgoing ? "out" : "in"), \(message.encryptionProfile ?? "plain"), "
                    + "\(message.transportState.map { "\($0)" } ?? "-"), '\(message.body.prefix(80))'")
            }
        default: break
        }
    }

    private static func logDevices(model: AppModel, window: MacWindowState) {
        guard let chat = window.selection else { return MacDebugHooks.log("devices: no chat open") }
        let devices = model.groupChats[chat]?.devices ?? model.encryptionOverview(for: chat)?.devices ?? []
        let profile = model.encryptionOverview(for: chat)?.profile.label ?? "-"
        MacDebugHooks.log("devices of \(chat) (sending with \(profile)): \(devices.isEmpty ? "none" : "")")
        for device in devices {
            MacDebugHooks.log("device \(device.deviceID) of \(device.jid), \(device.profile.label): \(device.trust.rawValue)"
                + "\(device.active ? "" : ", inactive")\(device.identityChanged ? ", identity changed" : ""), fingerprint \(device.fingerprint.prefix(16))…")
        }
        MacDebugHooks.log("review: chat \(model.trustSummary(for: chat).subtitle.isEmpty ? "-" : model.trustSummary(for: chat).subtitle), "
            + "sending waits \(model.encryptionNeedsReview), reading waits \(model.encryptionIncomingReview), "
            + "own device review \(model.ownDeviceReview.map { String($0.deviceID) })")
    }
}
#endif
