#if DEBUG
import AppKit
import MessageStore
import OMEMO
import SwiftUI

// `-haus-tour` steps (see `MacDebugHooks`). Button steps press the element as VoiceOver would, running its own action.
// `own-review` opens the review directly: the sidebar's rows are not in the accessibility tree of a never-shown window.
@MainActor enum MacDeviceReviewTour {
    static func step(_ name: String, _ argument: String, model: AppModel, window: MacWindowState, mainWindow: NSWindow?) async {
        // The fingerprint sheet is for one device, and the iPhone's lab tests find its buttons by title.
        let buttons: [String: (identifiers: [String], titles: [String])] = [
            "device": (["encryptionDevice.", "waitingDevice.", "groupDevice."], []),
            "trust": (["deviceReview.trust.", "ownDevice.trust."], ["Accept without verifying"]),
            "verify": ([], ["Fingerprints match"]),
            "dont-trust": (["deviceReview.reject.", "ownDevice.reject."], ["Block this device"]),
            "compare": (["deviceReview.compare.", "ownDevice.compare."], []),
            "remove": (["ownDevice.remove."], ["Remove old device"]),
        ]
        if let button = buttons[name] {
            guard let mainWindow else { return MacDebugHooks.log("tour \(name): no main window") }
            // The review sheet's identifiers end in the device's version; the bare ID matches them as a prefix.
            let identifiers = button.identifiers.flatMap { [$0 + argument, $0 + argument + "."] }
            await MacKeyboardDebug.pressElement(matching: identifiers + button.titles, in: mainWindow)
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
                // Text only from a lab account's synthetic messages.
                let text = model.isLabAccount ? "'\(message.body.prefix(80))'" : "\(message.body.count) characters"
                MacDebugHooks.log("message \(message.id): \(message.isOutgoing ? "out" : "in"), \(message.encryptionProfile ?? "plain"), "
                    + "\(message.transportState.map { "\($0)" } ?? "-"), \(text)")
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
