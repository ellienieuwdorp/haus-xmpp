import Foundation
import OMEMO
import XMPPProtocol

enum ChatDeviceReview {
    static func devices(_ devices: [EncryptionDevice], account: String, isGroup: Bool) -> [EncryptionDevice] {
        devices.filter { holds($0, account: account, isGroup: isGroup) }.sorted {
            ($0.jid == account ? 1 : 0, $0.jid, $0.deviceID, $0.profile.rawValue) < ($1.jid == account ? 1 : 0, $1.jid, $1.deviceID, $1.profile.rawValue)
        }
    }

    // The account's own blocked devices are left out of group sends instead of holding the group.
    static func holds(_ device: EncryptionDevice, account: String, isGroup: Bool) -> Bool {
        guard device.active else { return false }
        if isGroup { return !device.trust.permitsEncryption && !device.isLeftOutOfGroups(account: account) }
        return device.trust == .undecided
    }

    // Nil while it waits, and for a record that went inactive undecided (its key was replaced). `decided` is keyed by
    // fingerprint-scoped ID and answers for a device no longer listed.
    static func outcome(of device: EncryptionDevice, in devices: [EncryptionDevice], decided: [String: DeviceTrust] = [:],
                        account: String, isGroup: Bool) -> DeviceTrust? {
        guard let current = devices.first(where: { $0.id == device.id }) else { return decided[device.id] }
        guard !holds(current, account: account, isGroup: isGroup), current.trust != .undecided else { return nil }
        return current.trust
    }

    // A waiting record flagged `identityChanged` kept its device ID but not its key.
    static func identityChanged(_ waiting: [EncryptionDevice]) -> Bool { waiting.contains(where: \.identityChanged) }

    static func headline(sendingWaits: Bool, isGroup: Bool, ownDevicesOnly: Bool, identityChanged: Bool, title: String) -> String {
        if identityChanged {
            return isGroup ? "A device in this group changed its identity"
                : ownDevicesOnly ? "A device on your account changed its identity" : "\(title)’s device changed its identity"
        }
        guard sendingWaits else { return "Messages waiting for review" }
        return isGroup ? "Devices need review" : ownDevicesOnly ? "New device on your account" : "\(title) added a new device"
    }

    // Legitimate reinstalls publish a new device ID, so a new key under a known one reads as unusual.
    static func explanation(sendingWaits: Bool, identityChanged: Bool) -> String {
        if identityChanged {
            return sendingWaits
                ? "That’s unusual: a reinstall adds a new device instead. Compare fingerprints before sending."
                : "That’s unusual: a reinstall adds a new device instead. Compare fingerprints to read its messages."
        }
        return sendingWaits
            ? "Check its fingerprint before sending. Until then, nothing you write here leaves this \(ThisDevice.noun)."
            : "They come from a device you haven’t reviewed yet. Check its fingerprint to read them."
    }

    static let identityChangeNote = "Its identity changed. That’s unusual: a reinstall adds a new device instead."

    static func rejectionMessage(for device: EncryptionDevice, account: String, isGroup: Bool) -> String {
        if device.jid == account { return OwnDeviceReview.rejectionMessage }
        if isGroup { return "Nothing it sends will be opened. Blocking another member’s device pauses sending to the whole group." }
        return "Your messages won’t be encrypted for it, and nothing it sends will be opened."
    }
}

extension AppModel {
    // The open chat's card then says a known device ID came back with another key.
    var encryptionReviewIdentityChanged: Bool {
        guard let chat = encryptionOverviewChatID else { return false }
        let stored = groupChats[chat]?.devices ?? encryptionOverview(for: chat)?.devices ?? []
        return ChatDeviceReview.identityChanged(ChatDeviceReview.devices(stored, account: accountID, isGroup: isGroup(chat)))
    }
}
