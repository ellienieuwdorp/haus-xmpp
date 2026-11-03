import Foundation
import OMEMO

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

    static func headline(sendingWaits: Bool, isGroup: Bool, ownDevicesOnly: Bool, title: String) -> String {
        guard sendingWaits else { return "Messages waiting for review" }
        return isGroup ? "Devices need review" : ownDevicesOnly ? "New device on your account" : "\(title) added a new device"
    }

    static func explanation(sendingWaits: Bool) -> String {
        sendingWaits
            ? "Check its fingerprint before sending. Until then, nothing you write here leaves this \(ThisDevice.noun)."
            : "They come from a device you haven’t reviewed yet. Check its fingerprint to read them."
    }

    static func rejectionMessage(for device: EncryptionDevice, account: String, isGroup: Bool) -> String {
        if device.jid == account { return OwnDeviceReview.rejectionMessage }
        if isGroup { return "Nothing it sends will be opened. Blocking another member’s device pauses sending to the whole group." }
        return "Your messages won’t be encrypted for it, and nothing it sends will be opened."
    }
}
